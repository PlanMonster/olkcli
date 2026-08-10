# PlanMonster GitHub Release Assets

NanoClaw and other snapshot installers can consume native binaries from a
fork-owned GitHub Release without invoking any upstream publication channel.

## Tag and asset contract

Push a tag matching:

```text
olk-pm-v<upstream-major>.<upstream-minor>.<upstream-patch>.<fork-revision>
```

For the first PlanMonster build based on upstream 1.11.0, use
`olk-pm-v1.11.0.1`. Increment only the final fork revision for another build of
the same upstream version. This namespace cannot match either upstream
`release.yml` (`v*`) or the fork npm workflow (`npm-v*`).

The workflow creates a GitHub Release with six archives and `checksums.txt`.
For `olk-pm-v1.11.0.1`, NanoClaw's Linux AMD64 asset is exactly:

```text
olk_1.11.0.1_linux_amd64.tar.gz
```

The archive contains one executable named `olk`. Other assets use the same
`olk_<version>_<os>_<arch>` shape; Windows archives are `.zip`, and all others
are `.tar.gz`.

## Verify and install Linux AMD64

```bash
tag=olk-pm-v1.11.0.1
version=${tag#olk-pm-v}
asset="olk_${version}_linux_amd64.tar.gz"

gh release download "$tag" \
  --repo PlanMonster/olkcli \
  --pattern "$asset" \
  --pattern checksums.txt
grep "  ${asset}$" checksums.txt | sha256sum --check -
tar -xzf "$asset"
./olk version --json
```

Do not install an asset unless its checksum passes.

## Release procedure

1. Merge the tested release PR to PlanMonster `main` without rewriting history.
2. Confirm CI passed on the merge commit and the working tree is clean.
3. Create the new fork-owned tag on that exact merge commit:
   `git tag olk-pm-v1.11.0.1`.
4. Push only that tag: `git push origin olk-pm-v1.11.0.1`.
5. Watch **Release (GitHub assets, PlanMonster)**. It validates the tag, builds
   Linux/Windows with CGO disabled and macOS with CGO enabled, checks all six
   archives, smoke-tests Linux AMD64, generates and verifies SHA-256 checksums,
   and creates one GitHub Release.
6. Download the Linux AMD64 archive and `checksums.txt`, then independently run
   the verification commands above before updating NanoClaw's pinned snapshot.

The workflow does not call GoReleaser or either existing publication workflow.
It cannot publish Homebrew, npm, or MCP Registry artifacts. It also refuses to
overwrite an existing GitHub Release because `gh release create` fails when the
tag already has one. Never move or reuse a release tag; increment the final fork
revision instead.
