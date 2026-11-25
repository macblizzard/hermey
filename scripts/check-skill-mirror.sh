#!/usr/bin/env bash
# check-skill-mirror.sh — the bundled copies are mirrors, not forks.
#
# The cards-first policy is written once, in the fleet's shared skills, and hermeyd ships the same
# file so a fresh host has it with nobody copying anything. A host that installs a bundle which has
# drifted from the canon is a host whose bot asks in prose. This is the check.
#
#   check-skill-mirror.sh          compare, exit 1 on drift (prints the diff)
#   check-skill-mirror.sh --fix    copy the canon over the bundle, then re-check
#
# Exit codes: 0 identical, 1 drift, 2 no canonical library on this machine (not a fleet host).
#
# Scope: only the untemplated skills can be byte-identical. `mac-local-computer` and `signin` carry
# `@@BIN@@`/`@@TOKEN_FILE@@` placeholders that hermeyd renders at install, so they are not mirrored
# here — their bundle text is the template and the shared copy is the host's rendering.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARED="${HERMES_SHARED_SKILLS:-/root/.hermes/shared/skills}"
MIRRORED=(agent-cards)

fix=0
[ "${1:-}" = "--fix" ] && fix=1

[ -d "$SHARED" ] || { echo "skip: no shared skills library at $SHARED"; exit 2; }

drift=0
for name in "${MIRRORED[@]}"; do
  canon="$SHARED/$name/SKILL.md"
  bundle="$ROOT/hermeyd/assets/agent-skills/$name/SKILL.md"
  if [ ! -f "$canon" ]; then
    echo "skip: $name is not in $SHARED"
    continue
  fi
  if [ ! -f "$bundle" ]; then
    echo "DRIFT: $name is in the shared library but not bundled"
    drift=1
    continue
  fi
  if [ "$fix" = 1 ]; then
    cp "$canon" "$bundle"
  fi
  if ! diff -q "$canon" "$bundle" >/dev/null; then
    echo "DRIFT: hermeyd/assets/agent-skills/$name/SKILL.md != $canon"
    diff -u "$bundle" "$canon" | sed -n '3,40p'
    drift=1
  else
    echo "ok: $name mirrors the shared copy"
  fi
done

if [ "$drift" = 1 ]; then
  echo
  echo "Re-run with --fix, or edit $SHARED and copy it over — never edit the bundle alone."
  exit 1
fi

# The policy itself must be present, not just identical files: a mirror of an empty rule is drift too.
if ! grep -q "## Cards first — the standing rule" "$ROOT/hermeyd/assets/agent-skills/agent-cards/SKILL.md"; then
  echo "DRIFT: the bundled agent-cards skill has no cards-first rule"
  exit 1
fi
if ! grep -q "SECURE-ENTRY" "$ROOT/hermeyd/assets/agent-skills/agent-cards/SKILL.md"; then
  echo "DRIFT: the bundled agent-cards skill has no SECURE-ENTRY requirement"
  exit 1
fi
echo "ok: cards-first and SECURE-ENTRY are in the bundle"
