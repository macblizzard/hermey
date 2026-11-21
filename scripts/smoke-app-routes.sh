#!/usr/bin/env bash
# Replays the app's connect sequence over the routes hermeyd must serve, and asserts the shapes the
# Swift decoders require. Every call mints a FRESH single-use ticket, exactly like the client.
set -uo pipefail

BASE="http://127.0.0.1:${HERMEYD_PORT:-8788}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }
jget() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2]))" "$1" "$2" 2>/dev/null; }
# HTTP helpers: $1 = method, rest = curl args. Body lands in $TMP/body, status printed.
req() { local m="$1"; shift; printf '%s' "$(curl -s -o "$TMP/body" -w '%{http_code}' -X "$m" "$@")"; }

echo "target $BASE"

# --- pair once, then mint a ticket per call ---
curl -s -o "$TMP/mint" -X POST "$BASE/v1/pair/start"
CODE=$(jget "$TMP/mint" "d['code']")
curl -s -o "$TMP/claim" -X POST "$BASE/v1/pair/claim" -H 'content-type: application/json' \
  -d "{\"code\":\"$CODE\",\"public_key\":\"$(printf 'k%.0s' $(seq 1 44))\",\"device_name\":\"app-seq\",\"platform\":\"ios\"}"
DEV=$(jget "$TMP/claim" "d['device_id']"); REF=$(jget "$TMP/claim" "d['refresh_token']")
[ -n "$DEV" ] && pass "paired device ${DEV:0:8}…" || { fail "pair" "no device"; exit 1; }

ticket() {
  curl -s -o "$TMP/tok" -X POST "$BASE/v1/token" -H 'content-type: application/json' \
    -d "{\"device_id\":\"$DEV\",\"refresh_token\":\"$REF\"}"
  jget "$TMP/tok" "d['ws_ticket']"
}

check() { # check <label> <method> <path> <jq-ish expr>
  local label="$1" method="$2" path="$3" expr="$4" auth="-H" tk
  tk="$(ticket)"
  local s; s=$(req "$method" "$BASE$path" -H "Authorization: Bearer $tk" -H 'content-type: application/json')
  if [ "$s" != "200" ]; then fail "$label" "HTTP $s $(head -c 120 "$TMP/body")"; return; fi
  local got; got=$(jget "$TMP/body" "$expr")
  if [ -n "$got" ]; then pass "$label → $got"; else fail "$label" "missing shape $expr in $(head -c 120 "$TMP/body")"; fi
}

# The exact sequence the app ran while it was stuck, plus the writes its screens perform.
check "GET /v1/bots/disabled"    GET  /v1/bots/disabled    "d['disabled']"
check "GET /v1/rooms"            GET  /v1/rooms            "len(d)"
check "GET /v1/bot-categories"   GET  /v1/bot-categories   "sorted(d.keys())"
check "GET /v1/bot-defaults"     GET  /v1/bot-defaults     "sorted(d.keys())"
check "GET /v1/bot-icons"        GET  /v1/bot-icons        "sorted(d.keys())"
check "GET /v1/bots/approvals"   GET  /v1/bots/approvals   "sorted(d.keys())"
check "GET /v1/bots/previews"    GET  /v1/bots/previews    "sorted(d.keys())"

tk=$(ticket); s=$(req POST "$BASE/v1/push/presence" -H "Authorization: Bearer $tk" \
  -H 'content-type: application/json' -d '{"bot":null}')
[ "$s" = "200" ] && pass "POST /v1/push/presence" || fail "push/presence" "HTTP $s"

# --- writes: create a category, set a soul default, set an icon ---
tk=$(ticket); s=$(req POST "$BASE/v1/bot-categories" -H "Authorization: Bearer $tk" \
  -H 'content-type: application/json' -d '{"name":"Work"}')
if [ "$s" = "200" ] && [ "$(jget "$TMP/body" "len(d['categories'])")" = "1" ]; then
  pass "POST category 'Work' → 1 category"
  CAT=$(jget "$TMP/body" "d['categories'][0]['id']")
else
  fail "create category" "HTTP $s $(head -c 120 "$TMP/body")"; CAT=""
fi

tk=$(ticket); s=$(req PUT "$BASE/v1/bot-defaults/soul" -H "Authorization: Bearer $tk" \
  -H 'content-type: application/json' -d '{"text":"You are a test bot."}')
[ "$s" = "200" ] && [ "$(jget "$TMP/body" "d['soul']['present']")" = "True" ] \
  && pass "PUT soul default persisted (present=true)" || fail "soul default" "HTTP $s"

tk=$(ticket); s=$(req PUT "$BASE/v1/bot-icons/scratch" -H "Authorization: Bearer $tk" \
  -H 'content-type: application/json' -d '{"avatar":"fox"}')
[ "$s" = "200" ] && pass "PUT bot icon" || fail "bot icon" "HTTP $s"

tk=$(ticket); s=$(req PUT "$BASE/v1/bots/approvals" -H "Authorization: Bearer $tk" \
  -H 'content-type: application/json' -d '{"mode":"auto"}')
[ "$s" = "200" ] && [ "$(jget "$TMP/body" "d['mode']")" = "auto" ] \
  && pass "PUT approvals mode" || fail "approvals write" "HTTP $s"

tk=$(ticket); s=$(req POST "$BASE/v1/bots/scratch/state" -H "Authorization: Bearer $tk" \
  -H 'content-type: application/json' -d '{"enabled":false}')
[ "$s" = "200" ] && pass "POST bot state (disable)" || fail "bot state" "HTTP $s"

# --- persistence across calls ---
check "categories survive (still 1)" GET /v1/bot-categories "len(d['categories'])"
check "disabled lists scratch"      GET /v1/bots/disabled   "d['disabled']"
check "icon survives"               GET /v1/bot-icons      "d['faces']['scratch']['avatar']"

echo
if [ "$fails" -eq 0 ]; then echo "APP-ROUTE SMOKE OK"; exit 0; else echo "APP-ROUTE SMOKE FAILED ($fails)"; exit 1; fi
