#!/usr/bin/env bash
# Guard Hotline test isolation: every test workspace template must use the
# runner-provided TMPDIR, while retaining a standalone /tmp fallback.
set -u

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGED_TESTS=(
  cmux-call-async_test.sh cmux-call_test.sh dial-history_test.sh
  dial_wrapper_test.sh herdr-transport_test.sh reproduce-jq-parse-error.sh
  session-cache_test.sh session_init_test.sh surface-placement_test.sh
  transport-signal_test.sh wait-for-cmux_test.sh wait-for-response_test.sh
)
unquoted=0
for suite in "${CHANGED_TESTS[@]}"; do
  if rg -n 'mktemp[[:space:]]+-d[[:space:]]+\$TMP_ROOT' "$TEST_DIR/$suite" >/dev/null; then
    unquoted=1
    break
  fi
done
if [[ $unquoted -eq 0 ]]; then
  pass "every changed Hotline mktemp template quotes TMP_ROOT"
else
  fail "every changed Hotline mktemp template quotes TMP_ROOT"
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

space_root=$(mktemp -d "${TMPDIR:-/tmp}/hotline-space-XXXXXX")
space_root="$space_root with spaces"
mkdir -p "$space_root"
space_tmpdir="$space_root/runner tmp"
mkdir -p "$space_tmpdir"
space_output=$(TMPDIR="$space_tmpdir" bash "$TEST_DIR/wait-for-response_test.sh")
space_rc=$?
if [[ $space_rc -eq 0 ]]; then
  pass "wait-for-response honors a TMPDIR containing spaces"
else
  fail "wait-for-response honors a TMPDIR containing spaces" "rc=$space_rc\n$space_output"
fi
rm -rf "$space_root"

echo "tmpdir-isolation: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
