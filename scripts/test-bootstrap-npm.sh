#!/usr/bin/env bash
# Regression test for scripts/bootstrap-npm.sh.
#
#   bash scripts/test-bootstrap-npm.sh
#
# Builds the seven wrapper tarballs (no Go binaries needed — npm packs the
# placeholder layout fine), then exercises the bootstrap script in --dry-run
# mode against a *relative* directory.
#
# The main assertion is that every `npm publish` argument is an absolute path.
# npm parses a bare relative path such as "dist-npm/pkg.tgz" as the GitHub
# shorthand <owner>/<repo> and tries to clone
# ssh://git@github.com/dist-npm/pkg.tgz.git, failing with
# "npm error code 128 ... Permission denied (publickey)".
#
# Also asserts the publish order (six platform packages, launcher last) and the
# input validation (wrong tarball count, mixed versions, missing platform).
set -euo pipefail

VERSION="${1:-0.0.0-bootstrap-test.1}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

tmp="$(mktemp -d)"
cleanup() {
  git checkout -- npm/olk/package.json npm/olk-*/package.json 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

echo "==> pack 7 tarballs at $VERSION"
node scripts/build-npm.mjs "$VERSION" \
  --scope @planmonster \
  --registry https://registry.npmjs.org \
  --repository PlanMonster/olkcli >/dev/null
mkdir -p "$tmp/dist-npm"
npm pack --silent --pack-destination "$tmp/dist-npm" ./npm/olk-* ./npm/olk >/dev/null
git checkout -- npm/olk/package.json npm/olk-*/package.json
count="$(ls "$tmp"/dist-npm/*.tgz | wc -l | tr -d ' ')"
[ "$count" -eq 7 ] || {
  echo "expected 7 tarballs, packed $count" >&2
  exit 1
}

# Run from the parent directory with a RELATIVE argument — the exact shape that
# triggered the git-shorthand misparse.
echo "==> dry run with a relative directory argument"
out="$( cd "$tmp" && bash "$root/scripts/bootstrap-npm.sh" dist-npm --dry-run )"
echo "$out" | sed 's/^/    /'

echo "==> assert every publish argument is an absolute path"
bad=0
while IFS= read -r line; do
  arg="$(printf '%s' "$line" | sed -n 's/.*npm publish \([^ ]*\).*/\1/p')"
  [ -n "$arg" ] || continue
  case "$arg" in
    /*) ;;
    *)
      echo "    NOT ABSOLUTE: $arg" >&2
      bad=1
      ;;
  esac
done <<< "$(printf '%s\n' "$out" | grep 'DRY RUN: npm publish')"
[ "$bad" -eq 0 ] || {
  echo "npm would parse a relative path as a git shorthand" >&2
  exit 1
}

echo "==> assert publish order: 6 platform packages, launcher last"
order="$(printf '%s\n' "$out" | grep -c 'DRY RUN: npm publish')"
[ "$order" -eq 7 ] || {
  echo "expected 7 publish commands, saw $order" >&2
  exit 1
}
last="$(printf '%s\n' "$out" | grep 'DRY RUN: npm publish' | tail -1)"
case "$last" in
  *olkcli-*) ;;
  *)
    echo "launcher must be published last, saw: $last" >&2
    exit 1
    ;;
esac

expect_failure() { # description, dir
  local desc="$1" d="$2"
  if ( cd "$tmp" && bash "$root/scripts/bootstrap-npm.sh" "$d" --dry-run >/dev/null 2>&1 ); then
    echo "    expected failure: $desc" >&2
    exit 1
  fi
  echo "    rejected: $desc"
}

echo "==> assert input validation"
cp -r "$tmp/dist-npm" "$tmp/extra"
cp "$tmp/extra"/*olkcli-*.tgz "$tmp/extra/unrelated-9.9.9.tgz"
expect_failure "an extra/unexpected tarball" extra

cp -r "$tmp/dist-npm" "$tmp/missing"
rm -f "$tmp/missing"/*olk-win32-arm64*.tgz
expect_failure "a missing platform package" missing

cp -r "$tmp/dist-npm" "$tmp/empty-ish"
rm -f "$tmp/empty-ish"/*.tgz
expect_failure "no tarballs at all" empty-ish

if ( cd "$tmp" && bash "$root/scripts/bootstrap-npm.sh" dist-npm --tag --dry-run >/dev/null 2>&1 ); then
  echo "    expected failure: --tag consuming a following flag" >&2
  exit 1
fi
echo "    rejected: --tag with an option-like value"

echo
echo "bootstrap script test: PASS"
