#!/usr/bin/env bash
# End-to-end test of the npm wrapper packages.
#
#   bash scripts/test-npm-package.sh
#
# Builds a host binary, stamps the wrapper packages, packs them, installs the
# tarballs into a scratch project, and runs `olk version` through the JS
# launcher. Asserts the launcher resolved the per-platform optional dependency
# and returned the stamped version.
#
# Runs twice: unscoped (the upstream npmjs.org layout) and scoped (the fork
# layout, e.g. @planmonster/olkcli). This is what makes packaging breakage a
# pull-request failure instead of a tag-time failure.
#
# Restores npm/*/package.json on exit — stamping mutates them in place.
set -euo pipefail

VERSION="${1:-0.0.0-test.1}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

goos="$(go env GOOS)"
goarch="$(go env GOARCH)"
case "$goos" in
  darwin | linux) platform="$goos" ;;
  windows) platform="win32" ;;
  *)
    echo "unsupported GOOS for this test: $goos" >&2
    exit 2
    ;;
esac
pkgdir="npm/olk-${platform}-${goarch/amd64/x64}"
exe="olk"
[ "$platform" = "win32" ] && exe="olk.exe"

if [ ! -d "$pkgdir" ]; then
  echo "no wrapper package for this host: $pkgdir" >&2
  exit 2
fi

tmp="$(mktemp -d)"
cleanup() {
  git checkout -- npm/olk/package.json npm/olk-*/package.json 2>/dev/null || true
  rm -rf "$tmp" "$pkgdir/bin/$exe"
}
trap cleanup EXIT

echo "==> build $goos/$goarch -> $pkgdir/bin/$exe"
mkdir -p "$pkgdir/bin"
CGO_ENABLED=0 go build \
  -ldflags "-s -w -X github.com/rlrghb/olkcli/internal/cmd.Version=$VERSION" \
  -o "$pkgdir/bin/$exe" ./cmd/olk

run_case() {
  local label="$1"
  shift
  local dest="$tmp/$label"
  mkdir -p "$dest"

  echo
  echo "==> case: $label"
  node scripts/build-npm.mjs "$VERSION" "$@"

  local main_name
  main_name="$(node -p "require('./npm/olk/package.json').name")"
  local plat_name
  plat_name="$(node -p "require('./$pkgdir/package.json').name")"
  echo "    launcher=$main_name platform=$plat_name"

  # The launcher must not hardcode the platform package name; assert it is
  # listed as an optional dependency at the stamped version.
  node -e "
    const p = require('./npm/olk/package.json');
    const want = '$plat_name', v = '$VERSION';
    if (p.optionalDependencies[want] !== v) {
      console.error('optionalDependencies missing ' + want + '@' + v);
      process.exit(1);
    }
  "

  npm pack --silent --pack-destination "$dest" "./$pkgdir" ./npm/olk >/dev/null
  local plat_tgz main_tgz
  plat_tgz="$(ls "$dest"/*olk-"$platform"-"${goarch/amd64/x64}"-"$VERSION".tgz)"
  main_tgz="$(ls "$dest"/*olkcli-"$VERSION".tgz)"
  echo "    packed $(basename "$plat_tgz") ($(du -h "$plat_tgz" | cut -f1))"

  ( cd "$dest" && npm init -y >/dev/null 2>&1 )
  # --omit=optional: the other five platform packages do not exist at this
  # version yet. The one we need is installed explicitly, as a direct
  # dependency, so the launcher still resolves it.
  ( cd "$dest" && npm install --omit=optional --no-audit --no-fund --silent \
      "$plat_tgz" "$main_tgz" >/dev/null )

  local got
  got="$( cd "$dest" && ./node_modules/.bin/olk version --json )"
  echo "    olk version --json -> $got"
  node -e "
    const got = JSON.parse(process.argv[1]);
    if (got.version !== '$VERSION') {
      console.error('want version $VERSION, got ' + got.version);
      process.exit(1);
    }
  " "$got"

  # Exit-code propagation through the launcher matters for the control plane.
  local code=0
  ( cd "$dest" && ./node_modules/.bin/olk --definitely-not-a-flag >/dev/null 2>&1 ) || code=$?
  if [ "$code" -eq 0 ]; then
    echo "launcher did not propagate a non-zero exit code" >&2
    exit 1
  fi
  echo "    exit-code propagation ok (got $code)"

  git checkout -- npm/olk/package.json npm/olk-*/package.json
  echo "    PASS: $label"
}

run_case unscoped
run_case scoped --scope @planmonster --registry https://registry.npmjs.org \
  --repository PlanMonster/olkcli

echo
echo "npm package test: PASS"
