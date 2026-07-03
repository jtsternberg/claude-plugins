#!/usr/bin/env bash
# =============================================================================
# Tests for the hotline switchboard: registry reading, transcript parsing/
# tailing, and server endpoints — all against synthesized fixtures in a temp
# HOME-like sandbox. No real registry or transcripts are touched.
#
# Usage: bash plugins/hotline/tests/switchboard_test.sh
# Exit 0 on success; exit 1 with failing case names on any failure.
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB_SCRIPTS="$SCRIPT_DIR/../skills/switchboard/scripts"

PASS=0
FAIL=0
FAILED_CASES=()

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"; }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 0
fi

# ---- sandbox ----------------------------------------------------------------

SANDBOX=$(mktemp -d)
trap 'kill "$SERVER_PID" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

SESSIONS_DIR="$SANDBOX/sessions"
PROJECTS_ROOT="$SANDBOX/projects"
mkdir -p "$SESSIONS_DIR" "$PROJECTS_ROOT/-tmp-caller-ws" "$PROJECTS_ROOT/-tmp-callee-ws"

CALLER_SID="aaaaaaaa-1111-2222-3333-444444444444"
CALLEE_SID="bbbbbbbb-5555-6666-7777-888888888888"
NOW=$(date +%s)

cat > "$SESSIONS_DIR/${CALLER_SID}.json" <<EOF
{
  "caller": "/tmp/caller-ws",
  "caller_session_id": "${CALLER_SID}",
  "connections": {
    "/tmp/callee-ws": {
      "session_id": "${CALLEE_SID}",
      "started": $((NOW - 300)),
      "last_contact": ${NOW},
      "mode": "work_order",
      "exchange_count": 3
    }
  }
}
EOF

# Stale entry pointing at a session with no transcript
cat > "$SESSIONS_DIR/stale.json" <<EOF
{
  "caller": "/tmp/old-ws",
  "caller_session_id": "cccccccc-0000-0000-0000-000000000000",
  "connections": {
    "/tmp/gone-ws": {
      "session_id": "dddddddd-0000-0000-0000-000000000000",
      "started": $((NOW - 900000)),
      "last_contact": $((NOW - 900000)),
      "mode": "quick_call",
      "exchange_count": 1
    }
  }
}
EOF

CALLER_T="$PROJECTS_ROOT/-tmp-caller-ws/${CALLER_SID}.jsonl"
CALLEE_T="$PROJECTS_ROOT/-tmp-callee-ws/${CALLEE_SID}.jsonl"

cat > "$CALLER_T" <<'EOF'
{"type":"user","timestamp":"2026-07-02T10:00:00Z","message":{"role":"user","content":"Hello there **bold** question"}}
{"type":"assistant","timestamp":"2026-07-02T10:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"Answering the question."},{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}
{"type":"user","timestamp":"2026-07-02T10:00:06Z","message":{"role":"user","content":[{"type":"tool_result","content":"file1\nfile2"}]}}
{"type":"user","isMeta":true,"message":{"role":"user","content":"meta noise should be skipped"}}
{"type":"user","isSidechain":true,"message":{"role":"user","content":"sidechain noise should be skipped"}}
{"type":"summary","summary":"Compacted: earlier discussion"}
{"type":"user","message":{"role":"user","content":"<system-reminder>injected</system-reminder>real user text"}}
not-json-garbage-line
EOF

cat > "$CALLEE_T" <<'EOF'
{"type":"user","timestamp":"2026-07-02T10:00:01Z","message":{"role":"user","content":"Incoming call payload"}}
{"type":"assistant","timestamp":"2026-07-02T10:00:09Z","message":{"role":"assistant","content":[{"type":"text","text":"Callee response"}]}}
EOF

PORT=$(( (RANDOM % 2000) + 42000 ))
HOTLINE_SESSIONS_DIR="$SESSIONS_DIR" HOTLINE_PROJECTS_ROOT="$PROJECTS_ROOT" \
  node "$SB_SCRIPTS/server.js" --port="$PORT" --stale-hours=24 > "$SANDBOX/server.log" 2>&1 &
SERVER_PID=$!

# Wait for server up
for _ in $(seq 1 20); do
  curl -sf "http://127.0.0.1:$PORT/api/calls" >/dev/null 2>&1 && break
  sleep 0.25
done

BASE="http://127.0.0.1:$PORT"

# ---- case: server boots and serves dashboard --------------------------------

if curl -sf "$BASE/" | grep -q "Hotline Switchboard"; then
  pass "dashboard HTML served"
else
  fail "dashboard HTML served"
fi

# ---- case: /api/calls enumerates registry, classifies status -----------------

CALLS=$(curl -sf "$BASE/api/calls")
if [[ $(echo "$CALLS" | jq '.calls | length') == "2" ]]; then
  pass "registry: both calls enumerated"
else
  fail "registry: both calls enumerated"
fi

LIVE_STATUS=$(echo "$CALLS" | jq -r --arg sid "$CALLER_SID" '.calls[] | select(.caller.session_id==$sid) | .status')
if [[ "$LIVE_STATUS" == "live" ]]; then
  pass "registry: fresh call classified live"
else
  fail "registry: fresh call classified live (got: $LIVE_STATUS)"
fi

STALE_STATUS=$(echo "$CALLS" | jq -r '.calls[] | select(.mode=="quick_call") | .status')
if [[ "$STALE_STATUS" == "stale" ]]; then
  pass "registry: old call classified stale"
else
  fail "registry: old call classified stale (got: $STALE_STATUS)"
fi

HAS_T=$(echo "$CALLS" | jq -r --arg sid "$CALLER_SID" '.calls[] | select(.caller.session_id==$sid) | .callee.has_transcript')
if [[ "$HAS_T" == "true" ]]; then
  pass "registry: transcript resolved via slugified cwd"
else
  fail "registry: transcript resolved via slugified cwd"
fi

# ---- case: transcript parsing -------------------------------------------------

TRANS=$(curl -sf "$BASE/api/transcript?session=$CALLER_SID")
COUNT=$(echo "$TRANS" | jq '.entries | length')
# Expected: user, assistant(+tool), tool_result, summary, cleaned user = 5
if [[ "$COUNT" == "5" ]]; then
  pass "parser: correct entry count (meta/sidechain/garbage skipped)"
else
  fail "parser: correct entry count (expected 5, got $COUNT)"
fi

if [[ $(echo "$TRANS" | jq -r '.entries[1].tools[0]') == "Bash: ls -la" ]]; then
  pass "parser: tool_use labeled"
else
  fail "parser: tool_use labeled"
fi

if [[ $(echo "$TRANS" | jq -r '.entries[4].text') == "real user text" ]]; then
  pass "parser: system-reminder noise stripped"
else
  fail "parser: system-reminder noise stripped"
fi

if [[ $(echo "$TRANS" | jq -r '.entries[3].kind') == "summary" ]]; then
  pass "parser: compaction summary surfaced"
else
  fail "parser: compaction summary surfaced"
fi

# ---- case: missing transcript -> 404 ------------------------------------------

CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/transcript?session=dddddddd-0000-0000-0000-000000000000")
if [[ "$CODE" == "404" ]]; then
  pass "missing transcript returns 404"
else
  fail "missing transcript returns 404 (got $CODE)"
fi

# ---- case: incremental tailing via offset --------------------------------------

OFFSET=$(echo "$TRANS" | jq '.offset')
echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"NEW LIVE ENTRY"}]}}' >> "$CALLER_T"
TRANS2=$(curl -sf "$BASE/api/transcript?session=$CALLER_SID&offset=$OFFSET")
if [[ $(echo "$TRANS2" | jq -r '.entries[0].text') == "NEW LIVE ENTRY" && $(echo "$TRANS2" | jq '.entries | length') == "1" ]]; then
  pass "tailing: offset read returns only new entries"
else
  fail "tailing: offset read returns only new entries"
fi

# ---- case: partial trailing line is not consumed --------------------------------

OFFSET2=$(echo "$TRANS2" | jq '.offset')
printf '{"type":"assistant","message":{"role":"assistant","con' >> "$CALLER_T"
TRANS3=$(curl -sf "$BASE/api/transcript?session=$CALLER_SID&offset=$OFFSET2")
if [[ $(echo "$TRANS3" | jq '.entries | length') == "0" && $(echo "$TRANS3" | jq '.offset') == "$OFFSET2" ]]; then
  pass "tailing: partial line left unconsumed"
else
  fail "tailing: partial line left unconsumed"
fi

# ---- case: SSE streams new entries ----------------------------------------------

printf 'tent":[{"type":"text","text":"finished line"}]}}\n' >> "$CALLER_T"
SSE_OUT="$SANDBOX/sse.out"
curl -sN --max-time 4 "$BASE/api/watch?sessions=$CALLER_SID" > "$SSE_OUT" &
CURL_PID=$!
sleep 1.5
echo '{"type":"user","message":{"role":"user","content":"SSE PUSHED MESSAGE"}}' >> "$CALLER_T"
wait "$CURL_PID" 2>/dev/null
if grep -q "SSE PUSHED MESSAGE" "$SSE_OUT"; then
  pass "sse: new transcript entry pushed to stream"
else
  fail "sse: new transcript entry pushed to stream"
fi

# ---- case: bad session id rejected -----------------------------------------------

CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/transcript?session=../../etc/passwd")
if [[ "$CODE" == "400" ]]; then
  pass "security: path-traversal session id rejected"
else
  fail "security: path-traversal session id rejected (got $CODE)"
fi

# ---- case: discovery scan reconstructs unregistered calls from ringing handshakes -

DISC_SID="eeeeeeee-1234-5678-9abc-def012345678"
mkdir -p "$PROJECTS_ROOT/-tmp-discovered-ws"
cat > "$PROJECTS_ROOT/-tmp-discovered-ws/${DISC_SID}.jsonl" <<'EOF'
{"type":"user","cwd":"/tmp/discovered-ws","timestamp":"2026-07-02T11:00:00Z","message":{"role":"user","content":"/hotline-ringing [CALL_ID: abc123] [MODE: work_order] [CALLER: /tmp/caller-ws] [SESSION: aaaaaaaa-1111-2222-3333-444444444444] Please do the thing"}}
{"type":"assistant","cwd":"/tmp/discovered-ws","message":{"role":"assistant","content":[{"type":"text","text":"On it."}]}}
EOF

DISC_CALLS=$(curl -sf "$BASE/api/calls")
DISC=$(echo "$DISC_CALLS" | jq -r --arg sid "$DISC_SID" '.calls[] | select(.callee.session_id==$sid)')
if [[ -n "$DISC" ]]; then
  pass "discovery: unregistered call reconstructed from ringing handshake"
else
  fail "discovery: unregistered call reconstructed from ringing handshake"
fi

if [[ $(echo "$DISC" | jq -r '.mode') == "work_order" && $(echo "$DISC" | jq -r '.caller.path') == "/tmp/caller-ws" \
   && $(echo "$DISC" | jq -r '.callee.path') == "/tmp/discovered-ws" && $(echo "$DISC" | jq -r '.discovered') == "true" ]]; then
  pass "discovery: mode/caller/callee parsed from handshake tags"
else
  fail "discovery: mode/caller/callee parsed from handshake tags (got: $DISC)"
fi

# Registry entries must NOT be duplicated by discovery (callee sid already known)
DUP_COUNT=$(echo "$DISC_CALLS" | jq --arg sid "$CALLEE_SID" '[.calls[] | select(.callee.session_id==$sid)] | length')
if [[ "$DUP_COUNT" == "1" ]]; then
  pass "discovery: registry-tracked calls not duplicated"
else
  fail "discovery: registry-tracked calls not duplicated (got $DUP_COUNT)"
fi

# Non-hotline transcripts are ignored
PLAIN_SID="ffffffff-0000-1111-2222-333333333333"
echo '{"type":"user","cwd":"/tmp/discovered-ws","message":{"role":"user","content":"just a normal session"}}' \
  > "$PROJECTS_ROOT/-tmp-discovered-ws/${PLAIN_SID}.jsonl"
FOUND_PLAIN=$(curl -sf "$BASE/api/calls" | jq -r --arg sid "$PLAIN_SID" '[.calls[] | select(.callee.session_id==$sid)] | length')
if [[ "$FOUND_PLAIN" == "0" ]]; then
  pass "discovery: non-hotline transcripts ignored"
else
  fail "discovery: non-hotline transcripts ignored"
fi

# ---- case: launchers persist call meta; wait-for-session registers the call -------

DIAL_SCRIPTS_DIR="$SCRIPT_DIR/../skills/dial/scripts"
META_DIR=$(mktemp -d "$SANDBOX/callmeta.XXXX")
RING_PROMPT="/hotline-ringing [CALL_ID: xyz] [MODE: quick_call] [CALLER: /tmp/caller-ws] [SESSION: aaaaaaaa-1111-2222-3333-444444444444] hello"
bash "$DIAL_SCRIPTS_DIR/persist-call-meta.sh" "$META_DIR" "/tmp/reg-target-ws" "$RING_PROMPT"
if [[ $(cat "$META_DIR/mode.txt" 2>/dev/null) == "quick_call" \
   && $(cat "$META_DIR/caller_session.txt" 2>/dev/null) == "aaaaaaaa-1111-2222-3333-444444444444" \
   && $(cat "$META_DIR/cwd.txt" 2>/dev/null) == "/tmp/reg-target-ws" ]]; then
  pass "auto-cache: persist-call-meta writes mode/caller-session/cwd"
else
  fail "auto-cache: persist-call-meta writes mode/caller-session/cwd"
fi

REG_HOME="$SANDBOX/reghome"
mkdir -p "$REG_HOME" "/tmp/reg-target-ws" 2>/dev/null || true
REG_SID="99999999-aaaa-bbbb-cccc-dddddddddddd"
( sleep 1; echo "$REG_SID" > "$META_DIR/session_id.txt" ) &
GOT_SID=$(HOME="$REG_HOME" bash "$DIAL_SCRIPTS_DIR/wait-for-session.sh" "$META_DIR" --timeout 10)
REG_FILE="$REG_HOME/.agents-hotline/sessions/aaaaaaaa-1111-2222-3333-444444444444.json"
if [[ "$GOT_SID" == "$REG_SID" && -f "$REG_FILE" ]] \
   && [[ $(jq -r '[.connections[] | .session_id] | first' "$REG_FILE") == "$REG_SID" ]]; then
  pass "auto-cache: wait-for-session registers call in sessions registry"
else
  fail "auto-cache: wait-for-session registers call in sessions registry (sid=$GOT_SID, file=$([[ -f $REG_FILE ]] && echo yes || echo no))"
fi

# register-call.sh is a silent no-op when metadata is missing
BARE_DIR=$(mktemp -d "$SANDBOX/bare.XXXX")
echo "some-sid" > "$BARE_DIR/session_id.txt"
if HOME="$REG_HOME" bash "$DIAL_SCRIPTS_DIR/register-call.sh" "$BARE_DIR"; then
  pass "auto-cache: register-call no-ops without metadata"
else
  fail "auto-cache: register-call no-ops without metadata"
fi

# ---- case: start replaces prior instances (pidfile + ad-hoc port squatter) --------

TAKEOVER_PORT=$(( PORT + 2 ))
TK_HOME="$SANDBOX/tkhome"
mkdir -p "$TK_HOME"
# Squat the port with an ad-hoc server (no pidfile — simulates `node server.js` by hand)
HOTLINE_SESSIONS_DIR="$SESSIONS_DIR" HOTLINE_PROJECTS_ROOT="$PROJECTS_ROOT" \
  node "$SB_SCRIPTS/server.js" --port="$TAKEOVER_PORT" > /dev/null 2>&1 &
SQUATTER_PID=$!
sleep 0.5
TK_OUT=$(HOME="$TK_HOME" HOTLINE_SESSIONS_DIR="$SESSIONS_DIR" HOTLINE_PROJECTS_ROOT="$PROJECTS_ROOT" \
  bash "$SB_SCRIPTS/switchboard.sh" start --port="$TAKEOVER_PORT" --no-open)
sleep 0.3
if [[ $(echo "$TK_OUT" | jq -r '.status') == "started" ]] && ! kill -0 "$SQUATTER_PID" 2>/dev/null; then
  pass "takeover: start kills ad-hoc port squatter and boots fresh"
else
  fail "takeover: start kills ad-hoc port squatter and boots fresh (got: $TK_OUT)"
fi
FIRST_PID=$(echo "$TK_OUT" | jq -r '.pid')
# Second start replaces the pidfile instance instead of reporting already_running
TK_OUT2=$(HOME="$TK_HOME" HOTLINE_SESSIONS_DIR="$SESSIONS_DIR" HOTLINE_PROJECTS_ROOT="$PROJECTS_ROOT" \
  bash "$SB_SCRIPTS/switchboard.sh" start --port="$TAKEOVER_PORT" --no-open)
sleep 0.3
if [[ $(echo "$TK_OUT2" | jq -r '.status') == "started" ]] && ! kill -0 "$FIRST_PID" 2>/dev/null; then
  pass "takeover: restart replaces pidfile instance"
else
  fail "takeover: restart replaces pidfile instance (got: $TK_OUT2)"
fi
HOME="$TK_HOME" bash "$SB_SCRIPTS/switchboard.sh" stop > /dev/null

# ---- case: switchboard.sh start/status/stop lifecycle -----------------------------

SB_PORT=$(( PORT + 1 ))
LIFE_HOME="$SANDBOX/home"
mkdir -p "$LIFE_HOME"
START_OUT=$(HOME="$LIFE_HOME" HOTLINE_SESSIONS_DIR="$SESSIONS_DIR" HOTLINE_PROJECTS_ROOT="$PROJECTS_ROOT" \
  bash "$SB_SCRIPTS/switchboard.sh" start --port="$SB_PORT" --no-open)
if [[ $(echo "$START_OUT" | jq -r '.status') == "started" ]]; then
  pass "lifecycle: start"
else
  fail "lifecycle: start (got: $START_OUT)"
fi

STATUS_OUT=$(HOME="$LIFE_HOME" bash "$SB_SCRIPTS/switchboard.sh" status)
if [[ $(echo "$STATUS_OUT" | jq -r '.status') == "running" ]]; then
  pass "lifecycle: status running"
else
  fail "lifecycle: status running (got: $STATUS_OUT)"
fi

STOP_OUT=$(HOME="$LIFE_HOME" bash "$SB_SCRIPTS/switchboard.sh" stop)
if [[ $(echo "$STOP_OUT" | jq -r '.status') == "stopped" ]]; then
  pass "lifecycle: stop"
else
  fail "lifecycle: stop (got: $STOP_OUT)"
fi

STATUS_OUT2=$(HOME="$LIFE_HOME" bash "$SB_SCRIPTS/switchboard.sh" status)
if [[ $(echo "$STATUS_OUT2" | jq -r '.status') == "not_running" ]]; then
  pass "lifecycle: status not_running after stop"
else
  fail "lifecycle: status not_running after stop (got: $STATUS_OUT2)"
fi

# ---- summary ----------------------------------------------------------------

echo ""
echo "PASS: $PASS  FAIL: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf 'Failed: %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
