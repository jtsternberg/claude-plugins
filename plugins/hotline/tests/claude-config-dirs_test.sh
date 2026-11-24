#!/usr/bin/env bash
# =============================================================================
# Every hotline script that reads Claude Code's own state looks in the same
# config dirs, in the same order: $CLAUDE_CONFIG_DIR (default ~/.claude), then
# $HOTLINE_CLAUDE_CONFIG_DIRS. Fake config dirs in a temp HOME; no live session.
#
# Each case runs under env -u for both vars and sets only what it is about: JT's
# shell exports HOTLINE_CLAUDE_CONFIG_DIRS pointing at the REAL dirs, so an
# unsanitized run would search the real ~/.claude-alt.
# =============================================================================
set -u
TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT=${TMP_ROOT%/}
HOTLINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$HOTLINE_DIR/scripts"
PASS=0; FAIL=0; FAILED_CASES=()
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; return 0; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want [$3] got [$2]"; fi; }

T=$(mktemp -d "$TMP_ROOT"/hotline-cfgdirs-XXXXXX)
T=$(cd -P "$T" && pwd -P)
SERVER_PID=""
trap '[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$T"' EXIT
H="$T/home"; ALT="$H/.claude-alt"; WS="$T/ws"
mkdir -p "$H/.claude/projects" "$ALT/projects" "$WS"
ENC=$(printf '%s' "$WS" | sed 's|[^a-zA-Z0-9]|-|g')
SID="deadbeef-1111-2222-3333-444444444444"

# Run with a clean config environment: run [VAR=value ...] -- cmd...
run() {
  local -a sets=()
  while [[ "$1" != "--" ]]; do sets+=("$1"); shift; done; shift
  env -u CLAUDE_CONFIG_DIR -u HOTLINE_CLAUDE_CONFIG_DIRS -u HOTLINE_CLAUDE_CONFIG_DIR \
    -u HOTLINE_PROJECTS_ROOT -u HOTLINE_CALLER_SESSION_ID -u CODEX_THREAD_ID \
    HOME="$H" ${sets[@]+"${sets[@]}"} "$@"
}

echo "claude-config-dirs.sh"
ln -s "$ALT" "$H/alt-link"
eq "default is ~/.claude alone" "$(run -- bash "$S/claude-config-dirs.sh")" "$H/.claude"
eq "CLAUDE_CONFIG_DIR replaces the default, extras follow in order, dupes and empties drop" \
  "$(run CLAUDE_CONFIG_DIR="$T/custom" HOTLINE_CLAUDE_CONFIG_DIRS="$ALT::$H/alt-link:$T/custom/:$H/.claude" -- bash "$S/claude-config-dirs.sh" | tr '\n' ' ')" \
  "$T/custom $ALT $H/.claude "

echo "transcript-path.sh"
TP=(bash "$S/transcript-path.sh" --cwd "$WS" --session "$SID")
eq "no transcript anywhere → primary dir" "$(run HOTLINE_CLAUDE_CONFIG_DIRS="$ALT" -- "${TP[@]}")" "$H/.claude/projects/$ENC/$SID.jsonl"
mkdir -p "$ALT/projects/$ENC"; echo '{"cwd":"'"$WS"'"}' > "$ALT/projects/$ENC/$SID.jsonl"
eq "transcript only in an extra dir → that dir" "$(run HOTLINE_CLAUDE_CONFIG_DIRS="$ALT" -- "${TP[@]}")" "$ALT/projects/$ENC/$SID.jsonl"
eq "extra dir not listed → primary" "$(run -- "${TP[@]}")" "$H/.claude/projects/$ENC/$SID.jsonl"
eq "HOTLINE_CLAUDE_CONFIG_DIR override still wins" "$(run HOTLINE_CLAUDE_CONFIG_DIR="$T/o" HOTLINE_CLAUDE_CONFIG_DIRS="$ALT" -- "${TP[@]}")" "$T/o/projects/$ENC/$SID.jsonl"

echo "resolve-workspace.sh"
eq "session id whose transcript is in an extra dir resolves its workspace" \
  "$(cd "$T" && run HOTLINE_CLAUDE_CONFIG_DIRS="$ALT" -- bash "$HOTLINE_DIR/skills/dial/scripts/resolve-workspace.sh" "$SID" 2>/dev/null)" "$WS"

echo "session-init.sh"
OUT=$(cd "$WS" && run CLAUDE_CODE_SESSION_ID="$SID" HOTLINE_SESSION_CACHE_DIR="$T" HOTLINE_CLAUDE_CONFIG_DIRS="$ALT" -- bash "$S/session-init.sh" --expanded)
eq "native identity finds its transcript in an extra dir" "$(jq -r .transcript_path <<<"$OUT")" "$ALT/projects/$ENC/$SID.jsonl"

echo "session-discover.sh"
FP="hotline-fp-$RANDOM$RANDOM"
SID2="deadbeef-5555-6666-7777-888888888888"
echo "{\"msg\":\"$FP\"}" > "$ALT/projects/$ENC/$SID2.jsonl"
eq "fingerprint planted in an extra dir's transcript is found" \
  "$(cd "$WS" && run HOTLINE_CLAUDE_CONFIG_DIRS="$ALT" -- bash "$S/session-discover.sh" "$FP" 2>/dev/null)" "$SID2"

echo "ambiguity"
mkdir -p "$H/.claude/projects/$ENC"; cp "$ALT/projects/$ENC/$SID.jsonl" "$H/.claude/projects/$ENC/"
run HOTLINE_CLAUDE_CONFIG_DIRS="$ALT" -- "${TP[@]}" >/dev/null 2>&1
eq "transcript-path.sh refuses an id in two config dirs" "$?" "1"
ERR=$(cd "$T" && run HOTLINE_CLAUDE_CONFIG_DIRS="$ALT" -- bash "$HOTLINE_DIR/skills/dial/scripts/resolve-workspace.sh" "$SID" 2>&1 >/dev/null)
if [[ "$ERR" == *ambiguous* ]]; then pass "resolve-workspace.sh refuses an id in two config dirs"; else fail "resolve-workspace.sh refuses an id in two config dirs" "$ERR"; fi
rm -rf "$H/.claude/projects/$ENC"

# A second account commonly symlinks projects/ to the first's, so one transcript
# is reachable through both dirs: that is one session, not two.
echo "shared projects/ (symlinked)"
SH="$T/shared"; mkdir -p "$SH/.claude/projects/$ENC" "$SH/.claude-alt"
ln -s "$SH/.claude/projects" "$SH/.claude-alt/projects"
echo '{"cwd":"'"$WS"'"}' > "$SH/.claude/projects/$ENC/$SID.jsonl"
eq "transcript-path.sh: one file through two dirs is not ambiguous" \
  "$(run HOME="$SH" HOTLINE_CLAUDE_CONFIG_DIRS="$SH/.claude-alt" -- "${TP[@]}" 2>&1)" "$SH/.claude/projects/$ENC/$SID.jsonl"
eq "resolve-workspace.sh: one file through two dirs is not ambiguous" \
  "$(cd "$T" && run HOME="$SH" HOTLINE_CLAUDE_CONFIG_DIRS="$SH/.claude-alt" -- bash "$HOTLINE_DIR/skills/dial/scripts/resolve-workspace.sh" "$SID" 2>&1)" "$WS"

echo "switchboard server.js"
if command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  PORT=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
  mkdir -p "$H/.agents-hotline/sessions"
  run HOTLINE_CLAUDE_CONFIG_DIRS="$ALT" HOTLINE_SESSIONS_DIR="$H/.agents-hotline/sessions" -- \
    node "$HOTLINE_DIR/skills/switchboard/scripts/server.js" --port="$PORT" > "$T/sb.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT/api/calls" >/dev/null 2>&1 && break; sleep 0.25; done
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/transcript?session=$SID")
  eq "serves a transcript that lives in an extra dir" "$CODE" "200"
  kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""

  # Shared projects/: discovery must list a traced call once, not once per dir.
  DSID="deadbeef-9999-aaaa-bbbb-cccccccccccc"
  echo '{"type":"user","cwd":"'"$WS"'","timestamp":"2026-07-02T11:00:00Z","message":{"role":"user","content":"/hotline:hotline-ringing [CALL_ID: abc123] [MODE: work_order] [CALLER: /tmp/caller-ws] [SESSION: aaaaaaaa-1111-2222-3333-444444444444] do it"}}' \
    > "$SH/.claude/projects/$ENC/$DSID.jsonl"
  mkdir -p "$SH/.agents-hotline/sessions"
  PORT=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
  run HOME="$SH" HOTLINE_CLAUDE_CONFIG_DIRS="$SH/.claude-alt" HOTLINE_SESSIONS_DIR="$SH/.agents-hotline/sessions" -- \
    node "$HOTLINE_DIR/skills/switchboard/scripts/server.js" --port="$PORT" > "$T/sb2.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT/api/calls" >/dev/null 2>&1 && break; sleep 0.25; done
  eq "shared projects/ lists a discovered call once" \
    "$(curl -sf "http://127.0.0.1:$PORT/api/calls" | jq --arg s "$DSID" '[.calls[] | select(.callee.session_id == $s)] | length')" "1"
else
  echo "  SKIP: node or curl not available"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || { printf '  failed: %s\n' "${FAILED_CASES[@]}"; exit 1; }
