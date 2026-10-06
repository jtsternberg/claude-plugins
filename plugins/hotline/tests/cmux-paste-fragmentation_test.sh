#!/usr/bin/env bash
# =============================================================================
# cmux-paste.sh's FRAGMENTATION COUNT — the additive `submit_frames` field.
#
# One `terminal.paste` is supposed to land as ONE user turn. When it does not,
# the callee gets the work order split across turns, and the confirmation ladder
# reports that as a clean delivery: it proves the NONCE arrived, and says nothing
# about how many turns it arrived as. The count is the only thing that shows it.
#
# WHAT THIS SUITE IS GUARDING, in order of how expensive the mistake would be:
#
#   1. `delivered` and `confirmed` DO NOT MOVE on a fragmented delivery. A split
#      payload IS in the callee's queue, so reporting it as undelivered invites
#      the caller to deliver it a second time — worse than the split itself.
#   2. The count is attributed to the CALLEE'S SURFACE, not to its workspace.
#      `workspace.prompt.submitted` carries no surface_id and no session_id
#      (measured live: 16/16 frames, null top-level id and no payload key), and a
#      side-by-side call puts the caller's REPL and the callee's in ONE workspace
#      (measured: one workspace_id over two session_ids on two surface_ids). A
#      workspace-scoped count would therefore cry fragmentation every time the
#      operator typed into their own pane inside the settle window. So the count
#      reads `agent.hook.UserPromptSubmit`, which carries surface_id, session_id
#      and cwd on every frame (measured: 21/21, both phases).
#   3. The field is OMITTED, never 0, where the stream could not answer. A 0 there
#      asserts the callee ingested nothing, which a confirmed delivery has just
#      disproved.
#
# Fixtures are the shapes of a real `cmux events --after 0 --no-ack
# --no-heartbeat` capture on cmux 0.64.25 — a two-phase agent.hook frame, the
# composite `cmux-feed-v1:<b64 agent>:<b64 uuid>` session id, and a UUID in the
# upper case the hook bridge emits. Phases 1+2 shipped three dead-on-arrival bugs
# from inventing these instead of capturing them.
#
# `cmux` is a PATH stub: read-screen/send-key as in cmux-paste-parked-retry_test.sh,
# plus `events` serving canned NDJSON and honouring --after. No real cmux.
# =============================================================================
set -u

PASS=0; FAIL=0; FAILED_CASES=()
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOTLINE_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$HOTLINE_DIR/skills/dial/scripts/cmux-paste.sh"
REAL_PYTHON3="$(command -v python3)"

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; }
check() { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi; }

if [[ -z "$REAL_PYTHON3" ]]; then
  echo "cmux-paste-fragmentation: SKIP — python3 not available"; exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "cmux-paste-fragmentation: SKIP — jq not available"; exit 0; }

GLYPH=$'\xe2\x9d\xaf'; NBSP=$'\xc2\xa0'
RULE="$(printf '─%.0s' {1..40})"
# UPPER CASE, as the hook bridge emits it, against a handle a caller holds in the
# same case the cmux tree gives. The comparison is case-folded on purpose; a UUID
# differing only in case would otherwise match nothing, silently.
SURF_UUID="AAAA0000-1111-4111-8111-111111111111"
WS_UUID="BBBB0000-2222-4222-8222-222222222222"
OTHER_SURF="CCCC0000-3333-4333-8333-333333333333"
BASE_SEQ=900

STUBROOT="$(mktemp -d)"
POISON_LOG="$STUBROOT/violations"
# shellcheck source=lib/socket-stub-harness.sh
source "$TESTS_DIR/lib/socket-stub-harness.sh"
trap 'socket_stub_cleanup; rm -rf "$STUBROOT"' EXIT
socket_stub_write_responses "$STUBROOT/responses"
OK_RESPONSES="$STUBROOT/responses/ok.json"

export HOTLINE_PASTE_CONFIRM_TRIES=2
export HOTLINE_PASTE_CONFIRM_SLEEP=0.05

empty_box() { printf '%s\n%s%s\n%s\n' "$RULE" "$GLYPH" "$NBSP" "$RULE"; }

# composite <uuid> — the session id shape cmux actually reports.
composite() { printf 'cmux-feed-v1:Y2xhdWRl:%s' "$(printf '%s' "$1" | base64 | tr -d '\n')"; }

# ingest_frame <seq> <surface> <session-uuid> <phase>
# Both phases are emitted for every real occurrence (trap 4); only "completed"
# may count, or every turn counts double.
ingest_frame() {
  printf '{"name":"agent.hook.UserPromptSubmit","seq":%s,"surface_id":"%s","workspace_id":"%s","payload":{"phase":"%s","session_id":"%s","surface_id":"%s","workspace_id":"%s","cwd":"/x","tool_input_length":262}}\n' \
    "$1" "$2" "$WS_UUID" "$4" "$(composite "$3")" "$2" "$WS_UUID"
}

# make_cmux <bindir> <screen> <reqlog> <frames-file>
# `events`:
#   --snapshot  → the ack ONLY (real cmux prints the ack and exits, so --no-ack
#                 suppresses its only line — that trap cost phase 1 a primitive
#                 that could never arm).
#   otherwise   → the frames file, filtered by --after, then the stderr timeout
#                 line a real window ends with.
make_cmux() {
  local bindir="$1" screen="$2" reqlog="$3" frames="$4"
  mkdir -p "$bindir"
  cat > "$bindir/cmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --version)   [[ -n "\${CMUX_STUB_VERSION:-}" ]] && echo "cmux \$CMUX_STUB_VERSION (108) [dda24fbd2]"; exit 0 ;;
  read-screen) cat "$screen"; exit 0 ;;
  send-key)    exit 0 ;;
  events)
    shift
    if [[ -n "\${CMUX_STUB_NO_EVENTS:-}" ]]; then
      echo "Error: unknown subcommand 'events'" >&2; exit 2
    fi
    snap=0; noack=0; after=0; prev=""
    for a in "\$@"; do
      [[ "\$a" == "--snapshot" ]] && snap=1
      [[ "\$a" == "--no-ack" ]] && noack=1
      [[ "\$prev" == "--after" ]] && after="\$a"
      prev="\$a"
    done
    echo "events \$*" >> "$reqlog.events"
    if [[ \$snap -eq 1 ]]; then
      [[ \$noack -eq 1 ]] && exit 0
      printf '{"type":"ack","resume":{"oldest_seq":1,"latest_seq":$BASE_SEQ,"gap":false}}\n'
      exit 0
    fi
    [[ \$noack -eq 0 ]] && printf '{"type":"ack","resume":{"latest_seq":$BASE_SEQ}}\n'
    if [[ -f "$frames" ]]; then
      "$REAL_PYTHON3" - "$frames" "\$after" <<'PY'
import json,sys
after=int(sys.argv[2] or 0)
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: seq=json.loads(line).get("seq",0)
    except Exception: seq=0
    if seq > after: print(line)
PY
    fi
    echo "Error: Timed out waiting for a matching event" >&2
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$bindir/cmux"
}

# run_case <dir> <call-id> <frames-writer-fn> [extra-env...]
#   Plants a transcript already carrying the nonce, so the PRIMARY (byte-definitive)
#   tier confirms and the run reaches the count on its confirmed path. That is the
#   only path the count is taken on.
run_case() {
  local dir="$1" cid="$2" framesfn="$3"; shift 3
  local bin="$dir/bin" home="$dir/home" sock proj
  mkdir -p "$dir/cwd" "$home"
  printf '%s' "$(empty_box)" > "$dir/screen"
  : > "$dir/frames.ndjson"
  "$framesfn" > "$dir/frames.ndjson"
  proj=$(HOME="$home" bash "$HOTLINE_DIR/scripts/transcript-path.sh" --cwd "$dir/cwd" --session "$SESS_UUID" 2>/dev/null)
  mkdir -p "$(dirname "$proj")"
  printf '{"type":"user","text":"[CALL_ID: %s]"}\n' "$cid" > "$proj"
  make_cmux "$bin" "$dir/screen" "$dir/sock/requests.log" "$dir/frames.ndjson"
  write_python3_shim "$bin" "$dir/py-argv"
  sock="$(socket_stub_start "$dir/sock" "$OK_RESPONSES" "$dir/echo-unused")"
  printf '[CALL_ID: %s]\nline one\nline two\nline three\nline four\n' "$cid" > "$dir/payload.md"
  env "$@" HOME="$home" PATH="$bin:$PATH" CMUX_SOCKET_PATH="$sock" \
    bash "$SCRIPT_UNDER_TEST" --surface "$SURF_UUID" --workspace "$WS_UUID" \
      --payload-file "$dir/payload.md" --call-id "$cid" \
      --cwd "$dir/cwd" --session "$SESS_UUID" 2>/dev/null
}

SESS_UUID="d1d722b9-d8c1-42ef-987e-468ce2662c73"

echo "cmux-paste.sh fragmentation count:"

# --- 1. One ingest → one turn, a clean delivery ------------------------------
f_one() { ingest_frame $((BASE_SEQ+1)) "$SURF_UUID" "$SESS_UUID" received
          ingest_frame $((BASE_SEQ+2)) "$SURF_UUID" "$SESS_UUID" completed; }
d="$STUBROOT/one"; out=$(run_case "$d" "frag000000000001" f_one)
[[ "$(jq -r '.submit_frames // "absent"' <<<"$out")" == "1" ]]
check "one ingested turn reports submit_frames:1" $? "out=$out"

# The two phases of ONE occurrence must not count as two turns (trap 4).
[[ "$(jq -r '.submit_frames' <<<"$out")" != "2" ]]
check "the 'received' phase of the same occurrence is not counted twice" $? "out=$out"

# --- 2. Two ingests → fragmentation, and NOTHING ELSE CHANGES ----------------
f_two() { ingest_frame $((BASE_SEQ+1)) "$SURF_UUID" "$SESS_UUID" received
          ingest_frame $((BASE_SEQ+2)) "$SURF_UUID" "$SESS_UUID" completed
          ingest_frame $((BASE_SEQ+3)) "$SURF_UUID" "$SESS_UUID" received
          ingest_frame $((BASE_SEQ+4)) "$SURF_UUID" "$SESS_UUID" completed; }
d="$STUBROOT/two"; out=$(run_case "$d" "frag000000000002" f_two)
[[ "$(jq -r '.submit_frames // "absent"' <<<"$out")" == "2" ]]
check "a payload that landed as two turns reports submit_frames:2" $? "out=$out"

# THE NON-NEGOTIABLE. A fragmented payload is in the callee's queue; reporting it
# as undelivered invites a second delivery of the same work order.
jq -e '.delivered == true and .sent == true and .confirmed == "transcript"' <<<"$out" >/dev/null 2>&1
check "fragmentation does NOT change delivered/sent/confirmed" $? "out=$out"

# --- 3. Attribution: another surface in the SAME workspace is not ours -------
# The measured shape of a side-by-side call: caller and callee share workspace_id.
f_other_surface() { ingest_frame $((BASE_SEQ+1)) "$SURF_UUID" "$SESS_UUID" completed
                    ingest_frame $((BASE_SEQ+2)) "$OTHER_SURF" "aaaaaaaa-1111-4111-8111-111111111111" received
                    ingest_frame $((BASE_SEQ+3)) "$OTHER_SURF" "aaaaaaaa-1111-4111-8111-111111111111" completed; }
d="$STUBROOT/othersurf"; out=$(run_case "$d" "frag000000000003" f_other_surface)
[[ "$(jq -r '.submit_frames // "absent"' <<<"$out")" == "1" ]]
check "a submit on the caller's own surface in the same workspace is not counted" $? "out=$out"

# The session filter carries case 3 on its own (the caller's REPL is a different
# session), so the SURFACE half of the attribution needs its own fixture: the same
# session id reported against a different surface. A session is not pinned to one
# place — a `claude --resume` puts the same uuid in a second surface — and with no
# --session passed at all the surface is the ONLY discriminator there is.
f_same_session_other_surface() { ingest_frame $((BASE_SEQ+1)) "$SURF_UUID" "$SESS_UUID" completed
                                 ingest_frame $((BASE_SEQ+2)) "$OTHER_SURF" "$SESS_UUID" received
                                 ingest_frame $((BASE_SEQ+3)) "$OTHER_SURF" "$SESS_UUID" completed; }
d="$STUBROOT/samesess"; out=$(run_case "$d" "frag000000000009" f_same_session_other_surface)
[[ "$(jq -r '.submit_frames // "absent"' <<<"$out")" == "1" ]]
check "our own session's turn in ANOTHER surface is not counted" $? "out=$out"

# --- 4. Attribution: another SESSION on our surface is not ours --------------
# A resumed surface can host a different session than the one we dialed.
f_other_session() { ingest_frame $((BASE_SEQ+1)) "$SURF_UUID" "$SESS_UUID" completed
                    ingest_frame $((BASE_SEQ+2)) "$SURF_UUID" "99999999-9999-4999-8999-999999999999" completed; }
d="$STUBROOT/othersess"; out=$(run_case "$d" "frag000000000004" f_other_session)
[[ "$(jq -r '.submit_frames // "absent"' <<<"$out")" == "1" ]]
check "a submit by another session is not counted as ours" $? "out=$out"

# --- 5. The seq marker scopes the window to THIS delivery --------------------
# The retained buffer REPLAYS. Without the before-marker, the previous exchange's
# turns count as this delivery's and every reused surface looks fragmented.
f_stale() { ingest_frame $((BASE_SEQ-50)) "$SURF_UUID" "$SESS_UUID" completed
            ingest_frame $((BASE_SEQ-40)) "$SURF_UUID" "$SESS_UUID" completed
            ingest_frame $((BASE_SEQ+1))  "$SURF_UUID" "$SESS_UUID" completed; }
d="$STUBROOT/stale"; out=$(run_case "$d" "frag000000000005" f_stale)
[[ "$(jq -r '.submit_frames // "absent"' <<<"$out")" == "1" ]]
check "turns from BEFORE the paste marker are not counted as this delivery's" $? "out=$out"

# --- 6. Measured-and-zero is a reading; unmeasurable is not ------------------
f_none() { :; }
d="$STUBROOT/zero"; out=$(run_case "$d" "frag000000000006" f_none)
[[ "$(jq -r '.submit_frames // "absent"' <<<"$out")" == "0" ]]
check "a confirmed delivery with no ingest yet in the window reports 0 (queued)" $? "out=$out"

# No event stream at all → the key is ABSENT. A 0 here would assert the callee
# ingested nothing, which the confirmed delivery above it has disproved.
d="$STUBROOT/noevents"; out=$(run_case "$d" "frag000000000007" f_one CMUX_STUB_NO_EVENTS=1)
jq -e 'has("submit_frames") | not' <<<"$out" >/dev/null 2>&1
check "a cmux with no event stream omits submit_frames rather than reporting 0" $? "out=$out"
jq -e '.delivered == true and .confirmed == "transcript"' <<<"$out" >/dev/null 2>&1
check "…and the delivery still confirms through the screen-reading fallbacks" $? "out=$out"

# --- 7. The cost gate --------------------------------------------------------
# cmux_events_all cannot return early, so the count spends its whole settle window
# on a ladder that confirms in well under a second. =0 must buy that back — and
# not by querying and discarding: the events subcommand must not be called at all.
d="$STUBROOT/gated"; out=$(run_case "$d" "frag000000000008" f_two HOTLINE_PASTE_INGEST_WINDOW=0)
jq -e 'has("submit_frames") | not' <<<"$out" >/dev/null 2>&1
check "HOTLINE_PASTE_INGEST_WINDOW=0 omits the field" $? "out=$out"
[[ ! -s "$d/sock/requests.log.events" ]]
check "…and spends no event query at all doing it" $? \
  "events calls: $(cat "$d/sock/requests.log.events" 2>/dev/null)"

# --- 8. The length check: cmux >= 0.65.0 only, one-sided, additive ----------
# run_case's payload is 5 lines; its stripped length is what a whole delivery reports.
LEN_CID="lenchk0000000001"
SENT_LEN=$(printf '[CALL_ID: %s]\nline one\nline two\nline three\nline four' "$LEN_CID" | wc -c | tr -d ' ')

# submitted_frame <seq> <workspace> <message_length> [preview]
# Shape of a live 0.65.0 capture: no surface_id, no session_id, message null.
submitted_frame() {
  printf '{"name":"workspace.prompt.submitted","seq":%s,"workspace_id":"%s","payload":{"message":null,"message_length":%s,"message_preview":"%s","redacted_fields":["message"],"workspace_id":"%s"}}\n' \
    "$1" "$2" "$3" "${4:-x}" "$2"
}
f_len_whole() { ingest_frame $((BASE_SEQ+1)) "$SURF_UUID" "$SESS_UUID" completed
                submitted_frame $((BASE_SEQ+2)) "$WS_UUID" "$SENT_LEN"; }
f_len_short() { ingest_frame $((BASE_SEQ+1)) "$SURF_UUID" "$SESS_UUID" completed
                submitted_frame $((BASE_SEQ+2)) "$WS_UUID" $((SENT_LEN - 20)); }

d="$STUBROOT/lenwhole"; out=$(run_case "$d" "$LEN_CID" f_len_whole CMUX_STUB_VERSION=0.65.0)
jq -e --argjson n "$SENT_LEN" '.length_check == {sent: $n, seen: $n, short: false}' <<<"$out" >/dev/null 2>&1
check "0.65.0, reported length == sent length → length_check.short:false" $? "out=$out"

d="$STUBROOT/lenshort"; out=$(run_case "$d" "$LEN_CID" f_len_short CMUX_STUB_VERSION=0.65.0)
jq -e --argjson n "$SENT_LEN" '.length_check == {sent: $n, seen: ($n - 20), short: true}' <<<"$out" >/dev/null 2>&1
check "0.65.0, reported length below sent → length_check.short:true (byte loss)" $? "out=$out"
# A suspected loss is a payload IN the queue; reporting it undelivered invites a resend.
jq -e '.delivered == true and .sent == true and .confirmed == "transcript" and .submit_frames == 1' <<<"$out" >/dev/null 2>&1
check "…and suspected loss does NOT change delivered/sent/confirmed or the frame count" $? "out=$out"

# Below 0.65.0 message_length is the preview's length: no length field, today's output.
d="$STUBROOT/lenold"; out=$(run_case "$d" "$LEN_CID" f_len_short CMUX_STUB_VERSION=0.64.25)
jq -e 'has("length_check") | not' <<<"$out" >/dev/null 2>&1
check "0.64.25 → no length_check, however short the frame reads" $? "out=$out"
jq -e '.submit_frames == 1 and .confirmed == "transcript"' <<<"$out" >/dev/null 2>&1
check "…and the rest of the result is unchanged" $? "out=$out"

# A cmux whose --version prints nothing (every stub before this one) reads as old.
d="$STUBROOT/lenunknown"; out=$(run_case "$d" "$LEN_CID" f_len_short)
jq -e 'has("length_check") | not' <<<"$out" >/dev/null 2>&1
check "unknown version → no length_check" $? "out=$out"

# 0.100.0 is newer than 0.65.0; a string compare would say otherwise.
d="$STUBROOT/lennumeric"; out=$(run_case "$d" "$LEN_CID" f_len_whole CMUX_STUB_VERSION=0.100.0)
jq -e 'has("length_check")' <<<"$out" >/dev/null 2>&1
check "versions compare numerically (0.100.0 >= 0.65.0)" $? "out=$out"

# Attribution. The workspace event cannot say whose submit it was, so a second
# workspace frame (another REPL, or fragmentation) leaves the length unread.
f_len_two_frames() { f_len_whole; submitted_frame $((BASE_SEQ+3)) "$WS_UUID" 17; }
d="$STUBROOT/lentwo"; out=$(run_case "$d" "$LEN_CID" f_len_two_frames CMUX_STUB_VERSION=0.65.0)
jq -e 'has("length_check") | not' <<<"$out" >/dev/null 2>&1
check "two workspace frames → ambiguous, length_check omitted" $? "out=$out"

# A frame from another workspace is not ours, and absence is not a reading.
f_len_other_ws() { ingest_frame $((BASE_SEQ+1)) "$SURF_UUID" "$SESS_UUID" completed
                   submitted_frame $((BASE_SEQ+2)) "DDDD0000-4444-4444-8444-444444444444" 5; }
d="$STUBROOT/lenotherws"; out=$(run_case "$d" "$LEN_CID" f_len_other_ws CMUX_STUB_VERSION=0.65.0)
jq -e 'has("length_check") | not' <<<"$out" >/dev/null 2>&1
check "a frame from another workspace → omitted, not a fake 0" $? "out=$out"

# A workspace frame with no ingest of ours beside it is somebody else's submit.
f_len_no_ingest() { submitted_frame $((BASE_SEQ+2)) "$WS_UUID" 5; }
d="$STUBROOT/lennoingest"; out=$(run_case "$d" "$LEN_CID" f_len_no_ingest CMUX_STUB_VERSION=0.65.0)
jq -e 'has("length_check") | not' <<<"$out" >/dev/null 2>&1
check "no ingest of ours in the window → length not attributed, omitted" $? "out=$out"

# A new CLI on PATH over a not-yet-restarted old app still emits capped frames: an
# ellipsized preview whose length IS the message_length. That is not a measurement.
CAPPED="$(printf 'a%.0s' {1..239})…"
f_len_oldapp() { ingest_frame $((BASE_SEQ+1)) "$SURF_UUID" "$SESS_UUID" completed
                 submitted_frame $((BASE_SEQ+2)) "$WS_UUID" 240 "$CAPPED"; }
d="$STUBROOT/lenoldapp"; out=$(run_case "$d" "$LEN_CID" f_len_oldapp CMUX_STUB_VERSION=0.65.0)
jq -e 'has("length_check") | not' <<<"$out" >/dev/null 2>&1
check "a capped 240 with an ellipsized preview is not read as a true length" $? "out=$out"

# The same preview with a LONGER message_length is the fixed shape.
f_len_long() { ingest_frame $((BASE_SEQ+1)) "$SURF_UUID" "$SESS_UUID" completed
               submitted_frame $((BASE_SEQ+2)) "$WS_UUID" 1260 "$CAPPED"; }
d="$STUBROOT/len1260"; out=$(run_case "$d" "$LEN_CID" f_len_long CMUX_STUB_VERSION=0.65.0)
jq -e '.length_check.seen == 1260 and .length_check.short == false' <<<"$out" >/dev/null 2>&1
check "an ellipsized preview with a longer message_length is the fixed shape → read" $? "out=$out"

d="$STUBROOT/lengated"; out=$(run_case "$d" "$LEN_CID" f_len_whole CMUX_STUB_VERSION=0.65.0 HOTLINE_PASTE_INGEST_WINDOW=0)
jq -e 'has("length_check") | not' <<<"$out" >/dev/null 2>&1
check "HOTLINE_PASTE_INGEST_WINDOW=0 omits length_check too" $? "out=$out"

# --- 9. payload-graphemes.py: never a false byte-loss on non-ASCII -----------
G="$HOTLINE_DIR/scripts/payload-graphemes.py"
t="$STUBROOT/g"; mkdir -p "$t"
printf 'caf\xc3\xa9 \xe2\x80\x94 \xe2\x9c\x85\n' > "$t/plain"   # é, em dash, ✅ — one codepoint each
got=$("$REAL_PYTHON3" "$G" "$t/plain")
[[ "$got" == "8" ]]
check "single-codepoint non-ASCII counts once each (not as bytes)" $? "got '$got'"
printf 'e\xcc\x81x' > "$t/combining"                           # e + U+0301: one cluster, two codepoints
[[ -z "$("$REAL_PYTHON3" "$G" "$t/combining")" ]]
check "a combining sequence is declined (codepoints would over-count clusters)" $?
printf '\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9' > "$t/zwj"
[[ -z "$("$REAL_PYTHON3" "$G" "$t/zwj")" ]]
check "a ZWJ sequence is declined" $?
printf 'a\r\nb' > "$t/crlf"
[[ -z "$("$REAL_PYTHON3" "$G" "$t/crlf")" ]]
check "CRLF is declined (one cluster, two codepoints)" $?
printf '\n\n  hello  \n\n' > "$t/ws"
got=$("$REAL_PYTHON3" "$G" "$t/ws")
[[ "$got" == "5" ]]
check "surrounding whitespace is stripped from the sent length" $? "got '$got'"
printf 'ab \xef\xbe\x9e cd' > "$t/halfwidth"                  # U+FF9E: Extend in Swift, though category Lm
[[ -z "$("$REAL_PYTHON3" "$G" "$t/halfwidth")" ]]
check "U+FF9E (halfwidth voiced mark) is declined" $?
printf 'a\x01b' > "$t/ctrl"
[[ -z "$("$REAL_PYTHON3" "$G" "$t/ctrl")" ]]
check "an ASCII control character is declined" $?
printf '\xff\xfe' > "$t/bad"
[[ -z "$("$REAL_PYTHON3" "$G" "$t/bad")" ]]
check "invalid UTF-8 is declined, not guessed" $?

echo
echo "cmux-paste-fragmentation: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  failed: %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
