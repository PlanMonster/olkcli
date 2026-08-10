package cmd

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/rlrghb/olkcli/internal/graphapi"
	"github.com/rlrghb/olkcli/internal/secrets"
)

// sentinelToken is deliberately unique so a leak test can grep for it.
const sentinelToken = "SENTINEL-ACCESS-TOKEN-DO-NOT-PRINT"

// policyOpts are the token request options the Graph SDK would pass.
func policyOpts() policy.TokenRequestOptions {
	return policy.TokenRequestOptions{Scopes: []string{"https://graph.microsoft.com/.default"}}
}

// failStore is a secrets.Store that fails the test if anything touches it. It
// proves token mode never reaches the keyring: no reads, no writes, no prompts.
type failStore struct{ t *testing.T }

func (s failStore) Set(key, value string) error {
	s.t.Fatalf("keyring Set(%q) called in token mode", key)
	return nil
}

func (s failStore) Get(key string) (string, error) {
	s.t.Fatalf("keyring Get(%q) called in token mode", key)
	return "", nil
}

func (s failStore) Delete(key string) error {
	s.t.Fatalf("keyring Delete(%q) called in token mode", key)
	return nil
}

func (s failStore) Keys() ([]string, error) {
	s.t.Fatalf("keyring Keys() called in token mode")
	return nil, nil
}

// tokenRunContext returns a RunContext wired to a keyring that fails on use and
// to a throwaway config dir, so any stored-credential access is a test failure.
func tokenRunContext(t *testing.T, flags *RootFlags) *RunContext {
	t.Helper()
	t.Setenv("OLK_ACCESS_TOKEN", sentinelToken)
	t.Setenv("OLK_CONFIG_DIR", t.TempDir())
	return &RunContext{Ctx: context.Background(), Flags: flags, store: failStore{t}}
}

// --- 11.1 credential selection ----------------------------------------------

func TestTokenMode_SelectsStaticCredentialWithoutKeyring(t *testing.T) {
	ctx := tokenRunContext(t, &RootFlags{})

	client, err := ctx.GraphClient()
	if err != nil {
		t.Fatalf("GraphClient in token mode: %v", err)
	}
	if client == nil {
		t.Fatal("expected a Graph client")
	}
	// A second call must reuse the cached client (still no keyring access).
	if again, err := ctx.GraphClient(); err != nil || again != client {
		t.Fatalf("expected cached client, got %v, %v", again, err)
	}
}

func TestTokenMode_GuardsStillApply(t *testing.T) {
	ctx := tokenRunContext(t, &RootFlags{NoWrite: true, NoSend: true})

	client, err := ctx.GraphClient()
	if err != nil {
		t.Fatalf("GraphClient: %v", err)
	}
	// The guards live on the client, so exercising any mutating method proves
	// token mode did not bypass SetGuards. CreateDraft refuses before any I/O.
	if _, err := client.CreateDraft(ctx.Ctx, "s", "b", []string{"a@b.com"}, nil, nil, false); !errors.Is(err, graphapi.ErrNoWrite) {
		t.Fatalf("expected ErrNoWrite in token mode, got %v", err)
	}
}

func TestAccountMode_UnchangedWhenNoTokenSupplied(t *testing.T) {
	t.Setenv("OLK_ACCESS_TOKEN", "")
	if tm, err := newTokenMode(&RootFlags{}); err != nil || tm != nil {
		t.Fatalf("expected account mode (nil, nil), got %v, %v", tm, err)
	}
	t.Setenv("OLK_ACCESS_TOKEN", "   ")
	if tm, err := newTokenMode(&RootFlags{}); err != nil || tm != nil {
		t.Fatalf("whitespace-only token must mean account mode, got %v, %v", tm, err)
	}
}

// --- 11.2 expiry fails closed ------------------------------------------------

func TestTokenMode_ExpiredFailsClosed(t *testing.T) {
	past := time.Now().Add(-time.Minute).UTC().Format(time.RFC3339)
	ctx := tokenRunContext(t, &RootFlags{AccessTokenExpiresAt: past})

	_, err := ctx.GraphClient()
	if !errors.Is(err, errTokenExpired) {
		t.Fatalf("expected errTokenExpired, got %v", err)
	}
	// No client was constructed, so no request could have been sent.
	if ctx.client != nil {
		t.Fatal("a Graph client was built for an expired token")
	}
}

func TestTokenMode_FutureExpiryIsUsedVerbatim(t *testing.T) {
	t.Setenv("OLK_ACCESS_TOKEN", sentinelToken)
	want := time.Now().Add(2 * time.Hour).UTC().Truncate(time.Second)
	tm, err := newTokenMode(&RootFlags{
		AccessTokenExpiresAt: want.Format(time.RFC3339),
	})
	if err != nil {
		t.Fatalf("newTokenMode: %v", err)
	}
	tok, err := tm.credential().GetToken(context.Background(), policyOpts())
	if err != nil {
		t.Fatalf("GetToken: %v", err)
	}
	if !tok.ExpiresOn.UTC().Equal(want) {
		t.Fatalf("expiry = %s, want %s", tok.ExpiresOn.UTC(), want)
	}
	if tok.Token != sentinelToken {
		t.Fatal("credential returned a different token than the one supplied")
	}
}

func TestTokenMode_MissingExpiryGetsNominalLifetime(t *testing.T) {
	t.Setenv("OLK_ACCESS_TOKEN", sentinelToken)
	tm, err := newTokenMode(&RootFlags{})
	if err != nil {
		t.Fatalf("newTokenMode: %v", err)
	}
	tok, err := tm.credential().GetToken(context.Background(), policyOpts())
	if err != nil {
		t.Fatalf("GetToken: %v", err)
	}
	// A zero expiry would make the azcore pipeline treat the token as expired
	// and refuse to send the request, so the credential must report a future one.
	if !tok.ExpiresOn.After(time.Now().Add(nominalTokenLifetime - time.Minute)) {
		t.Fatalf("expected a nominal future expiry, got %s", tok.ExpiresOn)
	}
}

func TestTokenMode_MalformedExpiryIsRejectedWithoutEchoingToken(t *testing.T) {
	t.Setenv("OLK_ACCESS_TOKEN", sentinelToken)
	_, err := newTokenMode(&RootFlags{AccessTokenExpiresAt: "yesterday"})
	if err == nil {
		t.Fatal("expected an error for a malformed expiry")
	}
	if !strings.Contains(err.Error(), "RFC3339") {
		t.Fatalf("error should name the expected format, got %q", err)
	}
	if strings.Contains(err.Error(), sentinelToken) {
		t.Fatal("error message leaked the access token")
	}
}

// --- 11.3 exit code ----------------------------------------------------------

func TestExitCodeFor(t *testing.T) {
	if got := exitCodeFor(nil); got != 0 {
		t.Fatalf("nil error => %d, want 0", got)
	}
	if got := exitCodeFor(errors.New("boom")); got != 1 {
		t.Fatalf("generic error => %d, want 1", got)
	}
	if got := exitCodeFor(errTokenExpired); got != exitTokenExpired {
		t.Fatalf("expired token => %d, want %d", got, exitTokenExpired)
	}
	// Wrapped sentinels must keep the distinct code so callers can retry.
	wrapped := errors.Join(errors.New("context"), errTokenExpired)
	if got := exitCodeFor(wrapped); got != exitTokenExpired {
		t.Fatalf("wrapped expired token => %d, want %d", got, exitTokenExpired)
	}
}

// --- 11.4 no persistence -----------------------------------------------------

func TestTokenMode_WritesNothingToConfigDir(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("OLK_ACCESS_TOKEN", sentinelToken)
	t.Setenv("OLK_CONFIG_DIR", dir)

	flags := &RootFlags{AccountEmail: "user@corp.com"}
	ctx := &RunContext{Ctx: context.Background(), Flags: flags, store: failStore{t}}
	if _, err := ctx.GraphClient(); err != nil {
		t.Fatalf("GraphClient: %v", err)
	}
	if _, _, err := captureStd(func() error { return (&AuthStatusCmd{}).Run(ctx) }); err != nil {
		t.Fatalf("auth status: %v", err)
	}

	var found []string
	err := filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path != dir {
			found = append(found, path)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walking config dir: %v", err)
	}
	if len(found) != 0 {
		t.Fatalf("token mode created config state: %v", found)
	}
}

func TestTokenMode_DoesNotReadConfigForTimezoneOrConfigCommands(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.json")
	if err := os.WriteFile(configPath, []byte(`{"timezone":"Pacific/Honolulu"}`), 0o644); err != nil {
		t.Fatalf("write config sentinel: %v", err)
	}
	t.Setenv("OLK_ACCESS_TOKEN", sentinelToken)
	t.Setenv("OLK_CONFIG_DIR", dir)

	ctx := &RunContext{Ctx: context.Background(), Flags: &RootFlags{}}
	loc, err := ctx.Timezone()
	if err != nil {
		t.Fatalf("Timezone: %v", err)
	}
	if loc != time.Local {
		t.Fatalf("token-mode timezone = %q, want Local without config fallback", loc)
	}
	if err := (&ConfigGetCmd{Key: "timezone"}).Run(ctx); err == nil {
		t.Fatal("config get must be unavailable in token mode")
	}
	if err := (&ConfigSetCmd{Key: "timezone", Value: "UTC"}).Run(ctx); err == nil {
		t.Fatal("config set must be unavailable in token mode")
	}

	info, err := os.Stat(configPath)
	if err != nil {
		t.Fatalf("stat config sentinel: %v", err)
	}
	if got := info.Mode().Perm(); got != 0o644 {
		t.Fatalf("config file mode changed to %o, proving token mode touched it", got)
	}
}

// --- 11.5 flag interplay -----------------------------------------------------

func TestTokenMode_AccountFlagIsRejected(t *testing.T) {
	t.Setenv("OLK_ACCESS_TOKEN", sentinelToken)
	_, err := newTokenMode(&RootFlags{Account: "someone@corp.com"})
	if err == nil || !strings.Contains(err.Error(), "OLK_ACCESS_TOKEN") {
		t.Fatalf("expected --account to be refused in token mode, got %v", err)
	}
}

func TestTokenMode_MailboxStillResolves(t *testing.T) {
	ctx := tokenRunContext(t, &RootFlags{Mailbox: "shared@corp.com"})
	if _, err := ctx.GraphClient(); err != nil {
		t.Fatalf("GraphClient with --mailbox: %v", err)
	}
	target, err := resolveMailboxTarget(ctx.Flags.Mailbox)
	if err != nil {
		t.Fatalf("resolveMailboxTarget: %v", err)
	}
	if target != "shared@corp.com" {
		t.Fatalf("mailbox target = %q, want shared@corp.com", target)
	}
}

func TestTokenMode_AccessTokenIsEnvironmentOnly(t *testing.T) {
	t.Setenv("OLK_ACCESS_TOKEN", sentinelToken)
	t.Setenv("OLK_ACCESS_TOKEN_EXPIRES_AT", "")
	t.Setenv("OLK_ACCOUNT", "")

	cli := &CLI{}
	k, err := newKongParser(cli)
	if err != nil {
		t.Fatalf("newKongParser: %v", err)
	}
	if _, err := k.Parse([]string{"--access-token", sentinelToken, "version"}); err == nil {
		t.Fatal("--access-token must not be accepted")
	}

	schema := flagSchema(leafByPath(t, "mail", "list"))
	if _, ok := schema.Properties["access-token"]; ok {
		t.Fatal("access-token must not appear in the Kong-derived MCP schema")
	}

	tm, err := newTokenMode(&cli.RootFlags)
	if err != nil {
		t.Fatalf("newTokenMode: %v", err)
	}
	if tm == nil || tm.token != sentinelToken {
		t.Fatal("OLK_ACCESS_TOKEN did not activate token mode")
	}
}

// --- 11.6 auth subcommands ---------------------------------------------------

func TestAuthCommands_RefusedInTokenMode(t *testing.T) {
	ctx := tokenRunContext(t, &RootFlags{Force: true})

	cases := map[string]func() error{
		"login":  func() error { return (&AuthLoginCmd{}).Run(ctx) },
		"logout": func() error { return (&AuthLogoutCmd{}).Run(ctx) },
		"clean":  func() error { return (&AuthCleanCmd{}).Run(ctx) },
		"list":   func() error { return (&AuthListCmd{}).Run(ctx) },
	}
	for name, run := range cases {
		t.Run(name, func(t *testing.T) {
			_, _, err := captureStd(run)
			if err == nil {
				t.Fatalf("auth %s must fail in token mode", name)
			}
			if !strings.Contains(err.Error(), "OLK_ACCESS_TOKEN") {
				t.Fatalf("auth %s error should name OLK_ACCESS_TOKEN, got %q", name, err)
			}
			if !strings.Contains(err.Error(), name) {
				t.Fatalf("auth %s error should name the command, got %q", name, err)
			}
		})
	}
}

func TestAuthStatus_ReportsInjectedToken(t *testing.T) {
	expiry := time.Now().Add(time.Hour).UTC().Truncate(time.Second)
	ctx := tokenRunContext(t, &RootFlags{
		AccountEmail:         "user@corp.com",
		AccessTokenExpiresAt: expiry.Format(time.RFC3339),
	})

	out, _, err := captureStd(func() error { return (&AuthStatusCmd{}).Run(ctx) })
	if err != nil {
		t.Fatalf("auth status: %v", err)
	}
	for _, want := range []string{"user@corp.com", "injected access token", expiry.Format(time.RFC3339)} {
		if !strings.Contains(out, want) {
			t.Fatalf("auth status output missing %q:\n%s", want, out)
		}
	}
}

func TestAuthStatus_UnknownIdentityWithoutHint(t *testing.T) {
	ctx := tokenRunContext(t, &RootFlags{})

	out, _, err := captureStd(func() error { return (&AuthStatusCmd{}).Run(ctx) })
	if err != nil {
		t.Fatalf("auth status: %v", err)
	}
	if !strings.Contains(out, "unknown (injected token)") || !strings.Contains(out, "Expires: unknown") {
		t.Fatalf("unexpected auth status output:\n%s", out)
	}
}

// --- 11.7 the token never appears in output ----------------------------------

func TestTokenMode_TokenNeverPrinted(t *testing.T) {
	ctx := tokenRunContext(t, &RootFlags{
		AccountEmail: "user@corp.com",
		Verbose:      true,
		DryRun:       true,
	})

	out, errOut, err := captureStd(func() error {
		if _, cerr := ctx.GraphClient(); cerr != nil {
			return cerr
		}
		return (&AuthStatusCmd{}).Run(ctx)
	})
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	if strings.Contains(out, sentinelToken) || strings.Contains(errOut, sentinelToken) {
		t.Fatalf("access token leaked into output:\nstdout: %s\nstderr: %s", out, errOut)
	}
}

// --- token mode under the MCP server ----------------------------------------

// The MCP server re-parses argv (and therefore re-reads the environment) on every
// tool call, so token mode must apply per call without any MCP-specific plumbing.
func TestMCP_HonorsTokenMode(t *testing.T) {
	t.Setenv("OLK_CONFIG_DIR", t.TempDir())
	t.Setenv("OLK_ACCOUNT", "")
	t.Setenv("OLK_ACCESS_TOKEN", sentinelToken)
	t.Setenv("OLK_ACCESS_TOKEN_EXPIRES_AT", time.Now().Add(-time.Minute).UTC().Format(time.RFC3339))

	cs := connectE2E(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "whoami"})
	if err != nil {
		t.Fatalf("CallTool: %v", err)
	}
	text := resultText(res)
	// The expired-token failure must surface as stable, matchable text: an
	// orchestrator keys off it to mint a fresh token (exit codes are invisible
	// over MCP).
	if !strings.Contains(text, "access token expired") {
		t.Fatalf("expected the expired-token message, got: %s", text)
	}
	if strings.Contains(text, sentinelToken) {
		t.Fatal("access token leaked into an MCP tool result")
	}
	// Reaching the token-mode branch means no stored account was consulted.
	if strings.Contains(text, "no account configured") {
		t.Fatal("MCP tool call fell through to account mode")
	}
}

// compile-time assertion: failStore satisfies the keyring interface it stands in for.
var _ secrets.Store = failStore{}
