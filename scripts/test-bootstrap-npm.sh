#!/usr/bin/env bash
# Regression tests for scripts/bootstrap-npm.sh and the publish arguments that
# scripts/build-npm.mjs produces.
#
#   bash scripts/test-bootstrap-npm.sh
#
# Packs the seven wrapper tarballs (no Go binaries needed — npm packs the
# placeholder layout fine) and then asserts three things that broke a real
# bootstrap attempt:
#
#  1. Every `npm publish` argument is an absolute path. npm parses a bare
#     relative path such as "dist-npm/pkg.tgz" as the GitHub shorthand
#     <owner>/<repo> and tries to clone
#     ssh://git@github.com/dist-npm/pkg.tgz.git, failing with
#     "npm error code 128 ... Permission denied (publickey)".
#
#  2. Every publish carries an explicit dist-tag. npm >= 11 refuses to publish a
#     prerelease version unless the tag is explicit, and every version of this
#     fork is a prerelease (the -pm.N suffix):
#     "npm error You must specify a tag using --tag when publishing a prerelease
#     version."
#
#  3. The publish order (six platform packages, launcher last) and the input
#     validation: an extra tarball, a missing platform package, an empty
#     directory, and --tag swallowing a following flag.
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

stamp() {
  node scripts/build-npm.mjs "$VERSION" \
    --scope @planmonster \
    --registry https://registry.npmjs.org \
    --repository PlanMonster/olkcli "$@" >/dev/null
}

echo "==> pack 7 tarballs at $VERSION"
stamp
mkdir -p "$tmp/dist-npm"
npm pack --silent --pack-destination "$tmp/dist-npm" ./npm/olk-* ./npm/olk >/dev/null
count="$(ls "$tmp"/dist-npm/*.tgz | wc -l | tr -d ' ')"
[ "$count" -eq 7 ] || {
  echo "expected 7 tarballs, packed $count" >&2
  exit 1
}

echo "==> assert build-npm.mjs stamps publishConfig.tag"
stamped_tag="$(node -p 'require("./npm/olk/package.json").publishConfig.tag')"
[ "$stamped_tag" = "latest" ] || {
  echo "publishConfig.tag is '$stamped_tag', want 'latest'" >&2
  exit 1
}
echo "    publishConfig.tag=latest"
git checkout -- npm/olk/package.json npm/olk-*/package.json

# Run from the parent directory with a RELATIVE argument — the exact shape that
# triggered the git-shorthand misparse.
echo "==> dry run with a relative directory argument"
out="$( cd "$tmp" && bash "$root/scripts/bootstrap-npm.sh" dist-npm --dry-run )"
printf '%s\n' "$out" | sed 's/^/    /'

echo "==> assert every publish argument is an absolute path"
bad=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  arg="$(printf '%s' "$line" | sed -n 's/.*npm publish \([^ ]*\).*/\1/p')"
  [ -n "$arg" ] || continue
  case "$arg" in
    /*) ;;
    *)
      echo "    NOT ABSOLUTE: $arg" >&2
      bad=1
      ;;
  esac
done <<< "$(printf '%s\n' "$out" | grep 'DRY RUN: npm publish' || true)"
[ "$bad" -eq 0 ] || {
  echo "npm would parse a relative path as a git shorthand" >&2
  exit 1
}
echo "    all absolute"

echo "==> assert every publish carries an explicit --tag"
untagged="$(printf '%s\n' "$out" | grep 'DRY RUN: npm publish' | grep -v -- '--tag ' || true)"
[ -z "$untagged" ] || {
  echo "    missing --tag: $untagged" >&2
  exit 1
}
echo "    all tagged"

echo "==> assert publish order: 6 platform packages, launcher last"
n="$(printf '%s\n' "$out" | grep -c 'DRY RUN: npm publish')"
[ "$n" -eq 7 ] || {
  echo "expected 7 publish commands, saw $n" >&2
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
echo "    order ok"

# Prove the prerelease rule against a real npm that enforces it. The system npm
# may predate 11, so fall back to a pinned npm@11 through npx.
echo "==> live npm check (prerelease tag rule)"
npm_bin=()
npm_major="$(npm --version 2>/dev/null | cut -d. -f1 || echo 0)"
if [ "${npm_major:-0}" -ge 11 ]; then
  npm_bin=(npm)
elif npx --yes npm@11 --version >/dev/null 2>&1; then
  npm_bin=(npx --yes npm@11)
else
  echo "    SKIP: npm $npm_major < 11 and npm@11 unavailable"
fi

if [ "${#npm_bin[@]}" -gt 0 ]; then
  probe="$tmp/dist-npm/$(cd "$tmp/dist-npm" && ls | grep -- '-linux-x64-' | head -1)"
  if ! "${npm_bin[@]}" publish "$probe" --dry-run --access public >/dev/null 2>&1; then
    echo "    stamped tarball was rejected by npm publish --dry-run" >&2
    exit 1
  fi
  echo "    npm accepts the stamped prerelease tarball"

  # Strip publishConfig.tag and confirm npm rejects it, proving the stamp is
  # what makes the publish work.
  strip="$tmp/strip"
  mkdir -p "$strip" && tar -xzf "$probe" -C "$strip"
  node -e '
    const fs = require("fs");
    const p = process.argv[1] + "/package/package.json";
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    delete j.publishConfig.tag;
    fs.writeFileSync(p, JSON.stringify(j, null, 2));
  ' "$strip"
  ( cd "$strip" && tar -czf "$tmp/untagged.tgz" package )
  if "${npm_bin[@]}" publish "$tmp/untagged.tgz" --dry-run --access public >/dev/null 2>&1; then
    echo "    expected npm to reject an untagged prerelease publish" >&2
    exit 1
  fi
  echo "    npm rejects the same tarball without publishConfig.tag"
fi

expect_failure() { # description, dir, extra args...
  local desc="$1" d="$2"
  shift 2
  if ( cd "$tmp" && bash "$root/scripts/bootstrap-npm.sh" "$d" --dry-run "$@" >/dev/null 2>&1 ); then
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

mkdir -p "$tmp/empty-ish"
expect_failure "no tarballs at all" empty-ish

if ( cd "$tmp" && bash "$root/scripts/bootstrap-npm.sh" dist-npm --tag --dry-run >/dev/null 2>&1 ); then
  echo "    expected failure: --tag consuming a following flag" >&2
  exit 1
fi
echo "    rejected: --tag with an option-like value"

echo
echo "bootstrap script test: PASS"
