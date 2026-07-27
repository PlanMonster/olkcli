#!/usr/bin/env bash
# One-time npm bootstrap: publish pre-packed tarballs by hand.
#
#   bash scripts/bootstrap-npm.sh <dir-with-tarballs> [--dry-run] [--tag <tag>]
#
# npm Trusted Publishing can only be configured on a package that already
# exists, so the first publish of each of the seven names cannot come from CI.
# This script does that first publish from a maintainer's machine, in the
# correct order, using tarballs built by CI.
#
# Get the tarballs without building anything locally (no Mac needed):
#   1. Actions -> "Publish (npm, @planmonster)" -> Run workflow
#      version: <the version you intend to ship>, dry_run: true
#   2. Download the "npm-tarballs" artifact and unzip it.
#   3. npm login          (answer the 2FA prompt)
#   4. bash scripts/bootstrap-npm.sh <unzipped-dir>
#   5. Add a Trusted Publisher to each of the seven packages on npmjs.com:
#      PlanMonster / olkcli / publish-npm.yml
#   6. Revoke the token or log out. CI never needs one again.
#
# Ordering is enforced: the six binary packages go first and the launcher goes
# last, so no consumer can ever resolve a launcher whose optional dependencies
# are absent.
set -euo pipefail

dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "usage: bash scripts/bootstrap-npm.sh <dir-with-tarballs> [--dry-run] [--tag <tag>]" >&2
  exit 2
fi
shift

dry_run=0
tag=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --tag)
      shift
      tag="${1:-}"
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

shopt -s nullglob
platform_tgz=()
launcher_tgz=""
for f in "$dir"/*.tgz; do
  name="$(basename "$f")"
  # The launcher package is *olkcli-<version>.tgz; the binary packages are
  # *olk-<os>-<arch>-<version>.tgz.
  if [[ "$name" == *olkcli-* ]]; then
    launcher_tgz="$f"
  else
    platform_tgz+=("$f")
  fi
done

if [ "${#platform_tgz[@]}" -ne 6 ] || [ -z "$launcher_tgz" ]; then
  echo "expected 6 binary tarballs + 1 launcher tarball in $dir, found:" >&2
  printf '  %s\n' "$dir"/*.tgz >&2
  exit 1
fi

echo "Binary packages (published first):"
printf '  %s\n' "${platform_tgz[@]##*/}"
echo "Launcher (published last):"
echo "  ${launcher_tgz##*/}"
echo

publish() {
  local f="$1"
  local args=(publish "$f" --access public)
  [ -n "$tag" ] && args+=(--tag "$tag")
  if [ "$dry_run" -eq 1 ]; then
    echo "DRY RUN: npm ${args[*]}"
    return 0
  fi
  echo "==> npm ${args[*]}"
  npm "${args[@]}"
}

for f in "${platform_tgz[@]}"; do publish "$f"; done
publish "$launcher_tgz"

echo
if [ "$dry_run" -eq 1 ]; then
  echo "Dry run complete. Nothing was published."
else
  echo "Bootstrap complete. Now add a Trusted Publisher to each of the seven"
  echo "packages (PlanMonster / olkcli / publish-npm.yml), then revoke the token."
fi
