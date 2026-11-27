#!/usr/bin/env bash
# =============================================================================
# you-should-know.sh — relaying the callee's "You should know" mod notes.
#
# Fixture store files under a scratch HOME only; the real ~/.claude store is
# never read. Covers the reader's quiet/broken rules, the call-dir seed (written
# once at dial), the collected-notes file, and the waiter's additive output.
# =============================================================================
set -u
unset CLAUDE_CONFIG_DIR HOTLINE_CLAUDE_CONFIG_DIR HOTLINE_CLAUDE_CONFIG_DIRS
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
READER="$ROOT/scripts/you-should-know.sh"
DIAL_SCRIPTS="$ROOT/skills/dial/scripts"
WAIT="$DIAL_SCRIPTS/wait-for-response.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [[ -n "${2:-}" ]] && echo "    $2"; return 0; }
check() { if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1" "${3:-}"; fi; }

TMP_ROOT="${TMPDIR:-/tmp}"; TMP_ROOT=${TMP_ROOT%/}
T=$(mktemp -d "$TMP_ROOT"/hotline-ysk-test-XXXXXX); trap 'rm -rf "$T"' EXIT
SID="11111111-2222-4333-8444-555555555555"
NOW_MS=$(( $(date +%s) * 1000 ))

new_home() { # → fresh scratch HOME
  local h; h=$(mktemp -d "$T/home-XXXXXX"); mkdir -p "$h/.claude/plugins/store"; echo "$h"
}
store() { # <home> <name-suffix> <json>
  printf '%s\n' "$3" > "$1/.claude/plugins/store/cc-plugin-you-should-know_builtin-$2.json"
}
offer() { # <session> <shownAt> [line] → a store document holding one offer
  jq -nc --arg s "$1" --argjson at "$2" --arg l "${3:-the migration order check will fail}" \
    '{known:[], seen:[], looksToSkip:0, typedPastInARow:0,
      sessions:[{id:$s, tag:"Heads up", view:{kind:"offer", line:$l, explanation:"why", shownAt:$at}}]}'
}
transcript() { # <path> <turns> <main-agent steps per turn> [sidechain steps per turn]
  mkdir -p "$(dirname "$1")"; : > "$1"
  local t i
  for ((t = 0; t < $2; t++)); do
    printf '{"type":"user","message":{"content":"prompt %s"}}\n' "$t" >> "$1"
    for ((i = 0; i < $3; i++)); do
      printf '{"type":"assistant","message":{"id":"msg_%s_%s"}}\n' "$t" "$i" >> "$1"
      printf '{"type":"assistant","message":{"id":"msg_%s_%s"}}\n' "$t" "$i" >> "$1"   # same message, 2nd block
      # A tool result continues the turn; it is not a new prompt.
      printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}\n' >> "$1"
    done
    for ((i = 0; i < ${4:-0}; i++)); do
      printf '{"type":"assistant","isSidechain":true,"message":{"id":"side_%s_%s"}}\n' "$t" "$i" >> "$1"
      printf '{"type":"user","isSidechain":true,"message":{"content":"subagent prompt"}}\n' >> "$1"
    done
  done
}
read_ysk() { # <home> [args] → OUT
  local h="$1"; shift
  OUT=$(HOME="$h" bash "$READER" --session "$SID" "$@" 2>/dev/null)
}
quiet() { [[ "$OUT" == '{"notes":[],"broken":null}' ]]; }
broken() { jq -e '.broken | type == "string" and startswith("maybe the you-should-know relay is broken")' <<<"$OUT" >/dev/null 2>&1; }

echo "you-should-know.sh reader:"

h=$(new_home); store "$h" a "$(offer "$SID" 5000)"
read_ysk "$h" --since 1000
[[ "$(jq -r '.notes[0].line' <<<"$OUT")" == "the migration order check will fail" && "$(jq -r '.notes[0].tag' <<<"$OUT")" == "Heads up" \
   && "$(jq -r '.broken' <<<"$OUT")" == null ]]
check "an offer newer than --since is returned with its tag" $? "$OUT"
read_ysk "$h" --since 5000; quiet; check "an offer at or before --since is quiet" $? "$OUT"

h=$(new_home); store "$h" a "$(offer "$SID" 5000)"
printf '{"enabledPlugins":{"cc-plugin-you-should-know@builtin":false}}\n' > "$h/.claude/settings.json"
read_ysk "$h"; quiet; check "mod disabled in settings.json → quiet" $? "$OUT"

ok=0
for k in asked making ready explaining explained off failed; do
  h=$(new_home)
  store "$h" a "$(jq -nc --arg s "$SID" --arg k "$k" '{sessions:[{id:$s, view:{kind:$k}}]}')"
  read_ysk "$h"; quiet || { ok=1; fail "known non-offer kind '$k' → quiet" "$OUT"; }
done
[[ $ok -eq 0 ]] && pass "every known non-offer kind is quiet"
h=$(new_home); store "$h" a "$(jq -nc --arg s "$SID" '{sessions:[{id:$s, askedTurn:"t"}]}')"
read_ysk "$h"; quiet; check "an entry with no view → quiet" $? "$OUT"

h=$(new_home); store "$h" a "$(jq -nc --arg s "$SID" '{sessions:[{id:$s, view:{kind:"glowing"}}]}')"
read_ysk "$h"; broken && [[ "$OUT" == *glowing* ]]; check "an unknown view kind → BROKEN naming it" $? "$OUT"

h=$(new_home); store "$h" old "$(offer "$SID" 5000 "from the old release")"; touch -t 202001010000 "$h/.claude/plugins/store/cc-plugin-you-should-know_builtin-old.json"
store "$h" new "$(offer "$SID" 6000 "from the new release")"
read_ysk "$h"; [[ "$(jq -r '.notes[0].line' <<<"$OUT")" == "from the new release" ]]
check "two store files → the newest by mtime is read, not BROKEN" $? "$OUT"
printf '{not json\n' > "$h/.claude/plugins/store/cc-plugin-you-should-know_builtin-new.json"
read_ysk "$h"; [[ "$(jq -r '.notes[0].line' <<<"$OUT")" == "from the old release" ]]
check "newest unparseable → falls back to the next that parses" $? "$OUT"
printf '{not json\n' > "$h/.claude/plugins/store/cc-plugin-you-should-know_builtin-old.json"
read_ysk "$h"; broken; check "no store file parses → BROKEN" $? "$OUT"

h=$(new_home); store "$h" a '{"sessions":{"x":1}}'
read_ysk "$h"; broken; check "sessions not an array → BROKEN" $? "$OUT"
h=$(new_home); store "$h" a "$(jq -nc --arg s "$SID" '{sessions:[{id:$s, view:{kind:"offer", line:"x"}}]}')"
read_ysk "$h"; broken; check "an offer missing shownAt → BROKEN" $? "$OUT"

# Missing store file and the canary: interactive vs headless.
h=$(new_home); transcript "$T/tx-many.jsonl" 1 8
read_ysk "$h" --transcript "$T/tx-many.jsonl"; broken; check "interactive, no store file, an 8-step turn → BROKEN" $? "$OUT"
read_ysk "$h" --transcript "$T/tx-many.jsonl" --headless; quiet; check "headless, no store file → quiet" $? "$OUT"
transcript "$T/tx-few.jsonl" 1 6 4
read_ysk "$h" --transcript "$T/tx-few.jsonl"; quiet
check "interactive, no store file, a 6-step turn (+ sidechain, + repeated ids) → quiet" $? "$OUT"
transcript "$T/tx-short.jsonl" 20 3
read_ysk "$h" --transcript "$T/tx-short.jsonl"; quiet
check "interactive, no store file, many 3-step turns (60 steps in all) → quiet" $? "$OUT"

h=$(new_home); store "$h" a "$(offer other-session 5000)"
read_ysk "$h" --transcript "$T/tx-many.jsonl"; broken && [[ "$OUT" == *"$SID"* ]]
check "canary: interactive, one 8-step turn, no entry for the session → BROKEN" $? "$OUT"
read_ysk "$h" --transcript "$T/tx-few.jsonl"; quiet; check "canary: a 6-step turn, no entry → quiet" $? "$OUT"
read_ysk "$h" --transcript "$T/tx-short.jsonl"; quiet; check "canary: many 3-step turns, no entry → quiet" $? "$OUT"
# The mod backs off on ignored notes, skipping up to 16 check opportunities.
h=$(new_home); store "$h" a "$(offer other-session 5000 | jq -c '.typedPastInARow = 7 | .looksToSkip = 16')"
read_ysk "$h" --transcript "$T/tx-many.jsonl"; quiet
check "canary: back-off in the store, 1 check opportunity → quiet" $? "$OUT"
transcript "$T/tx-16.jsonl" 16 7
read_ysk "$h" --transcript "$T/tx-16.jsonl"; quiet
check "canary: back-off, 16 opportunities (the most it can skip) → quiet" $? "$OUT"
transcript "$T/tx-17.jsonl" 17 7
read_ysk "$h" --transcript "$T/tx-17.jsonl"; broken && [[ "$OUT" == *"17 check opportunities"* ]]
check "canary: back-off, 17 opportunities → BROKEN" $? "$OUT"
transcript "$T/tx-2x13.jsonl" 1 13
h=$(new_home); store "$h" a "$(offer other-session 5000 | jq -c '.typedPastInARow = 2')"
read_ysk "$h" --transcript "$T/tx-2x13.jsonl"; quiet
check "canary: typedPastInARow nonzero counts as back-off" $? "$OUT"
read_ysk "$h" --transcript "$T/tx-many.jsonl" --headless; quiet; check "canary: headless → quiet" $? "$OUT"

# Store location: the callee's config dir first, then ~/.claude.
h=$(new_home); mkdir -p "$T/alt/plugins/store"
printf '%s\n' "$(offer "$SID" 5000 "from the alt account")" > "$T/alt/plugins/store/cc-plugin-you-should-know_builtin-z.json"
store "$h" a "$(offer "$SID" 5000 "from the default account")"
read_ysk "$h" --config-dir "$T/alt"; [[ "$(jq -r '.notes[0].line' <<<"$OUT")" == "from the alt account" ]]
check "a recorded config dir's store wins over ~/.claude's" $? "$OUT"
rm -rf "$T/alt/plugins"
read_ysk "$h" --config-dir "$T/alt"; [[ "$(jq -r '.notes[0].line' <<<"$OUT")" == "from the default account" ]]
check "no store under the config dir → falls back to ~/.claude/plugins/store" $? "$OUT"

echo "mark seeded at dial:"
h=$(new_home); mkdir -p "$T/bin" "$T/calls" "$T/target"
cat > "$T/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
jq -nc '{type:"result",session_id:"sess-h",result:"done\n\nSTATUS: WORK_COMPLETE"}'
STUB
chmod +x "$T/bin/claude"
before=$(( $(date +%s) * 1000 ))
launch=$(env PATH="$T/bin:$PATH" HOME="$h" HOTLINE_CALL_HOME="$T/calls" \
  bash "$DIAL_SCRIPTS/headless-call-async.sh" --cwd "$T/target" --prompt "do it" 2>/dev/null)
CD=$(jq -r '.call_dir' <<<"$launch" 2>/dev/null)
mark=$(cat "$CD/you_should_know_since.txt" 2>/dev/null)
[[ "$mark" =~ ^[0-9]+$ ]] && (( mark >= before && mark <= $(date +%s) * 1000 ))
check "a dial seeds the call dir's mark with the current epoch ms" $? "mark=$mark before=$before"
store "$h" a "$(offer sess-h $((mark - 1)) "shown before the dial")"
OUT=$(env HOME="$h" HOTLINE_POLL_SLEEP=0.1 bash "$WAIT" "$CD" --timeout 20 2>/dev/null); RC=$?
[[ $RC -eq 0 ]] && ! jq -e 'has("you_should_know") or has("you_should_know_broken")' <<<"$OUT" >/dev/null
check "a note shown before the dial (a resumed session's) is not relayed" $? "rc=$RC out=$OUT"

echo "waiter:"
# A finished call dir with no transport.txt: the waiter takes its file-watch path,
# and the relay treats the callee as interactive.
mk_call() { # <home> → call dir with a delivered response
  local d; d=$(mktemp -d "$T/calls/call-XXXXXX")
  jq -nc --arg s "$SID" '{session_id:$s, response:"the answer"}' > "$d/response.json"
  touch "$d/done"; echo "$T/target" > "$d/cwd.txt"
  printf '%s\n' "$NOW_MS" > "$d/you_should_know_since.txt"
  echo "$d"
}
wait_on() { OUT=$(env HOME="$1" HOTLINE_POLL_SLEEP=0.1 bash "$WAIT" "$2" --timeout 10 2>/dev/null); RC=$?; }

h=$(new_home); CD=$(mk_call "$h"); store "$h" a "$(offer "$SID" $((NOW_MS - 10)))"
wait_on "$h" "$CD"
[[ $RC -eq 0 && "$OUT" == "$(jq -c . "$CD/response.json")" ]]
check "no new note → output byte-identical to response.json" $? "rc=$RC out=$OUT"
rm "$CD/you_should_know_since.txt"; store "$h" a "$(offer "$SID" $((NOW_MS + 10)))"
wait_on "$h" "$CD"
[[ $RC -eq 0 && "$OUT" == "$(jq -c . "$CD/response.json")" ]]
check "a call dir with no mark (dialed before marks) → byte-identical" $? "rc=$RC out=$OUT"

h=$(new_home); CD=$(mk_call "$h"); store "$h" a "$(offer "$SID" $((NOW_MS + 10)))"
wait_on "$h" "$CD"
[[ $RC -eq 0 && "$(jq -r '.you_should_know[0].line' <<<"$OUT")" == "the migration order check will fail" \
   && "$(jq -r '.response' <<<"$OUT")" == "the answer" ]] && ! jq -e 'has("you_should_know_broken")' <<<"$OUT" >/dev/null
check "a new note is delivered as an additive you_should_know array" $? "rc=$RC out=$OUT"
[[ "$(wc -l < "$CD/you_should_know.jsonl" | tr -d ' ')" == 1 && "$(cat "$CD/you_should_know_since.txt")" == "$NOW_MS" ]] \
  && ! jq -e 'has("you_should_know")' "$CD/response.json" >/dev/null
check "the note is collected in you_should_know.jsonl; the seed and response.json are untouched" $? \
  "notes=$(cat "$CD/you_should_know.jsonl" 2>/dev/null) seed=$(cat "$CD/you_should_know_since.txt")"
wait_on "$h" "$CD"
[[ "$(jq -c '[.you_should_know[].line]' <<<"$OUT")" == '["the migration order check will fail"]' \
   && "$(wc -l < "$CD/you_should_know.jsonl" | tr -d ' ')" == 1 ]]
check "a re-run shows the collected note again, without collecting it twice" $? "out=$OUT"
store "$h" a "$(offer "$SID" $((NOW_MS + 20)) "a later note")"
wait_on "$h" "$CD"
[[ "$(jq -c '[.you_should_know[].line]' <<<"$OUT")" == '["the migration order check will fail","a later note"]' ]]
check "a later note on a re-run is shown with every earlier one" $? "out=$OUT"

# A waiter killed after reading but before printing: the store has since moved on
# to a newer note (it keeps only the latest), yet the first one is not lost.
h=$(new_home); CD=$(mk_call "$h"); store "$h" a "$(offer "$SID" $((NOW_MS + 10)) "first")"
source "$READER"; HOME="$h" ysk_relay "$CD" "$SID" >/dev/null
store "$h" a "$(offer "$SID" $((NOW_MS + 20)) "second")"
wait_on "$h" "$CD"
[[ "$(jq -c '[.you_should_know[].line]' <<<"$OUT")" == '["first","second"]' ]]
check "a note collected by an interrupted run is still shown later" $? "out=$OUT"

echo "concurrency:"
h=$(new_home); CD=$(mk_call "$h"); store "$h" a "$(offer "$SID" $((NOW_MS + 10)) "only one")"
pids=()
for i in 1 2 3 4 5 6; do (HOME="$h" ysk_relay "$CD" "$SID" > "$T/conc-$i.out") & pids+=($!); done
wait "${pids[@]}"
[[ "$(wc -l < "$CD/you_should_know.jsonl" | tr -d ' ')" == 1 && "$(jq -r '.line' "$CD/you_should_know.jsonl")" == "only one" ]]
check "six concurrent collectors → the note collected exactly once" $? "notes=$(cat "$CD/you_should_know.jsonl")"
[[ ! -e "$CD/you_should_know.lock" ]]; check "the lock is released" $?
h=$(new_home); CD=$(mk_call "$h"); store "$h" a "$(offer "$SID" $((NOW_MS + 30)) "late")"
printf '%s\n' "$(jq -nc --argjson at $((NOW_MS + 5)) '{tag:"Heads up", line:"earlier", explanation:"", shownAt:$at}')" > "$CD/you_should_know.jsonl"
mkdir "$CD/you_should_know.lock"
OUT=$(HOME="$h" HOTLINE_YSK_LOCK_TRIES=2 ysk_relay "$CD" "$SID")
[[ "$(jq -c '[.notes[].line]' <<<"$OUT")" == '["earlier"]' && "$(wc -l < "$CD/you_should_know.jsonl" | tr -d ' ')" == 1 ]]
check "a held lock → collection skipped this run, earlier notes still shown" $? "out=$OUT"
rmdir "$CD/you_should_know.lock"

h=$(new_home); CD=$(mk_call "$h"); store "$h" a "$(jq -nc --arg s "$SID" '{sessions:[{id:$s, view:{kind:"glowing"}}]}')"
wait_on "$h" "$CD"
[[ $RC -eq 0 && "$(jq -r '.you_should_know_broken' <<<"$OUT")" == "maybe the you-should-know relay is broken"* ]] \
  && ! jq -e 'has("you_should_know")' <<<"$OUT" >/dev/null
check "a broken store → you_should_know_broken, exit code unchanged" $? "rc=$RC out=$OUT"

h=$(new_home); CD=$(mk_call "$h"); echo codex > "$CD/agent_kind.txt"; store "$h" a "$(offer "$SID" $((NOW_MS + 10)))"
wait_on "$h" "$CD"; [[ "$OUT" == "$(jq -c . "$CD/response.json")" ]]
check "a Codex callee is never read" $? "out=$OUT"
h=$(new_home); CD=$(mk_call "$h"); echo box > "$CD/remote_target.txt"; store "$h" a "$(offer "$SID" $((NOW_MS + 10)))"
wait_on "$h" "$CD"; [[ "$OUT" == "$(jq -c . "$CD/response.json")" ]]
check "a remote callee is never read (its store is on another machine)" $? "out=$OUT"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
