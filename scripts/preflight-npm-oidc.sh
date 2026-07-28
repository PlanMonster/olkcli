#!/usr/bin/env bash
# Preflight: verify npm Trusted Publishing works for every package we are about
# to publish, before publishing any of them.
#
#   bash scripts/preflight-npm-oidc.sh <scope> [registry]
#
# Why this exists. npm checks Trusted Publishing **per package**, by exchanging a
# GitHub OIDC token at
#
#   POST /-/npm/v1/oidc/token/exchange/package/<escaped-name>
#
# and npm's oidc.js swallows a failed exchange: it logs at `verbose` level and
# returns, then `npm publish` falls back to whatever `_authToken` is configured.
# actions/setup-node writes the placeholder XXXXX-XXXXX-XXXXX-XXXXX there, so the
# registry answers:
#
#   npm error 404 Not Found - PUT https://registry.npmjs.org/@scope%2fpkg
#
# A 404 that actually means "no trusted publisher for this package". Worse, the
# packages publish one at a time, so package 4 of 7 failing leaves a half-released
# version — and npm versions are immutable, so that cannot be repaired in place.
#
# This script exchanges a token for all seven names up front and reports exactly
# which ones are not ready.
set -euo pipefail

scope="${1:-@planmonster}"
registry="${2:-https://registry.npmjs.org}"
scope="${scope#@}"

if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  echo "preflight: no GitHub OIDC token available." >&2
  echo "  This must run in GitHub Actions with 'permissions: id-token: write'." >&2
  exit 2
fi

host="$(printf '%s' "$registry" | sed -E 's#^https?://##; s#/.*$##')"
audience="npm:${host}"

echo "registry: $registry"
echo "audience: $audience"
echo "scope:    @$scope"
echo

# Request the ID token once; the audience is per-registry, not per-package.
id_token="$(curl -sS \
  -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  -H "Accept: application/json" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience}" |
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);if(!j.value){console.error("no id_token in response");process.exit(1)}process.stdout.write(j.value)})')"

if [ -z "$id_token" ]; then
  echo "preflight: could not obtain a GitHub ID token" >&2
  exit 1
fi
echo "obtained GitHub ID token (${#id_token} chars)"
echo

packages=(
  "olkcli"
  "olk-darwin-arm64"
  "olk-darwin-x64"
  "olk-linux-arm64"
  "olk-linux-x64"
  "olk-win32-arm64"
  "olk-win32-x64"
)

not_ready=()
for p in "${packages[@]}"; do
  full="@${scope}/${p}"
  escaped="@${scope}%2f${p}"
  body="$(mktemp)"
  code="$(curl -sS -o "$body" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${id_token}" \
    -H "Accept: application/json" \
    -H "Content-Length: 0" \
    "${registry}/-/npm/v1/oidc/token/exchange/package/${escaped}")"

  # npm currently returns 201 Created for a successful exchange. Accept any
  # successful 2xx response so the preflight follows HTTP semantics rather
  # than depending on one registry implementation detail.
  if [[ "$code" =~ ^2[0-9]{2}$ ]] && grep -q '"token"' "$body"; then
    printf '  %-34s READY\n' "$full"
  else
    msg="$(node -e '
      const fs=require("fs");
      try{const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(j.message||j.error||JSON.stringify(j).slice(0,200))}
      catch{process.stdout.write(fs.readFileSync(process.argv[1],"utf8").slice(0,200))}
    ' "$body" 2>/dev/null || echo "unreadable response")"
    printf '  %-34s NOT READY  (http %s) %s\n' "$full" "$code" "$msg"
    not_ready+=("$full")
  fi
  rm -f "$body"
done

echo
if [ "${#not_ready[@]}" -gt 0 ]; then
  cat >&2 <<EOF
preflight FAILED: ${#not_ready[@]} of ${#packages[@]} packages cannot publish via OIDC.

Fix each one at:
  https://www.npmjs.com/package/<name>/access

  Trusted Publisher -> GitHub Actions
    Organization or user:  ${GITHUB_REPOSITORY%%/*}
    Repository:            ${GITHUB_REPOSITORY##*/}
    Workflow filename:     publish-npm.yml
    Environment:           (leave empty)

Not ready:
EOF
  printf '  %s\n' "${not_ready[@]}" >&2
  exit 1
fi

echo "preflight OK: all ${#packages[@]} packages can publish via OIDC."
