#!/usr/bin/env bash
# Publish the newest green CI build to the public GitHub sideload source.
#
#   Tools/release/publish_github.sh            # newest successful run on main
#   Tools/release/publish_github.sh 42100765552
#   NOTES="what changed" Tools/release/publish_github.sh
#
#   # and, on the host that also serves the tailnet mirror:
#   MIRROR_TO=/srv/hermes-apps-dist MIRROR_BASE_URL=https://host.example.ts.net:8444 \
#     Tools/release/publish_github.sh
#
# The mirror half is `Tools/release/publish_dist.py`, which stages atomically, generates the mirror's
# manifests from the staged file, and verifies them over the wire before this script exits 0.
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
# One token source for the whole publish. `gh auth status` on this host reports "not logged into any
# GitHub hosts" while `hosts.yml` holds a working token, so the token is read from the file rather
# than assumed to be in the environment — a publish that dies at the last step having already pushed
# a release is worse than one that refuses to start.
if [ -z "${GITHUB_TOKEN:-}" ]; then
  GITHUB_TOKEN="${GH_TOKEN:-}"
  if [ -z "$GITHUB_TOKEN" ] && [ -r "${HOME}/.config/gh/hosts.yml" ]; then
    GITHUB_TOKEN=$(python3 -c "import re,pathlib;print(re.search(r'oauth_token:\s*(\S+)', pathlib.Path('${HOME}/.config/gh/hosts.yml').read_text()).group(1))")
  fi
  [ -n "$GITHUB_TOKEN" ] || {
    echo "no GitHub token: set GH_TOKEN or run 'gh auth login'" >&2
    exit 1
  }
  export GITHUB_TOKEN
fi

# The macOS download in `docs/APPS.md` lives in a separate Pages repo. This flag used to be opt-in
# and the documented publish command never set it, so the *only public* macOS link served a build
# from 2026-11-11 while the release was current — twice, the second time on 2026-11-16, with a comment
# right here claiming it was part of the publish. It is not opt-in any more: the repo is named below,
# the image is published from the same artifact as the release, and `DOWNLOADS_REPO=` is the explicit
# way to skip it.
DOWNLOADS_REPO=${DOWNLOADS_REPO-macblizzard/hermey-downloads}
DOWNLOAD_ARGS=()
if [ -n "$DOWNLOADS_REPO" ]; then
  DOWNLOAD_ARGS=(--downloads-repo "$DOWNLOADS_REPO")
fi

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
MAC=$(find "$TMP" -name '*.dmg' | head -1)
[ -n "$IPA" ] || { echo "run $RUN_ID has no .ipa artifact" >&2; exit 1; }

python3 Tools/release/publish_altstore.py \
  --ipa "$IPA" \
  ${MAC:+--mac-dmg "$MAC"} \
  --repo "$REPO" \
  ${MIRROR_ARGS[@]+"${MIRROR_ARGS[@]}"} \
  ${DOWNLOAD_ARGS[@]+"${DOWNLOAD_ARGS[@]}"} \
  --notes "${NOTES:-Build from CI run $RUN_ID.}"

echo
echo "add this source once in your sideloading app — later releases appear there as updates:"
echo "  https://github.com/$REPO/releases/latest/download/altstore.json"
