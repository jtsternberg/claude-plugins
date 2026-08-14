#!/usr/bin/env bash
# =============================================================================
# Shared harness for suites that exercise hotline's control-socket delivery.
#
# SOURCE this, don't execute it.
#
# Two seams live here, and both were duplicated near-verbatim in
# cmux-reuse-surface_test.sh and dial_wrapper_test.sh before this file existed —
# the same two-copies pattern that has already cost this repo time twice in the
# transcript parser. When one copy learns about a new stub option and the other
# does not, the suite that did not learn keeps passing against a stale idea of the
# code.
#
#   socket_stub_start   — brings up tests/lib/socket-stub.py on a unix socket,
#                         blocking on its READY line rather than sleeping.
#   write_python3_shim  — writes a PATH shim in front of python3 that records the
#                         socket helper's argv and the MODE of the file it was
#                         handed. Nothing else can assert those two things: that
#                         the payload travels as a path and never as an argument,
#                         and that the path is owner-only at the moment it is read.
#
# Contract for the sourcing suite:
#   • define $POISON_LOG before sourcing (violations are appended to it)
#   • call socket_stub_cleanup from your EXIT trap
#   • $REAL_PYTHON3 is set here if the suite has not set it already
# =============================================================================

# The real interpreter, captured BEFORE any suite puts a shim on PATH — a shim
# that exec'd itself would loop.
: "${REAL_PYTHON3:=$(command -v python3)}"

SOCKET_STUB_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/socket-stub.py"

SOCKET_STUB_PIDS=()

# socket_stub_start <dir> [responses-json] [echo-file] [reject-surface]
#   → echoes the socket path; the request log is <dir>/requests.log
#
# With no responses file the server is POISONED: it answers ok:false and records
# every request as a violation, so a case that forgot to stage responses fails
# loudly instead of quietly passing.
socket_stub_start() {
  local dir="$1" responses="${2:-}" echo_file="${3:-}" reject="${4:-}"
  local sock args=() i
  mkdir -p "$dir"
  sock="$dir/cmux.sock"
  # --watch-pid is the SUITE shell ($$), not this subshell: socket_stub_start is
  # usually called inside $(...) whose subshell exits at once, so the stub must
  # watch the durable owner to know when the run is truly over. $$ stays the main
  # shell's pid even inside a command substitution; BASHPID would not.
  args=(--socket "$sock" --requests "$dir/requests.log" --watch-pid "$$")
  if [[ -n "$responses" ]]; then
    args+=(--responses "$responses")
  else
    args+=(--poison --violations "${POISON_LOG:-$dir/violations}")
  fi
  [[ -n "$echo_file" ]] && args+=(--echo-file "$echo_file")
  [[ -n "$reject"    ]] && args+=(--reject-surface "$reject")
  "$REAL_PYTHON3" "$SOCKET_STUB_LIB" "${args[@]}" > "$dir/stub.out" 2>"$dir/stub.err" &
  SOCKET_STUB_PIDS+=($!)
  # Block on the stub's own readiness line. A fixed sleep here is the classic
  # source of a suite that passes on a fast machine and flakes on a loaded one.
  for i in $(seq 1 60); do
    grep -q READY "$dir/stub.out" 2>/dev/null && break
    sleep 0.05
  done
  : > "$dir/requests.log"
  printf '%s' "$sock"
}

socket_stub_cleanup() {
  local p
  for p in ${SOCKET_STUB_PIDS[@]+"${SOCKET_STUB_PIDS[@]}"}; do
    kill "$p" 2>/dev/null || true
  done
}

# write_python3_shim <bin-dir> <log-file>
#
# Logs one %q-quoted line per python3 invocation, plus a `PAYLOAD_MODE <mode>
# <path>` line for the file passed to --payload-file, then delegates to the real
# interpreter.
write_python3_shim() {
  local bindir="$1" log="$2"
  mkdir -p "$bindir"
  # The mode read below tries GNU stat (-c) BEFORE BSD stat (-f). Order matters:
  # on Linux `stat -f '%Lp'` is --file-system and prints verbose garbage instead
  # of failing, so a BSD-first idiom never reaches the -c fallback and the 0600
  # assertions read empty on CI. All four copies of this idiom must stay GNU-first.
  cat > "$bindir/python3" <<SHIM
#!/usr/bin/env bash
printf '%q ' "\$@" >> "$log"; printf '\n' >> "$log"
for _a in "\$@"; do
  if [[ -n "\${_want_file:-}" ]]; then
    printf 'PAYLOAD_MODE %s %s\n' \
      "\$(stat -c '%a' "\$_a" 2>/dev/null || stat -f '%Lp' "\$_a" 2>/dev/null)" "\$_a" >> "$log"
    _want_file=""
  fi
  [[ "\$_a" == "--payload-file" ]] && _want_file=1
done
exec "$REAL_PYTHON3" "\$@"
SHIM
  chmod +x "$bindir/python3"
}

# Canned answers a working cmux gives. system.capabilities must advertise
# terminal.paste under result.METHODS — result.capabilities is a different list of
# *.v1 feature tokens and never contains it, so a preflight reading the wrong one
# would degrade every call on a cmux that supports the verb perfectly well.
socket_stub_write_responses() {  # socket_stub_write_responses <dir>
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/ok.json" <<'JSON'
{"system.capabilities": {"ok": true, "result": {
   "methods": ["system.capabilities", "terminal.paste", "workspace.close"],
   "capabilities": ["terminal.bytes.v1", "events.v1"]}},
 "terminal.paste": {"ok": true, "result": {"submitted": true}},
 "_default": {"ok": true, "result": {}}}
JSON
  # A cmux too old to offer the verb at all.
  cat > "$dir/no-paste.json" <<'JSON'
{"system.capabilities": {"ok": true, "result": {
   "methods": ["system.capabilities", "workspace.close"],
   "capabilities": ["terminal.bytes.v1"]}},
 "_default": {"ok": true, "result": {}}}
JSON
  # A paste the socket refuses outright.
  cat > "$dir/reject.json" <<'JSON'
{"system.capabilities": {"ok": true, "result": {
   "methods": ["system.capabilities", "terminal.paste"]}},
 "terminal.paste": {"ok": false, "error": {"message": "surface is not a terminal"}}}
JSON
}
