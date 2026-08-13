#!/usr/bin/env bash
# =============================================================================
# socket-stub-orphan_test.sh — the control-socket stub must not outlive its run.
#
# The suites reap stubs from an EXIT trap (socket-stub-harness.sh). A shell
# killed abnormally never runs that trap, so before claude-plugins-r7di a stub
# whose run was SIGKILLed kept running forever, reparented to init — 1391 of them
# accumulated across three checkouts before anyone noticed. The stub now takes a
# --watch-pid (the harness passes the durable SUITE shell) and exits once that
# pid is gone. This proves both halves: it stays up while the owner lives, and it
# self-terminates once the owner dies.
#
# Usage: bash plugins/hotline/tests/socket-stub-orphan_test.sh
# =============================================================================
set -uo pipefail

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
STUB="$TESTS_DIR/lib/socket-stub.py"
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || { echo "python3 not found — skipping" >&2; exit 0; }
[ -f "$STUB" ] || { echo "cannot find stub at $STUB" >&2; exit 1; }

TMP=$(mktemp -d)
OWNER_PID=""
STUB_PID=""
cleanup() {
  [ -n "$OWNER_PID" ] && kill -9 "$OWNER_PID" 2>/dev/null
  [ -n "$STUB_PID" ] && kill -9 "$STUB_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# Short watchdog interval keeps the test snappy without changing what it proves.
export SOCKET_STUB_WATCHDOG_SECS=0.5

# Stand-in for the durable suite shell the harness would pass as --watch-pid.
sleep 600 &
OWNER_PID=$!
disown "$OWNER_PID" 2>/dev/null || true

# Start the stub watching that owner. Backgrounded directly — its own parent is
# this test shell (which stays alive), so the ONLY thing that can end it is the
# --watch-pid owner dying. That isolates exactly the behavior under test.
"$PY" "$STUB" --socket "$TMP/cmux.sock" --requests "$TMP/req.log" \
  --pidfile "$TMP/stub.pid" --watch-pid "$OWNER_PID" \
  >"$TMP/stub.out" 2>"$TMP/stub.err" &
STUB_JOB=$!
for _ in $(seq 1 100); do grep -q READY "$TMP/stub.out" 2>/dev/null && break; sleep 0.05; done
STUB_PID=$(cat "$TMP/stub.pid" 2>/dev/null || true)

if [ -n "$STUB_PID" ] && kill -0 "$STUB_PID" 2>/dev/null; then
  pass "stub starts and reports its pid"
else
  fail "stub never came up (pid='$STUB_PID'): $(cat "$TMP/stub.err" 2>/dev/null)"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi

# Control: while the owner lives, the stub must stay up across several watchdog
# ticks — the guard must not false-fire on a healthy run.
sleep 2
if kill -0 "$STUB_PID" 2>/dev/null; then
  pass "stub stays up while its --watch-pid owner is alive"
else
  fail "stub exited while its owner was alive (watchdog false-fired)"
fi

# Abandon it: kill the owner (as a SIGKILLed suite shell would vanish without
# running its reap trap). The stub must notice and exit on its own.
kill -9 "$OWNER_PID" 2>/dev/null
OWNER_PID=""

gone=0
for _ in $(seq 1 40); do   # up to ~8s
  kill -0 "$STUB_PID" 2>/dev/null || { gone=1; break; }
  sleep 0.2
done
if [ "$gone" = 1 ]; then
  pass "stub self-terminates once its owner is gone"
  STUB_PID=""
else
  fail "stub still running after its owner died (pid $STUB_PID) — it would leak"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
