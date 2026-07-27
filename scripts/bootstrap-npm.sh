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
# Resolve to an absolute path before building any tarball argument. npm parses a
# bare relative path like "dist-npm/pkg.tgz" as the GitHub shorthand
# <owner>/<repo> and tries to clone ssh://git@github.com/dist-npm/pkg.tgz.git,
# which fails with "code 128 ... Permission denied (publickey)". An absolute
# path (or a "./" prefix) is unambiguously a file.
dir="$(cd "$dir" && pwd)"
shift

dry_run=0
tag=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --tag)
      # Reject a missing or option-like value so `--tag --dry-run` cannot
      # silently consume `--dry-run` as the dist-tag and proceed with a real
      # publish.
      if [ "$#" -lt 2 ] || [[ "$2" == -* ]]; then
        echo "--tag requires a value" >&2
        exit 2
      fi
      tag="$2"
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# The six platform packages that must be published before the launcher. Bare
# names; the launcher's npm scope (e.g. "@planmonster/") is prepended below so
# a scoped and an unscoped build are both validated exactly.
expected_platforms=(
  olk-darwin-arm64
  olk-darwin-x64
  olk-linux-arm64
  olk-linux-x64
  olk-win32-arm64
  olk-win32-x64
)

# Read "<name>\t<version>" from a tarball's package/package.json. npm (hence
# node) is a hard dependency of this script, so parsing JSON with node is safe.
tarball_id() {
  tar -xzOf "$1" package/package.json 2>/dev/null | node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d));
    process.stdin.on("end", () => {
      try {
        const j = JSON.parse(s);
        if (!j.name || !j.version) process.exit(1);
        process.stdout.write(j.name + "\t" + j.version);
      } catch {
        process.exit(1);
      }
    });
  '
}

shopt -s nullglob
tarballs=()
for f in "$dir"/*.tgz; do tarballs+=("$f"); done
if [ "${#tarballs[@]}" -eq 0 ]; then
  echo "no .tgz tarballs found in $dir" >&2
  exit 1
fi

# Identify every tarball by the name/version inside its package.json rather than
# by filename, so an unrelated or mislabelled archive can never stand in for a
# required package.
names=()
vers=()
files=()
for f in "${tarballs[@]}"; do
  if ! pkgid="$(tarball_id "$f")"; then
    echo "cannot read package/package.json from ${f##*/}" >&2
    exit 1
  fi
  names+=("${pkgid%%$'\t'*}")
  vers+=("${pkgid##*$'\t'}")
  files+=("$f")
done

# Every tarball must carry the same version.
shared_version="${vers[0]}"
for i in "${!vers[@]}"; do
  if [ "${vers[$i]}" != "$shared_version" ]; then
    echo "tarballs disagree on version: '${names[0]}' is $shared_version but '${names[$i]}' is ${vers[$i]}" >&2
    exit 1
  fi
done

# Exactly one launcher (bare name "olkcli"); its scope fixes the scope we expect
# on the six platform packages.
launcher_tgz=""
launcher_name=""
for i in "${!names[@]}"; do
  if [ "${names[$i]##*/}" = "olkcli" ]; then
    if [ -n "$launcher_tgz" ]; then
      echo "found more than one launcher (olkcli) tarball" >&2
      exit 1
    fi
    launcher_tgz="${files[$i]}"
    launcher_name="${names[$i]}"
  fi
done
if [ -z "$launcher_tgz" ]; then
  echo "no launcher (olkcli) tarball found in $dir" >&2
  exit 1
fi
case "$launcher_name" in
  */*) scope_prefix="${launcher_name%/*}/" ;;
  *)   scope_prefix="" ;;
esac

# Each of the six expected platform packages must be present exactly once, at
# the launcher's scope.
platform_tgz=()
platform_names=()
for p in "${expected_platforms[@]}"; do
  want="${scope_prefix}${p}"
  match=""
  for i in "${!names[@]}"; do
    if [ "${names[$i]}" = "$want" ]; then
      if [ -n "$match" ]; then
        echo "found more than one tarball named $want" >&2
        exit 1
      fi
      match="${files[$i]}"
    fi
  done
  if [ -z "$match" ]; then
    echo "missing expected platform package: $want" >&2
    exit 1
  fi
  platform_tgz+=("$match")
  platform_names+=("$want")
done

# Launcher + six platforms = seven; any other count means an unexpected extra.
if [ "${#tarballs[@]}" -ne 7 ]; then
  echo "expected exactly 7 tarballs (1 launcher + 6 platform) in $dir, found ${#tarballs[@]}:" >&2
  printf '  %s\n' "${names[@]}" >&2
  exit 1
fi

echo "Version: $shared_version"
echo "Binary packages (published first):"
printf '  %s\n' "${platform_names[@]}"
echo "Launcher (published last):"
echo "  $launcher_name"
echo

# A published version is immutable, so re-running after a partial bootstrap must
# skip names already at $shared_version instead of aborting on the first one.
already_published() {
  local existing
  existing="$(npm view "$1@$shared_version" version 2>/dev/null || true)"
  [ "$existing" = "$shared_version" ]
}

publish() {
  local f="$1" name="$2"
  if already_published "$name"; then
    echo "skip $name@$shared_version (already published)"
    return 0
  fi
  local args=(publish "$f" --access public)
  [ -n "$tag" ] && args+=(--tag "$tag")
  if [ "$dry_run" -eq 1 ]; then
    echo "DRY RUN: npm ${args[*]}"
    return 0
  fi
  echo "==> npm ${args[*]}"
  npm "${args[@]}"
}

for i in "${!platform_tgz[@]}"; do
  publish "${platform_tgz[$i]}" "${platform_names[$i]}"
done
publish "$launcher_tgz" "$launcher_name"

echo
if [ "$dry_run" -eq 1 ]; then
  echo "Dry run complete. Nothing was published."
else
  echo "Bootstrap complete. Now add a Trusted Publisher to each of the seven"
  echo "packages (PlanMonster / olkcli / publish-npm.yml), then revoke the token."
fi
