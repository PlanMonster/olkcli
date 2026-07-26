# Stage 2 — Access Token Injection (Implementation Plan)

Language: ASD-STE100 Simplified Technical English. See [Writing rules](#13-writing-rules) at the end.
Parent document: [OLK_FORK.md](OLK_FORK.md). Stage 1 (fork setup) is complete.

---

## 1 Scope

This document tells the agent how to add an injected access token to `olk`.

An external system owns the OAuth flow. That system gives a short-lived access token to `olk`.
`olk` uses the token and forgets it. `olk` does not store a refresh token in the sandbox.

This document covers only Stage 2. It does not cover the release or the upstream pull request.

---

## 2 Terms

| Term | Meaning |
|---|---|
| Token mode | The condition when the user gives an access token to `olk`. |
| Account mode | The usual condition. `olk` reads a token from the keyring. |
| The keyring | The OS credential store. See `internal/secrets/store.go`. |
| The config dir | The directory from `config.ConfigDir()`. It holds `config.json` and `accounts/`. |
| The guards | The flags `--no-write` and `--no-send`. See `internal/graphapi/client.go:32`. |
| The sandbox | A container without a browser and without a persistent keyring. |

---

## 3 Before you start

The plan uses interfaces that are already in the fork. Confirm these five facts first.

1. `internal/msauth/credential.go:21` has `NewStaticTokenCredential(token, expiresOn)`.
2. `internal/graphapi/client.go:66` takes an `azcore.TokenCredential`. You do not change this package.
3. `internal/cmd/root.go:105` has `RunContext.GraphClient()`. This function is the only place that makes a client.
4. `internal/cmd/root.go:68` makes the keyring store. Only `GraphClient()` and the `auth` commands get there.
5. `internal/config/paths.go:9` reads `OLK_CONFIG_DIR`. The tests use this variable.

---

## 4 Design rules

Obey these ten rules. Each rule is testable.

1. `olk` must not read the keyring in token mode.
2. `olk` must not write the keyring in token mode.
3. `olk` must not read or write an account file in token mode.
4. `olk` must not refresh the token.
5. `olk` must not write the token to a disk file.
6. `olk` must not show the token in output, in an error, or in a log.
7. `olk` must stop before the first network call if the token is expired.
8. `olk` must keep the guards active in token mode.
9. `olk` must keep `--mailbox` operative in token mode.
10. `olk` must refuse `--account` in token mode.

CAUTION: Rule 6 includes the process arguments. Do not put the token into an argv that `olk` prints.

---

## 5 Task 1 — Add the flags

Edit `RootFlags` in `internal/cmd/root.go:27`.

1. Add the four fields below.
2. Keep the same style as the other fields. Each flag has an `env` tag.
3. Do not change the existing fields.

```go
AccessToken          string `help:"Delegated Graph access token; bypasses the keyring (prefer OLK_ACCESS_TOKEN)" env:"OLK_ACCESS_TOKEN" name:"access-token"`
AccessTokenExpiresAt string `help:"RFC3339 expiry of --access-token" env:"OLK_ACCESS_TOKEN_EXPIRES_AT" name:"access-token-expires-at"`
AccountEmail         string `help:"Account identity hint (UPN) for use with --access-token" env:"OLK_ACCOUNT_EMAIL" name:"account-email"`
```

Notes:

- kong reads the `env` tag only when the command line does not give the flag. The flag wins. You write no code for this.
- `OLK_ACCOUNT` continues to set `--account`. `OLK_ACCOUNT_EMAIL` is a different variable with a different function.

---

## 6 Task 2 — Add the token mode helper

Make a new file `internal/cmd/token.go`. Put all the new logic in this file.

The file holds one type and three functions.

```go
// tokenMode holds an externally supplied access token.
type tokenMode struct {
	token     string
	expiresAt time.Time // zero when the caller gives no expiry
	email     string
}

// errTokenExpired reports an expired injected token.
var errTokenExpired = errors.New("access token expired; obtain a fresh token")

// exitTokenExpired is the exit code for errTokenExpired.
const exitTokenExpired = 77

// nominalTokenLifetime is the expiry that the credential reports when the
// caller gives no expiry. Graph is the true authority; a 401 is the real answer.
const nominalTokenLifetime = 30 * time.Minute
```

Write `newTokenMode(f *RootFlags) (*tokenMode, error)` with this behavior:

1. Return `nil, nil` when `f.AccessToken` is empty. The caller then uses account mode.
2. Return an error when `f.Account` is not empty. Use the text `--account is not compatible with OLK_ACCESS_TOKEN`.
3. Parse `f.AccessTokenExpiresAt` with `time.RFC3339` when the field is not empty.
4. Return a parse error that names the format. Do not put the token in the message.
5. Return `errTokenExpired` when the expiry is in the past.
6. Return the `tokenMode` value.

Write `func (t *tokenMode) credential() azcore.TokenCredential`:

1. Use `t.expiresAt` when the value is not zero.
2. Use `time.Now().Add(nominalTokenLifetime)` when the value is zero.
3. Return `msauth.NewStaticTokenCredential(t.token, expiry)`.

Reason for step 2: the Azure pipeline refuses a credential that reports a zero expiry. The nominal
value lets the request go to Graph. Graph then answers with 401 if the token is not valid.

---

## 7 Task 3 — Add the branch in GraphClient

Edit `RunContext.GraphClient()` in `internal/cmd/root.go:105`.

Do this refactor first, because it prevents a bug:

1. Move the last part of `GraphClient()` into a new method. The last part is line 138 to line 153.
2. Name the new method `newGraphClient(cred azcore.TokenCredential) (*graphapi.Client, error)`.
3. Keep the verbose selection in the new method.
4. Keep the call to `client.SetGuards(...)` in the new method. Rule 8 depends on this call.
5. Keep the cache assignment `r.client = client` in the new method.

Then add the branch:

```go
func (r *RunContext) GraphClient() (*graphapi.Client, error) {
	if r.client != nil {
		return r.client, nil
	}

	// Token mode: an external system owns the OAuth flow. Do not touch the
	// keyring, the account files, or the default-account config.
	tm, err := newTokenMode(r.Flags)
	if err != nil {
		return nil, err
	}
	if tm != nil {
		return r.newGraphClient(tm.credential())
	}

	// ... the existing account-mode code, unchanged ...
}
```

The branch is above the call to `r.Store()`. This position satisfies rules 1 to 4.

---

## 8 Task 4 — Change the auth commands

Edit `internal/cmd/auth.go`. The five subcommands are at line 16 to line 21.

Add one guard function to `internal/cmd/token.go`:

```go
// refuseInTokenMode blocks a stored-account command while a token is injected.
func refuseInTokenMode(f *RootFlags, cmd string) error {
	if f.AccessToken == "" {
		return nil
	}
	return fmt.Errorf("auth %s manages stored accounts and is unavailable when OLK_ACCESS_TOKEN is set", cmd)
}
```

Then make these changes.

| Command | Change | Position |
|---|---|---|
| `auth login` | Call `refuseInTokenMode`. Return the error. | First statement, line 34. |
| `auth logout` | Call `refuseInTokenMode`. Return the error. | First statement, line 109. |
| `auth clean` | Call `refuseInTokenMode`. Return the error. | First statement, line 147. |
| `auth list` | Call `refuseInTokenMode`. Return the error. | First statement, line 214. |
| `auth status` | Report the injected token. Then return. | First statement, line 258. |

`auth status` in token mode prints these lines and no other line:

```
Account: <OLK_ACCOUNT_EMAIL, or "unknown (injected token)">
Status:  Authenticated (injected access token)
Expires: <RFC3339 expiry, or "unknown">
```

Each guard is above the first call to `ctx.Config()` or `ctx.Store()` in the function. This position
satisfies rules 1 to 3 for the `auth` group.

---

## 9 Task 5 — Add the exit code

Edit `Execute()` in `internal/cmd/root.go:243`.

1. Find the error block after `ctx.Run(runCtx)`.
2. Add a test for `errTokenExpired` with `errors.Is`.
3. Return `exitTokenExpired` for that error. Return 1 for all other errors.
4. Print the message to stderr with the existing `outfmt.SanitizeMultiline` call.

```go
err := ctx.Run(runCtx)
if err != nil {
	fmt.Fprintf(os.Stderr, "Error: %s\n", outfmt.SanitizeMultiline(err.Error()))
	if errors.Is(err, errTokenExpired) {
		return exitTokenExpired
	}
	return 1
}
```

---

## 10 Task 6 — Confirm the MCP server

The MCP server needs no new code. Confirm the four facts below. Then add the test in Task 7.

1. `newKongParser` at `internal/cmd/mcp_server.go:200` builds the same `CLI` struct. kong reads the same `env` tags. The new flags therefore work in the server.
2. `buildArgv` at `internal/cmd/mcp_invoke.go:193` builds a small argv. The function does not add `--access-token`. Rule 6 stays true. Do not add the flag to this function.
3. The handler at `internal/cmd/mcp_invoke.go:66` makes a new `RunContext` for each call. Each call therefore gets a new client from your branch.
4. `internal/graphapi/client.go:171` redacts the `Authorization` header in verbose logs. Rule 6 stays true for `--verbose`.

---

## 11 Task 7 — Write the tests

Put the tests in `internal/cmd/token_test.go`. Use the stdlib `testing` package.
The tests are in package `cmd`, so a test can set the private `store` field of `RunContext`.

Write these seven tests.

### 11.1 Credential selection

1. Make a fake `secrets.Store`. Each method calls `t.Fatal`.
2. Put the fake in `RunContext.store`.
3. Set `Flags.AccessToken`.
4. Call `GraphClient()`.
5. Confirm that the call returns a client and no error.
6. Confirm that the fake reports no access.

### 11.2 Expiry stops the command

1. Set `Flags.AccessTokenExpiresAt` to a time in the past.
2. Call `newTokenMode`.
3. Confirm `errors.Is(err, errTokenExpired)`.
4. Confirm that no HTTP transport runs. Use a transport that calls `t.Fatal`.

### 11.3 Exit code

1. Confirm that `errTokenExpired` maps to 77.
2. Test the mapping function, not the whole process.

### 11.4 No persistence

1. Set `OLK_CONFIG_DIR` to `t.TempDir()`.
2. Run a command in token mode against a mock transport.
3. Walk the temp directory.
4. Confirm that the directory holds no file.

### 11.5 Flag interplay

1. Confirm that `--account` with a token returns an error.
2. Confirm that `--mailbox` with a token passes to `resolveMailboxTarget`.
3. Confirm that `--access-token` on the command line wins against `OLK_ACCESS_TOKEN`.

### 11.6 Auth commands

1. Confirm that `login`, `logout`, `clean`, and `list` return an error in token mode.
2. Confirm that each error message names `OLK_ACCESS_TOKEN`.
3. Confirm that `status` prints the injected-token lines.
4. Confirm that `status` does not touch the fake store.

### 11.7 No token in output

1. Use a token with a unique value, for example `SENTINEL-TOKEN-VALUE`.
2. Run a command in token mode with `--verbose` and with `--dry-run`.
3. Capture stdout and stderr with `captureStd` from `internal/cmd/mcp_capture.go`.
4. Confirm that neither stream holds the sentinel value.

---

## 12 Task 8 — Documentation and checks

1. Add a section `Access-token injection` to `README.md`. Put the section under `Authentication`.
2. Describe the three environment variables in a table.
3. State that `olk` does not refresh and does not store the token.
4. Give one sandbox example with `OLK_ACCESS_TOKEN` and `--no-write`.
5. Add the same three variables to `SKILL.md` if that file lists the environment variables.
6. Run `make test`. All tests must pass.
7. Run `make lint`. The linter must report no finding.
8. Keep the diff small. Change only the files in this plan.

Expected files in the diff:

```
internal/cmd/root.go        (flags, branch, exit code)
internal/cmd/token.go       (new)
internal/cmd/token_test.go  (new)
internal/cmd/auth.go        (five guards)
README.md                   (one section)
```

---

## 13 Writing rules

This document follows ASD-STE100:

- One instruction per sentence. Procedural sentences hold 20 words or fewer.
- Active voice and the imperative form in all procedures.
- Present tense only.
- No gerund as a verb.
- `must` marks a requirement. `must not` marks a prohibition.
- A caution comes before the step that it applies to.
- Code identifiers, flag names, and file paths are technical names. STE permits them.
