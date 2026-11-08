#!/usr/bin/env bash
# Republish the newest green CI build as a sideload source.
#
#   Tools/release/publish_latest.sh            # newest successful run on main
#   Tools/release/publish_latest.sh 42039367061
#
# Run this on the host that serves the source directory. It downloads the artifacts of one
# successful CI run, then hands them to publish_source.py, which reads the version out of the
# IPA itself. Because CI stamps CFBundleVersion with the workflow run number, every republish
# is strictly newer than the last, so a sideloading app offers it as an update.
set -euo pipefail

cd "$(dirname "$0")/../.."
OUT=${OUT:-/srv/hermey-dist}
BASE_URL=${BASE_URL:-https://hermes.example.ts.net:8444}
RUN_ID=${1:-}

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

NOTES=${NOTES:-"Build from CI run $RUN_ID."}
python3 Tools/release/publish_source.py \
  --ipa "$IPA" \
  ${MAC:+--mac-zip "$MAC"} \
  --base-url "$BASE_URL" \
  --out "$OUT" \
  --notes "$NOTES"

echo
echo "source: $BASE_URL/source.json"
echo "add that URL once in your sideloading app; later runs appear as updates."
