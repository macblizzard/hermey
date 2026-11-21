#!/usr/bin/env bash
# Contract + security test for hermeyd. Proves the pairing flow AND that the four things that must
# fail actually do: code replay, bad refresh, missing bearer, revoked device.
#
#   scripts/smoke-hermeyd.sh            # expects hermeyd on 127.0.0.1:${HERMEYD_PORT:-8788}
set -uo pipefail

BASE="http://127.0.0.1:${HERMEYD_PORT:-8788}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }
code() { printf '%s' "$1"; }
jget() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get(sys.argv[2],""))' "$1" "$2" 2>/dev/null; }
http() { printf '%s' "$(curl -s -o "$TMP/body" -w '%{http_code}' "$@")"; }

echo "target $BASE"

s=$(http "$BASE/v1/health")
[ "$s" = "200" ] && pass "health 200" || fail "health" "got $s"
[ "$(jget "$TMP/body" status)" = "ok" ] && pass "health status=ok" || fail "health body" "$(cat "$TMP/body")"

s=$(http -X POST "$BASE/v1/pair/start")
if [ "$s" = "200" ]; then
  PAIR_CODE=$(jget "$TMP/body" code)
  pass "pair/start minted ${#PAIR_CODE} -digit code"
else
  fail "pair/start" "got $s"; PAIR_CODE=""
fi

s=$(http -X POST "$BASE/v1/pair/claim" -H 'content-type: application/json' \
      -d "{\"code\":\"$PAIR_CODE\",\"public_key\":\"$(printf 'k%.0s' $(seq 1 44))\",\"device_name\":\"smoke\",\"platform\":\"cli\"}")
if [ "$s" = "200" ]; then
  DEVICE_ID=$(jget "$TMP/body" device_id); REFRESH=$(jget "$TMP/body" refresh_token)
  pass "pair/claim registered device ${DEVICE_ID:0:8}… (refresh ${#REFRESH} chars)"
else
  fail "pair/claim" "got $s $(cat "$TMP/body")"; DEVICE_ID=""; REFRESH=""
fi

# The same code must not work twice.
s=$(http -X POST "$BASE/v1/pair/claim" -H 'content-type: application/json' \
      -d "{\"code\":\"$PAIR_CODE\",\"public_key\":\"$(printf 'k%.0s' $(seq 1 44))\"}")
[ "$s" = "401" ] && pass "pairing code is single-use (replay 401)" || fail "code replay" "got $s"

s=$(http -X POST "$BASE/v1/token" -H 'content-type: application/json' \
      -d "{\"device_id\":\"$DEVICE_ID\",\"refresh_token\":\"$REFRESH\"}")
if [ "$s" = "200" ]; then
  ACCESS=$(jget "$TMP/body" access_token); TICKET=$(jget "$TMP/body" ws_ticket); TTL=$(jget "$TMP/body" expires_in)
  pass "token minted access(${#ACCESS}) + ws_ticket(${#TICKET}), expires_in=${TTL}s"
else
  fail "token" "got $s $(cat "$TMP/body")"; ACCESS=""
fi

s=$(http -X POST "$BASE/v1/token" -H 'content-type: application/json' \
      -d "{\"device_id\":\"$DEVICE_ID\",\"refresh_token\":\"wrong-token-value\"}")
[ "$s" = "401" ] && pass "bad refresh rejected (401)" || fail "bad refresh" "got $s"

s=$(http "$BASE/v1/devices")
[ "$s" = "401" ] && pass "devices without bearer (401)" || fail "no-bearer" "got $s"

s=$(http "$BASE/v1/devices" -H "Authorization: Bearer $ACCESS")
if [ "$s" = "200" ]; then
  N=$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$TMP/body")
  pass "devices with bearer → $N device(s)"
else
  fail "devices with bearer" "got $s"
fi

s=$(http -X DELETE "$BASE/v1/devices/$DEVICE_ID" -H "Authorization: Bearer $ACCESS")
[ "$s" = "200" ] && pass "revoke 200" || fail "revoke" "got $s"

s=$(http -X POST "$BASE/v1/token" -H 'content-type: application/json' \
      -d "{\"device_id\":\"$DEVICE_ID\",\"refresh_token\":\"$REFRESH\"}")
[ "$s" = "401" ] && pass "revoked device cannot mint (401)" || fail "revoked refresh" "got $s"

echo
if [ "$fails" -eq 0 ]; then echo "HERMEYD SMOKE OK"; exit 0; else echo "HERMEYD SMOKE FAILED ($fails)"; exit 1; fi
