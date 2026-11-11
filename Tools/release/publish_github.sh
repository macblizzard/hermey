#!/usr/bin/env bash
# Publish the newest green CI build to the public GitHub sideload source.
#
#   Tools/release/publish_github.sh            # newest successful run on main
#   Tools/release/publish_github.sh 42100765552
#   NOTES="what changed" Tools/release/publish_github.sh
#
#   # and, on the host that also serves the tailnet mirror:
#   MIRROR_TO=/srv/hermey-dist MIRROR_BASE_URL=https://host.example.ts.net:8444 \
#     Tools/release/publish_github.sh
#
# The IPA becomes a release asset, and `altstore.json` is written to the release and to `gh-pages`,
# so the install URL works from anywhere — no Tailscale, no self-hosted file server, no cache to
# fight. `macblizzard/hermey` is the only shipping target; the predecessor repo is gone.
set -euo pipefail

cd "$(dirname "$0")/../.."
RUN_ID=${1:-}
REPO=${REPO:-macblizzard/hermey}

# A mirror is a *second* copy for devices that cannot reach GitHub's release CDN, so it is optional.
# A run that names one must also name the URL it is served on: left to itself the publish tool fills
# in a placeholder host, and a mirrored manifest whose downloads point at a name nobody has looks
# exactly like a successful publish. That is the failure this guard exists to make impossible.
MIRROR_ARGS=()
if [ -n "${MIRROR_TO:-}" ]; then
  [ -n "${MIRROR_BASE_URL:-}" ] || {
    echo "MIRROR_TO is set but MIRROR_BASE_URL is not — the mirror's manifest would point at a host that does not exist" >&2
    exit 1
  }
  MIRROR_ARGS=(--mirror-to "$MIRROR_TO" --mirror-base-url "$MIRROR_BASE_URL")
fi

if [ -z "$RUN_ID" ]; then
  RUN_ID=$(gh run list --workflow=ci --branch=main --status=success --limit=1 --json databaseId --jq '.[0].databaseId')
fi
[ -n "$RUN_ID" ] || { echo "no successful ci run found" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
gh run download "$RUN_ID" -D "$TMP" >/dev/null
IPA=$(find "$TMP" -name '*.ipa' | head -1)
MAC=$(find "$TMP" -name '*.zip' | head -1)
[ -n "$IPA" ] || { echo "run $RUN_ID has no .ipa artifact" >&2; exit 1; }

python3 Tools/release/publish_altstore.py \
  --ipa "$IPA" \
  ${MAC:+--mac-zip "$MAC"} \
  --repo "$REPO" \
  ${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"} \
  --notes "${NOTES:-Build from CI run $RUN_ID.}"

echo
echo "add this source once in your sideloading app — later releases appear there as updates:"
echo "  https://github.com/$REPO/releases/latest/download/altstore.json"
