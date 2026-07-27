# Publishing the fork to npm (`@planmonster`)

This fork publishes its own npm distribution. The upstream project owns the
unscoped names (`olkcli`, `olk-linux-x64`, …) on npmjs.org, so this fork uses
the `@planmonster` scope instead.

The distribution exists so that a control plane (Convex) can start the CLI in an
ephemeral sandbox (Daytona) with `npx`, and so that an agent runner can start the
MCP server.

## What gets published

Seven packages per release:

| Package | Contents | Size |
| --- | --- | --- |
| `@planmonster/olkcli` | JS launcher only | ~1.5 KB |
| `@planmonster/olk-linux-x64` | `bin/olk` | ~119 MB unpacked, ~23 MB compressed |
| `@planmonster/olk-linux-arm64` | `bin/olk` | same |
| `@planmonster/olk-darwin-x64` | `bin/olk` | same |
| `@planmonster/olk-darwin-arm64` | `bin/olk` | same |
| `@planmonster/olk-win32-x64` | `bin/olk.exe` | same |
| `@planmonster/olk-win32-arm64` | `bin/olk.exe` | same |

The Microsoft Graph SDK makes the binary large. A consumer downloads one binary
package only, because each binary package declares `os` and `cpu`. npm skips the
five that do not match the host.

`npm/olk/bin/olk.js` finds its binary through its own `optionalDependencies`, so
the launcher needs no scope-specific code. The same launcher works for the
unscoped upstream packages and for the scoped fork packages.

## Versioning

The fork must use a version that carries a suffix, for example `0.9.5-pm.1`.
`publish-npm.yml` rejects a bare `X.Y.Z` version. Two reasons:

- Upstream `olkcli` is at 1.10.0. A shared number implies a parity that does not
  exist.
- The suffix records which upstream release the fork tracks.

npm registry data is immutable. You can never re-use a version number, even
after an unpublish. Publish a new version to correct a defect.

## One-time bootstrap (do this before the first release)

npm Trusted Publishing can only be configured on a package that already exists.
CI publishes **through** Trusted Publishing. Therefore the first publish of each
of the seven names must come from a maintainer's machine. CI publishes every
version after that, and CI never holds a token.

Publish real tarballs, not placeholders. CI builds all six binaries for you, so
you do not need a Mac and you create no junk versions.

1. Create the `planmonster` organization on npmjs.org. Enable 2FA on your
   account.
2. In the Actions tab, start **Publish (npm, @planmonster)** with the version
   you intend to ship and `dry_run: true`. The run packs seven tarballs and
   uploads them as the `npm-tarballs` artifact.
3. Download and unzip the artifact.
4. Authenticate, then publish the tarballs in the required order:

   ```sh
   npm login                                # answer the 2FA prompt
   bash scripts/bootstrap-npm.sh <unzipped-dir> --dry-run   # inspect first
   bash scripts/bootstrap-npm.sh <unzipped-dir>
   ```

   The script publishes the six binary packages first and the launcher last, and
   it refuses to run unless all seven tarballs are present.
5. For each of the seven packages, open Settings on npmjs.com and add a Trusted
   Publisher:
   - Organization or user: `PlanMonster`
   - Repository: `olkcli`
   - Workflow: `publish-npm.yml`
6. Leave "Publishing access" at the default. Do **not** select "Require
   two-factor authentication and disallow tokens": that turns on staged
   publishing, which makes a person approve every CI publish before consumers
   can install it.
7. Revoke the token, or run `npm logout`.

After step 7, CI holds no secret. Each publish mints a short-lived credential
from the GitHub OIDC identity.

The next tagged release must use a new version, because registry versions are
immutable. A CI re-run of a version that already exists is safe: it is skipped,
and the job still succeeds.

### Alternative: reserve the names now, ship later

Use this only to claim the seven names before the code is ready to ship. It
publishes 373-byte packages that contain `package.json` and an empty `bin/`
directory, and no binary:

```sh
node scripts/build-npm.mjs 0.0.1-bootstrap.0 \
  --scope @planmonster \
  --registry https://registry.npmjs.org \
  --repository PlanMonster/olkcli \
  --publish --skip-binary-check --tag bootstrap
git checkout -- npm/olk/package.json npm/olk-*/package.json
```

`--skip-binary-check` permits a publish with no binary. `--tag bootstrap` keeps
the placeholder off the `latest` tag, so `npm i @planmonster/olkcli` cannot
install a launcher that has no binary. Never use either option in CI.

## Release procedure

```sh
git tag npm-v0.9.5-pm.1
git push origin npm-v0.9.5-pm.1
```

The tag prefix is `npm-v`, not `v`, so it does not also fire `release.yml`
(the upstream Homebrew and MCP Registry pipeline, which cannot run on this fork).

To validate without publishing, start the workflow from the Actions tab with
`dry_run: true`. The run packs the seven tarballs and uploads them as an
artifact. A dry run does not verify registry credentials.

## Pipeline

| Job | Runner | Why |
| --- | --- | --- |
| `version` | `blacksmith-4vcpu-ubuntu-2404` | validates the version string |
| `build-linux-windows` | `blacksmith-4vcpu-ubuntu-2404` | 4 targets, `CGO_ENABLED=0`, restored Go build cache |
| `build-darwin` | `macos-latest` | needs CGO against the Keychain; Blacksmith has no macOS runners |
| `publish` | `ubuntu-latest` | npm Trusted Publishing accepts cloud-hosted runners only |

Keep the `publish` job on `ubuntu-latest`. A Blacksmith runner reports itself as
self-hosted in the OIDC claims, and npm rejects a self-hosted claim.

Expect about 10–15 minutes for a release with a warm Go build cache. A cold
cache adds roughly 8 minutes per cross-compiled target.

The publish step publishes the six binary packages first and the launcher last.
A consumer therefore never sees a launcher whose optional dependencies are
absent. The step skips a version that already exists, so a re-run after a
partial failure is safe.

## Consuming the package

### From a Daytona sandbox

```sh
npx -y @planmonster/olkcli@0.9.5-pm.1 mail list --json
```

Pin the exact version. `@latest` makes an agent runner non-reproducible.

Pass the credential and the guard rails through the environment, never through
the command line, because command lines are visible to other processes:

```
OLK_ACCESS_TOKEN=<delegated Graph token>
OLK_ACCESS_TOKEN_EXPIRES_AT=<RFC3339>
OLK_ACCOUNT_EMAIL=<UPN>
OLK_JSON=1
OLK_NO_INPUT=1
OLK_NO_WRITE=1
OLK_NO_SEND=1
OLK_WRAP_UNTRUSTED=1
OLK_CONCISE=1
OLK_ENABLE_COMMANDS=mail,calendar
```

With an injected token the CLI reads no keyring and creates no configuration
directory. If the token is expired, the CLI stops before the first request and
returns exit code 77.

Read `stdout` for the JSON envelope. Ignore `stderr`, which carries hints only.

### As an MCP server

```sh
npx -y @planmonster/olkcli@0.9.5-pm.1 mcp
```

The server is read-only by default and always wraps untrusted text.

### Baked into a sandbox image

```sh
npm i -g @planmonster/olkcli@0.9.5-pm.1
```

This removes the registry round trip from a cold start.

## Local testing

```sh
bash scripts/test-npm-package.sh
```

The script builds a host binary, stamps the packages, packs them, installs the
tarballs into a scratch project, runs `olk version` through the launcher, and
checks that a failing command still returns a non-zero exit code. It tests the
unscoped layout and the scoped layout. It restores `npm/*/package.json` on exit.

The `package` job in `ci.yml` runs this script on every pull request.
