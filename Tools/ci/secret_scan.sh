#!/usr/bin/env bash
# Shape-based credential scan. Deliberately dependency-free: CI must not need a marketplace action
# to notice a token in the tree.
#
# It looks for the *shape* of real credentials, not for words like "token" — tests legitimately
# contain canaries such as "gateway-token-do-not-leak", and a scanner that flags those teaches
# people to ignore it.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

fail=0
git rev-parse --git-dir >/dev/null 2>&1 || { echo "secret scan: not a git repository — refusing to report clean" >&2; exit 2; }

scan() {
  local name=$1 pattern=$2
  local hits
  hits=$(git ls-files -z | xargs -0 grep -InE --binary-files=without-match "$pattern" 2>/dev/null | grep -v '100\.64\.0\.1' || true)
  if [ -n "$hits" ]; then
    echo "::error::$name"
    printf '%s\n' "$hits" | cut -c1-200
    fail=1
  fi
}

scan "private key material"      '-----BEGIN (RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----'
scan "OpenAI/Anthropic style key" '\b(sk|rk)-[A-Za-z0-9_-]{20,}'
scan "GitHub token"              '\bgh[pousr]_[A-Za-z0-9]{30,}'
scan "Slack token"               '\bxox[baprs]-[A-Za-z0-9-]{10,}'
scan "AWS access key id"         '\bAKIA[0-9A-Z]{16}\b'
scan "Google API key"            '\bAIza[0-9A-Za-z_-]{35}\b'
scan "JWT"                       '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.'
scan "tailnet address"           '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b'

# A tailnet address is not a secret; it is however somebody's private network, and this repo is
# published. Keep the check separate so the failure message can say which of the two it is.
printf 'secret scan: %s\n' "$([ $fail -eq 0 ] && echo clean || echo FAILED)"
exit $fail
