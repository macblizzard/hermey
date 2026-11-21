#!/usr/bin/env bash
# Attachment contract + abuse test for hermeyd.
# Happy path AND the four things that must fail: no auth, cross-device read, path traversal in the
# filename, oversized body. Byte integrity is proven by SHA-256, not by "it returned 200".
set -uo pipefail

BASE="http://127.0.0.1:${HERMEYD_PORT:-8788}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s — %s\n' "$1" "$2"; fails=$((fails + 1)); }
jget() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null; }
http() { printf '%s' "$(curl -s -o "$TMP/body" -w '%{http_code}' "$@")"; }

# Pair a device, return "device_id refresh_token" in $DEV/$REF via globals.
pair_device() {
  local label="$1"
  http -X POST "$BASE/v1/pair/start" >/dev/null
  local code; code=$(jget "$TMP/body" code)
  http -X POST "$BASE/v1/pair/claim" -H 'content-type: application/json' \
    -d "{\"code\":\"$code\",\"public_key\":\"$(printf 'k%.0s' $(seq 1 44))\",\"device_name\":\"$label\",\"platform\":\"cli\"}" >/dev/null
  DEV=$(jget "$TMP/body" device_id); REF=$(jget "$TMP/body" refresh_token)
  http -X POST "$BASE/v1/token" -H 'content-type: application/json' \
    -d "{\"device_id\":\"$DEV\",\"refresh_token\":\"$REF\"}" >/dev/null
  ACCESS=$(jget "$TMP/body" access_token)
}

echo "target $BASE"

pair_device "attach-a"
ACCESS_A="$ACCESS"   # owner of everything uploaded below; later pairings must not inherit it
[ -n "${ACCESS:-}" ] && pass "device A paired + token" || { fail "pair A" "no token"; exit 1; }

# --- upload a known payload ---
printf 'hermey attachment payload — 0123456789\n' > "$TMP/payload.txt"
LOCAL_SHA=$(sha256sum "$TMP/payload.txt" | awk '{print $1}')
s=$(http -X POST "$BASE/v1/attachments" \
      -H "Authorization: Bearer $ACCESS" \
      -H 'x-hermey-filename: notes.txt' \
      --data-binary "@$TMP/payload.txt")
if [ "$s" = "200" ]; then
  ATT=$(jget "$TMP/body" attachment_id); UP_SHA=$(jget "$TMP/body" sha256); UP_SIZE=$(jget "$TMP/body" size)
  pass "upload 200 (id ${ATT:0:8}…, ${UP_SIZE} bytes)"
  [ "$UP_SHA" = "$LOCAL_SHA" ] && pass "server sha256 matches local" || fail "sha on upload" "$UP_SHA != $LOCAL_SHA"
else
  fail "upload" "got $s $(cat "$TMP/body")"; ATT=""
fi

# --- download and compare bytes ---
s=$(http "$BASE/v1/attachments/$ATT" -H "Authorization: Bearer $ACCESS_A")
if [ "$s" = "200" ]; then
  DOWN_SHA=$(sha256sum "$TMP/body" | awk '{print $1}')
  [ "$DOWN_SHA" = "$LOCAL_SHA" ] && pass "download bytes identical (sha256)" || fail "download bytes" "sha mismatch"
else
  fail "download" "got $s"
fi

# --- production credential shape: a fresh single-use TICKET as the bearer, per request ---
http -X POST "$BASE/v1/token" -H 'content-type: application/json' \
  -d "{\"device_id\":\"$DEV\",\"refresh_token\":\"$REF\"}" >/dev/null
TICKET_A=$(jget "$TMP/body" ws_ticket)
s=$(http "$BASE/v1/devices" -H "Authorization: Bearer $TICKET_A")
[ "$s" = "200" ] && pass "ticket works as bearer (app's per-request credential)" || fail "ticket bearer" "got $s"
s=$(http "$BASE/v1/devices" -H "Authorization: Bearer $TICKET_A")
[ "$s" = "401" ] && pass "same ticket refused on reuse (single-use)" || fail "ticket reuse" "got $s"

# --- no auth ---
s=$(http -X POST "$BASE/v1/attachments" -H 'x-hermey-filename: x.txt' --data-binary "hi")
[ "$s" = "401" ] && pass "upload without bearer → 401" || fail "no-auth upload" "got $s"

# --- cross-device read ---
pair_device "attach-b"
s=$(http "$BASE/v1/attachments/$ATT" -H "Authorization: Bearer $ACCESS")
[ "$s" = "404" ] && pass "other device's attachment → 404 (existence not leaked)" || fail "cross-device" "got $s"

# --- traversal in filename ---
pair_device "attach-c"
printf 'traversal\n' > "$TMP/t.txt"
s=$(http -X POST "$BASE/v1/attachments" -H "Authorization: Bearer $ACCESS" \
      -H 'x-hermey-filename: ../../etc/passwd' --data-binary "@$TMP/t.txt")
if [ "$s" = "200" ]; then
  NAME=$(jget "$TMP/body" name)
  case "$NAME" in
    *"/"*|*".."*) fail "traversal sanitised" "stored name still dangerous: $NAME" ;;
    *) pass "filename traversal sanitised → '$NAME'" ;;
  esac
else
  fail "traversal upload" "got $s"
fi

# --- oversized ---
dd if=/dev/zero of="$TMP/big.bin" bs=1M count=26 status=none
s=$(http -X POST "$BASE/v1/attachments" -H "Authorization: Bearer $ACCESS" \
      -H 'x-hermey-filename: big.bin' --data-binary "@$TMP/big.bin")
[ "$s" = "413" ] && pass "26 MiB upload → 413" || fail "oversize" "got $s (expected 413)"

# --- delete, then prove it is gone ---
s=$(http -X DELETE "$BASE/v1/attachments/$ATT" -H "Authorization: Bearer $ACCESS_A")
[ "$s" = "200" ] && pass "delete 200" || fail "delete" "got $s"
s=$(http "$BASE/v1/attachments/$ATT" -H "Authorization: Bearer $ACCESS_A")
[ "$s" = "404" ] && pass "deleted attachment → 404" || fail "after delete" "got $s"

echo
if [ "$fails" -eq 0 ]; then echo "ATTACHMENT SMOKE OK"; exit 0; else echo "ATTACHMENT SMOKE FAILED ($fails)"; exit 1; fi
