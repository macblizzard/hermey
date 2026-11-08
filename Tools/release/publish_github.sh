#!/usr/bin/env bash
# Publish the newest green CI build to the public GitHub sideload source.
#
#   Tools/release/publish_github.sh            # newest successful run on main
#   Tools/release/publish_github.sh 42100765552
#   NOTES="what changed" Tools/release/publish_github.sh
#
# The IPA becomes a release asset and `altstore.json` in macblizzard/hermes-altstore is updated, so
# the install URL works from anywhere — no Tailscale, no self-hosted file server, no cache to fight.
set -euo pipefail

cd "$(dirname "$0")/../.."
RUN_ID=${1:-}
REPO=${REPO:-macblizzard/hermes-altstore}

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
  --mirror-to "${OUT:-/srv/hermey-dist}" \
  --notes "${NOTES:-Build from CI run $RUN_ID.}"

echo
echo "add this URL once in your installer:"
echo "  https://raw.githubusercontent.com/$REPO/main/altstore.json"
