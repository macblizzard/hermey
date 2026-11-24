#!/usr/bin/env bash
# Self-update smoke: the whole press against a release server on this machine.
#
# Proves, on a real process rather than in a unit test:
#
#   * GET /v1/update reports the running version and the newest published `hermeyd-v*` tag, and
#     ignores an app release that carries no host binary;
#   * POST /v1/update answers 202 before downloading, refuses a second press while one runs;
#   * the download is checked against SHA256SUMS, the previous build is kept beside the binary, the
#     verified one is renamed in, `update-state.json` records `pending`, and the service exits for
#     systemd to start the new build;
#   * two boots onto a build that will not stay up put the previous bytes back and mark the record
#     `rolled-back` — with no network involved in that step.
#
# Nothing real is replaced: a copy of the binary is the "installed" one, and both the feed and the
# assets are served from a temporary directory over loopback.
#
#   scripts/smoke-self-update.sh              # tests hermeyd/target/release/hermeyd
#   scripts/smoke-self-update.sh path/to/bin  # or a binary you built somewhere else
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
BIN="${1:-$ROOT/hermeyd/target/release/hermeyd}"
VERSION="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$ROOT/hermeyd/Cargo.toml" | head -n 1)"

if [ ! -x "$BIN" ]; then
  echo "no hermeyd binary at $BIN — build one first: (cd hermeyd && cargo build --release)" >&2
  exit 2
fi
if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
  echo "this smoke publishes a linux-x86_64 asset; this host is $(uname -s) $(uname -m)" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hermeyd-self-update.XXXXXX")"
HTTP_PID=""; SVC_PID=""
cleanup() {
  [ -n "$SVC_PID" ] && kill "$SVC_PID" 2>/dev/null
  [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }
# One JSON field out of a file, or the empty string.
jget() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));v=d.get(sys.argv[2]);
print("" if v is None else v)' "$1" "$2" 2>/dev/null; }

PORT=$(( (RANDOM % 2000) + 18800 ))
SERVE=$(( PORT + 1 ))
API="http://127.0.0.1:$SERVE"
STATE="$WORK/state"
BINDIR="$WORK/bin"
TARGET="$BINDIR/hermeyd"
ASSET="hermeyd-v9.9.9/hermeyd-linux-x86_64"
SHA="$(sha256sum "$BIN" | cut -d' ' -f1)"

mkdir -p "$BINDIR" "$STATE" "$WORK/srv/dl/hermeyd-v9.9.9"
cp "$BIN" "$TARGET"
# A distinguishable "next build": same program, different bytes, so every sha comparison means
# something. (An ELF tolerates a trailing comment; nothing here executes it.)
cp "$BIN" "$WORK/srv/dl/$ASSET"
printf '\n# 9.9.9\n' >> "$WORK/srv/dl/$ASSET"
(cd "$WORK/srv/dl/hermeyd-v9.9.9" && sha256sum hermeyd-linux-x86_64 > SHA256SUMS)
NEW_SHA="$(sha256sum "$WORK/srv/dl/$ASSET" | cut -d' ' -f1)"

cat > "$WORK/srv/releases.json" <<JSON
[
  {"tag_name":"v0.1.700","draft":false,"prerelease":false,"html_url":"https://example.invalid/app"},
  {"tag_name":"hermeyd-v0.0.1","draft":false,"prerelease":false,"html_url":"https://example.invalid/old"},
  {"tag_name":"hermeyd-v10.0.0","draft":true,"prerelease":false,"html_url":"https://example.invalid/draft"},
  {"tag_name":"hermeyd-v9.9.10-rc1","draft":false,"prerelease":true,"html_url":"https://example.invalid/rc"},
  {"tag_name":"hermeyd-v9.9.9","draft":false,"prerelease":false,"html_url":"https://example.invalid/hermeyd-v9.9.9"}
]
JSON

(cd "$WORK/srv" && exec python3 -m http.server "$SERVE" --bind 127.0.0.1 >"$WORK/http.log" 2>&1) &
HTTP_PID=$!

start_service() {
  HERMEYD_HOME="$STATE" \
  HERMEYD_ENGINE_HOME="$WORK/engine" \
  HERMEYD_PORT="$PORT" \
  HERMEYD_BROWSER_PORT="$(( PORT + 2 ))" \
  HERMEYD_UPDATE_BIN="$TARGET" \
  HERMEYD_UPDATE_API="$API/releases.json" \
  HERMEYD_UPDATE_BASE="$API/dl" \
  "$TARGET" >>"$WORK/service.log" 2>&1 &
  SVC_PID=$!
  for _ in $(seq 1 100); do
    grep -q HERMEYD_READY "$WORK/service.log" 2>/dev/null && return 0
    kill -0 "$SVC_PID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

wait_for_exit() {
  for _ in $(seq 1 200); do
    kill -0 "$SVC_PID" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

echo "target $BIN (version $VERSION) on 127.0.0.1:$PORT, releases at $API"

# ---- GET: the report --------------------------------------------------------------
start_service || { echo "  FAIL  the service did not start"; sed -n 1,20p "$WORK/service.log"; exit 1; }
TOKEN="$(cat "$STATE/local.token")"
curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/v1/update" -o "$WORK/get.json"
[ "$(jget "$WORK/get.json" current)" = "$VERSION" ] \
  && pass "GET current=$VERSION" || fail "GET current" "$(cat "$WORK/get.json")"
[ "$(jget "$WORK/get.json" latest)" = "9.9.9" ] \
  && pass "GET latest=9.9.9 (app release, draft and rc ignored)" || fail "GET latest" "$(cat "$WORK/get.json")"
[ "$(jget "$WORK/get.json" available)" = "True" ] \
  && pass "GET available=true" || fail "GET available" "$(cat "$WORK/get.json")"
[ "$(jget "$WORK/get.json" arch)" = "linux-x86_64" ] \
  && pass "GET arch=linux-x86_64" || fail "GET arch" "$(cat "$WORK/get.json")"
[ "$(jget "$WORK/get.json" can_self_update)" = "True" ] \
  && pass "GET can_self_update=true" || fail "GET can_self_update" "$(cat "$WORK/get.json")"

s=$(curl -s -o "$WORK/body" -w '%{http_code}' -H "Authorization: Bearer $(printf 'x%.0s' $(seq 1 43))" \
      "http://127.0.0.1:$PORT/v1/update")
[ "$s" = "401" ] && pass "GET without a real bearer → 401" || fail "GET auth" "got $s"

# ---- POST: the press --------------------------------------------------------------
s=$(curl -s -o "$WORK/post.json" -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" \
      "http://127.0.0.1:$PORT/v1/update")
[ "$s" = "202" ] && pass "POST → 202" || fail "POST" "got $s $(cat "$WORK/post.json")"
[ "$(jget "$WORK/post.json" target)" = "9.9.9" ] \
  && pass "POST target=9.9.9" || fail "POST target" "$(cat "$WORK/post.json")"

# A second press must never start a second install. On loopback the first one can finish before
# this request lands, so both answers are correct — 409 while it runs, or no answer because the
# service has already exited into the new build. A 202 would be the bug.
s=$(curl -s -o "$WORK/post2.json" -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" \
      "http://127.0.0.1:$PORT/v1/update")
case "$s" in
  409) pass "a second press while one runs → 409" ;;
  000) pass "a second press after the install exited → refused (no second run)" ;;
  *)   fail "POST concurrency" "got $s $(cat "$WORK/post2.json")" ;;
esac

wait_for_exit && pass "the service exited for systemd to start the new build" \
             || fail "service exit" "still running after 20 s"

[ "$(sha256sum "$TARGET" | cut -d' ' -f1)" = "$NEW_SHA" ] \
  && pass "the binary is the verified download" || fail "install" "sha differs from the asset"
[ "$(sha256sum "$TARGET.prev" 2>/dev/null | cut -d' ' -f1)" = "$SHA" ] \
  && pass "hermeyd.prev is the build that was running" || fail ".prev" "missing or not the old build"
[ ! -e "$TARGET.new" ] && pass "no staged file left behind" || fail "staged file" "hermeyd.new remains"
[ "$(jget "$STATE/update-state.json" state)" = "pending" ] \
  && pass "the record says pending" || fail "record" "$(cat "$STATE/update-state.json" 2>/dev/null)"
[ "$(jget "$STATE/update-state.json" target)" = "9.9.9" ] \
  && pass "the record names the target" || fail "record target" "$(cat "$STATE/update-state.json")"
[ "$(jget "$STATE/update-state.json" previous)" = "$VERSION" ] \
  && pass "the record names the previous build" || fail "record previous" "$(cat "$STATE/update-state.json")"
grep -q '"event":"update.installed"' "$STATE/audit.jsonl" \
  && pass "audited as update.installed" || fail "audit" "no update.installed line"
[ "$(grep -c '"event":"update.installed"' "$STATE/audit.jsonl")" = "1" ] \
  && pass "exactly one install was recorded" || fail "one install" "more than one update.installed"

# ---- the trial: two boots, then the previous bytes go back ------------------------
# A build that reports 9.9.9 cannot be built here, so the record is pointed at the version that
# *is* running: that is exactly the state the service is in after installing and restarting, and it
# is what `on_boot` decides on. The restore itself does not care which version it is putting back.
SVC_PID=""
python3 - "$STATE/update-state.json" "$VERSION" <<'PY'
import json, sys
path, version = sys.argv[1], sys.argv[2]
json.dump({"target": version, "previous": "9.9.8", "state": "pending",
           "attempts": 0, "started_at": 0.0}, open(path, "w"))
PY

start_service && pass "first boot onto the new build serves" || fail "trial boot 1" "did not start"
[ "$(jget "$STATE/update-state.json" attempts)" = "1" ] \
  && pass "the record counts attempt 1" || fail "attempts" "$(cat "$STATE/update-state.json")"
kill "$SVC_PID" 2>/dev/null; wait "$SVC_PID" 2>/dev/null; SVC_PID=""

wait_for_exit 2>/dev/null
start_service >/dev/null 2>&1
wait_for_exit && pass "the second boot restores the previous build and exits" \
             || fail "rollback" "no exit after the second boot"
[ "$(jget "$STATE/update-state.json" state)" = "rolled-back" ] \
  && pass "the record says rolled-back" || fail "record" "$(cat "$STATE/update-state.json")"
[ "$(sha256sum "$TARGET" | cut -d' ' -f1)" = "$SHA" ] \
  && pass "the previous bytes are back in place" || fail "restore" "the binary was not restored"
grep -q '"event":"update.rolled_back"' "$STATE/audit.jsonl" \
  && pass "audited as update.rolled_back" || fail "audit" "no update.rolled_back line"

# ---- and the old build comes up normally, with the record settled -----------------
start_service && pass "the restored build serves" || fail "after rollback" "did not start"
[ "$(jget "$STATE/update-state.json" state)" = "rolled-back" ] \
  && pass "a settled record is left alone" || fail "settled record" "$(cat "$STATE/update-state.json")"

if [ "$fails" -eq 0 ]; then
  echo "SELF-UPDATE SMOKE OK"
else
  echo "SELF-UPDATE SMOKE FAILED — $fails check(s)"
  echo "--- service log"; sed -n 1,40p "$WORK/service.log"
  exit 1
fi
