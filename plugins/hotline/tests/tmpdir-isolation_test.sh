#!/usr/bin/env bash
# Guard Hotline test isolation: every test workspace template must use the
# runner-provided TMPDIR, while retaining a standalone /tmp fallback.
set -u

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if rg -n 'mktemp[[:space:]]+-d[[:space:]]+"?/tmp/hotline-' "$TEST_DIR" --glob '*.sh' >/dev/null; then
  fail "no Hotline mktemp template bypasses TMPDIR"
else
  pass "no Hotline mktemp template bypasses TMPDIR"
fi

probe_root="${TMPDIR:-/tmp}/"
probe_root=${probe_root%/}
TMP_ROOT="$probe_root"
TMP_ROOT=${TMP_ROOT%/}
export TMP_ROOT
mkdir -p "$TMP_ROOT"
probe=$(mktemp -d "$TMP_ROOT/hotline-tmpdir-XXXXXX")
if [[ "$probe" == "$TMP_ROOT"/hotline-tmpdir-* ]]; then
  pass "normalizes a trailing TMPDIR slash for mktemp"
else
  fail "normalizes a trailing TMPDIR slash for mktemp"
fi
rm -rf "$probe"

echo "tmpdir-isolation: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
