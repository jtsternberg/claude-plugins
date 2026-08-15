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
#   socket_stub_write_responses — the canned answers a working cmux gives, including
#                         the `terminal.replay` render grids the placeholder-vs-input
#                         judgement reads. One definition of what a real cmux
#                         answers, so no suite tests against a fictional one.
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

  # --- terminal.replay: the STYLED render grid ------------------------------
  # The one thing a plain-text screen read cannot carry, and the whole reason
  # input_box_is_placeholder exists: claude draws a placeholder DIM (faint:true) and
  # real input at normal intensity, and `cmux read-screen` renders both identically.
  #
  # Every grid below is the same box: row 10, the glyph padded with U+00A0 in a
  # non-faint span at column 0, and a plain-space `❯` ECHO on row 12 BELOW it. The
  # echo is deliberate — it is drawn lower than the live box, so a reader that took
  # simply "the last ❯ row" would pick the wrong line, exactly as input_box_content's
  # NBSP tell exists to prevent. \u escapes rather than literals: a NO-BREAK SPACE
  # typed into a fixture is indistinguishable from a space on sight.
  #
  # style 0 = normal, 1 = faint (placeholder), 2 = inverse-not-faint (the cursor cell
  # a focused terminal draws over the placeholder's first character).
  _replay_grid() {  # _replay_grid <spans-json>
    cat <<JSON
{"ok": true, "result": {"render_grid": {
  "cursor": {"row": 10, "column": 2, "visible": true},
  "styles": [{"id": 0, "faint": false, "inverse": false, "bold": false},
             {"id": 1, "faint": true,  "inverse": false, "bold": false},
             {"id": 2, "faint": false, "inverse": true,  "bold": false}],
  "row_spans": [
    {"row": 10, "column": 0, "text": "\u276f\u00a0", "style_id": 0},
    $1
    {"row": 12, "column": 0, "text": "\u276f prior turn echo", "style_id": 0}
  ]}}}
JSON
  }
  _replay_responses() {  # _replay_responses <out-file> <spans-json>
    local out="$1"
    { printf '{"terminal.paste": {"ok": true, "result": {"submitted": true}},\n'
      printf ' "_default": {"ok": true, "result": {}},\n'
      printf ' "terminal.replay": '
      _replay_grid "$2"
      printf '}\n'
    } > "$out"
  }

  # The box holds a placeholder: every span after the glyph is faint.
  _replay_responses "$dir/replay-ghost.json" \
    '{"row": 10, "column": 2, "text": "push it", "style_id": 1},'
  # Same, focused: the placeholder's first character renders as the inverse cursor
  # cell at the cursor column, and only that one cell is not faint.
  _replay_responses "$dir/replay-ghost-focused.json" \
    '{"row": 10, "column": 2, "text": "p", "style_id": 2},
     {"row": 10, "column": 3, "text": "ush it", "style_id": 1},'
  # The box holds REAL unsent input: not faint, so not a placeholder.
  _replay_responses "$dir/replay-real.json" \
    '{"row": 10, "column": 2, "text": "leftover half-typed thing", "style_id": 0},'
  # Real input FIRST, a placeholder SECOND — the only way to express the state the
  # post-clear re-read has to handle: the gate saw genuine unsent text and cleared it,
  # and claude drew a placeholder into the now-empty box. Reading that as "still
  # dirty" would refuse a clear that worked.
  { printf '{"terminal.paste": {"ok": true, "result": {"submitted": true}},\n'
    printf ' "_default": {"ok": true, "result": {}},\n'
    printf ' "terminal.replay": [\n'
    _replay_grid '{"row": 10, "column": 2, "text": "leftover half-typed thing", "style_id": 0},'
    printf ',\n'
    _replay_grid '{"row": 10, "column": 2, "text": "push it", "style_id": 1},'
    printf ']}\n'
  } > "$dir/replay-real-then-ghost.json"
  # A cmux that has the capability but refuses the call.
  cat > "$dir/replay-error.json" <<'JSON'
{"terminal.paste": {"ok": true, "result": {"submitted": true}},
 "terminal.replay": {"ok": false, "error": {"message": "surface has no renderer"}},
 "_default": {"ok": true, "result": {}}}
JSON
}
