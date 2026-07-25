# olk Fork: Token Injection, Release, Upstream PR

Owns: the fork of `rlrghb/olkcli`, the agent prompt to implement the change in that repo, the release process that makes the binary installable in agent containers, and the upstream PR strategy. Snapshot-side installation is owned by [SNAPSHOT_PACKAGING.md](SNAPSHOT_PACKAGING.md).

## Why the fork exists

Stock olk has no access-token input. Its env vars (`OLK_CLIENT_ID`, `OLK_TENANT_ID`, `OLK_KEYRING_PASSWORD`, `OLK_ACCOUNT`) all serve its own login/keyring flows. The only headless path seeds a refresh token into a container-local keyring, which violates refresh-token containment and races Microsoft's refresh-token rotation across concurrent Daytona containers. The seam already exists upstream: `internal/msauth` has a static token credential and `internal/graphapi` accepts any `azcore.TokenCredential`. The fork adds an env route into that seam and nothing else.

## Fork setup

1. Fork `github.com/rlrghb/olkcli` to `github.com/PlanMonster/olkcli`.
2. Branch `access-token-injection` off the latest upstream release tag (record which one).
3. Apply the change below via the agent prompt.
4. Tag fork releases as `v<upstream>-nanoclaw.<n>` (for example `v0.9.1-nanoclaw.1`) so the upstream base is always readable from the version.

## Agent prompt (copy-paste into the fork repo)

Paste the block below verbatim as the task prompt for an agent session rooted in the `PlanMonster/olkcli` checkout.

```text
Implement an externally-supplied access-token credential mode for olk. This must be
upstream-quality, generic (no company-specific naming), and narrowly scoped. Do not
change any other behavior.

## Contract

Three new environment variables, honored by every CLI command and by `olk mcp`:

  OLK_ACCESS_TOKEN            A delegated Microsoft Graph access token (bearer).
  OLK_ACCESS_TOKEN_EXPIRES_AT Optional RFC3339 expiry for that token.
  OLK_ACCOUNT_EMAIL           Optional account identity hint (UPN/email) used where
                              olk would otherwise read stored account metadata.

Also add a --access-token flag on the root command mirroring OLK_ACCESS_TOKEN
(flag wins over env), consistent with how other global flags pair with env vars.

## Required behavior (all must hold)

1. When OLK_ACCESS_TOKEN is set, olk MUST NOT touch the OS keyring, the encrypted
   file store, or stored account metadata: no reads, no writes, no prompts. Token
   mode bypasses account resolution entirely.
2. Construct the credential from the supplied token. internal/msauth already has a
   static token credential (used in tests); reuse or promote it. The Graph client in
   internal/graphapi accepts azcore.TokenCredential, so no Graph-layer changes
   should be needed beyond wiring.
3. Never refresh. Never persist the token anywhere (no config dir writes, no cache
   files). The token's lifecycle is the process's lifecycle.
4. If OLK_ACCESS_TOKEN_EXPIRES_AT is set and in the past, fail closed BEFORE any
   network call, with a clear stderr message ("access token expired; obtain a fresh
   token") and a distinct nonzero exit code. If unset, pass the token through and
   let Graph return 401 naturally; map that 401 to the same "unauthenticated" error
   class olk already uses.
5. Identity: `olk whoami` and any code path that needs the signed-in account's
   email should use OLK_ACCOUNT_EMAIL when present, else resolve via Graph /me.
   --account must error in token mode ("--account is not compatible with
   OLK_ACCESS_TOKEN"); --mailbox (delegated mailbox targeting) must keep working.
6. `olk auth login|logout|clean|list|status` in token mode: status should report
   that an injected token is in use (and its expiry if known); the others should
   error with a message explaining that auth commands manage stored accounts and
   are unavailable when OLK_ACCESS_TOKEN is set.
7. All existing guard flags must compose unchanged with token mode: --no-write,
   --no-send, --no-input, --wrap-untrusted, --enable-commands[-exact],
   --disable-commands, and the OLK_MCP_* controls for `olk mcp`.
8. The token must never appear in logs, verbose output, error messages, or dry-run
   output.

## Where to look

- internal/msauth: credential construction, static token credential, device-code
  and browser flows (do not modify the flows; add a selection branch before them).
- internal/cmd: root command setup, global flag/env binding, account resolution.
- internal/secrets and internal/config: the code paths that must be provably
  skipped in token mode.
- internal/graphapi: confirm the client takes azcore.TokenCredential and needs no
  change.

## Tests (required)

- Credential selection: OLK_ACCESS_TOKEN set -> static credential chosen; keyring
  and config account lookup never invoked (inject a fake keyring that fails the
  test if touched).
- Expiry: past OLK_ACCESS_TOKEN_EXPIRES_AT fails closed with the documented exit
  code and no network call (use a transport that fails the test if used).
- Persistence: after running a command in token mode against a mocked Graph
  transport, the config dir contains no new/modified files.
- Flag interplay: --account errors; --mailbox passes through; --access-token flag
  overrides env.
- auth subcommand behavior per item 6.
- `olk mcp` honors token mode identically (spawn the server with the env set and a
  mocked transport; verify a read tool call works and no keyring access happens).

## Docs

Add a README section "Access-token injection" under Authentication describing the
three variables, the no-refresh/no-persistence semantics, and the intended use
case (an external system owns OAuth and hands short-lived tokens to olk in CI or
agent sandboxes). Keep the existing security posture language.

Run make test and make lint before finishing. Keep the diff reviewable: one
feature, no drive-by refactors.
```

## Release process (makes the binary installable in containers)

The upstream repo ships `.goreleaser.yaml` and a Makefile, so the fork can release real binaries with no new infrastructure:

1. Verify the fork has a release workflow (upstream builds via GoReleaser on tag push; if the workflow is not present in the fork, add a minimal `.github/workflows/release.yml` that runs `goreleaser release --clean` on `v*` tags with `GITHUB_TOKEN`).
2. Tag and push: `git tag v0.9.1-nanoclaw.1 && git push origin v0.9.1-nanoclaw.1`.
3. GoReleaser publishes GitHub release assets including `olk_<version>_linux_amd64.tar.gz` and a `checksums.txt`.
4. Record two values for the consumer side: the release tag and the sha256 of the linux/amd64 asset. These become the `OLK_VERSION` / `OLK_SHA256` pins in `scripts/daytona-snapshot.ts` (see [SNAPSHOT_PACKAGING.md](SNAPSHOT_PACKAGING.md)).

Fallback if GoReleaser is unavailable: `make build` in a linux/amd64 environment and attach `bin/olk` to a manually created GitHub release, plus a sha256. Do not consume unpinned artifacts (no `@latest`, no branch tarballs).

Do not publish to npm from the fork; the upstream `olkcli` npm name is not ours, and the snapshot consumes a checksummed binary directly.

## Upstream PR

Open the PR against `rlrghb/olkcli` from the same branch before NanoClaw work builds on the fork (the feature is generic and matches olk's existing env-pairing conventions, so it has a real chance of landing). The plan does not depend on it merging. If it merges, repoint the snapshot pin at the upstream release and retire the fork.

## Version bump procedure

When upstream releases a new version we want: rebase `access-token-injection` onto the new tag, re-run the fork test suite, tag `v<new-upstream>-nanoclaw.1`, update the two pins in `scripts/daytona-snapshot.ts`, and let the snapshot content hash roll the Daytona image.
