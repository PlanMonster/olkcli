package cmd

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"

	"github.com/rlrghb/olkcli/internal/msauth"
)

// Token mode: an external system (CI, an agent sandbox, a token broker) owns the
// OAuth flow and hands olk a short-lived delegated access token. olk then acts
// as a pure consumer of that token:
//
//   - it never reads or writes the OS keyring or the stored account files,
//   - it never refreshes, and never persists the token anywhere,
//   - the token's lifetime is the process's lifetime.
//
// This keeps long-lived refresh tokens outside disposable environments, where a
// container-local keyring would both leak a durable credential and race
// Microsoft's refresh-token rotation across concurrent containers.

// errTokenExpired reports an injected access token whose supplied expiry has
// already passed. It is a sentinel so Execute can map it to a distinct exit
// code and callers can re-mint a token without parsing message text.
var errTokenExpired = errors.New("access token expired; obtain a fresh token")

// exitTokenExpired is the process exit code for errTokenExpired. It is distinct
// from the generic failure code (1) so an orchestrator can react by minting a
// fresh token instead of treating the run as a hard error.
const exitTokenExpired = 77

// nominalTokenLifetime is the expiry reported to the Azure SDK when the caller
// supplies a token without an expiry. A zero expiry would make the SDK's
// credential pipeline treat the token as already expired and refuse to send the
// request, so we report a plausible remaining lifetime and let Graph be the
// authority: a stale token comes back as 401, which olk already maps to its
// unauthenticated error class.
const nominalTokenLifetime = 30 * time.Minute

// tokenMode holds an externally supplied access token and its optional
// metadata. A nil *tokenMode means account mode (the usual keyring-backed path).
type tokenMode struct {
	token     string
	expiresAt time.Time // zero when the caller supplied no expiry
	email     string    // optional identity hint (OLK_ACCOUNT_EMAIL)
}

// newTokenMode returns the injected-token configuration, or nil when no token is
// supplied. It fails closed: an unparseable or already-passed expiry is an error
// raised before any network call and before any credential store is touched.
func newTokenMode(f *RootFlags) (*tokenMode, error) {
	if f == nil {
		return nil, nil
	}
	token := injectedAccessToken()
	if token == "" {
		return nil, nil
	}

	// --account selects among *stored* accounts, which token mode does not read.
	// Failing here is clearer than silently ignoring the flag.
	if strings.TrimSpace(f.Account) != "" {
		return nil, errors.New("--account is not compatible with OLK_ACCESS_TOKEN; use --mailbox for delegated access, or OLK_ACCOUNT_EMAIL as an identity hint")
	}

	tm := &tokenMode{token: token, email: strings.TrimSpace(f.AccountEmail)}

	if raw := strings.TrimSpace(f.AccessTokenExpiresAt); raw != "" {
		exp, err := time.Parse(time.RFC3339, raw)
		if err != nil {
			// Report the expected format, never the value alongside the token.
			return nil, errors.New("invalid access token expiry: expected RFC3339, e.g. 2030-01-01T12:34:56Z")
		}
		tm.expiresAt = exp
		if !time.Now().Before(exp) {
			return nil, errTokenExpired
		}
	}

	return tm, nil
}

// injectedAccessToken reads the credential directly from the environment. The
// token intentionally has no RootFlags field: Kong must never accept it in
// process arguments or expose it in help or generated schemas.
func injectedAccessToken() string {
	return strings.TrimSpace(os.Getenv("OLK_ACCESS_TOKEN"))
}

// credential builds the azcore credential for the injected token. The Graph
// wrapper accepts any azcore.TokenCredential, so nothing below this point knows
// or cares where the token came from.
func (t *tokenMode) credential() azcore.TokenCredential {
	expiry := t.expiresAt
	if expiry.IsZero() {
		expiry = time.Now().Add(nominalTokenLifetime)
	}
	return msauth.NewStaticTokenCredential(t.token, expiry)
}

// accountLabel returns a display identity for the injected token. Token mode has
// no stored account metadata, so it uses the caller's hint when present.
func (t *tokenMode) accountLabel() string {
	if t.email != "" {
		return t.email
	}
	return "unknown (injected token)"
}

// expiryLabel renders the supplied expiry for display, or "unknown" when the
// caller did not supply one.
func (t *tokenMode) expiryLabel() string {
	if t.expiresAt.IsZero() {
		return "unknown"
	}
	return t.expiresAt.UTC().Format(time.RFC3339)
}

// exitCodeFor maps a command error to a process exit code. Everything is a
// generic failure (1) except an expired injected token, which gets its own code
// so an orchestrator can mint a fresh token and retry.
func exitCodeFor(err error) int {
	if err == nil {
		return 0
	}
	if errors.Is(err, errTokenExpired) {
		return exitTokenExpired
	}
	return 1
}

// refuseInTokenMode blocks a command that manages stored accounts while a token
// is injected. Call it before any keyring or config access so a refusal never
// prompts for a keyring password.
func refuseInTokenMode(f *RootFlags, cmd string) error {
	if f == nil || injectedAccessToken() == "" {
		return nil
	}
	return fmt.Errorf("auth %s manages stored accounts and is unavailable when OLK_ACCESS_TOKEN is set", cmd)
}
