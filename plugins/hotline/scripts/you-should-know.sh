#!/usr/bin/env bash
# =============================================================================
# You Should Know: read the notes Claude Code's built-in "You should know" mod
# (cc-plugin-you-should-know@builtin) showed above a callee's prompt.
#
# A hotline callee's terminal has no human watching it, so a note the mod shows
# there is never read unless something relays it. The waiter does
# (wait-for-response.sh → ysk_relay below), collecting them in
# call_dir/you_should_know.jsonl; this file is the one reader.
#
# Run as a CLI — prints ONE JSON line, always exits 0 once arguments parse:
#   you-should-know.sh --session <id> [--config-dir <dir>] [--since <epoch-ms>]
#                      [--transcript <jsonl>] [--headless]
#   → {"notes":[{"tag","line","explanation","shownAt"}],"broken":null|"<reason>"}
#
# Source it for the call-dir glue: ysk_mark_seed (launchers) and ysk_relay (waiter).
#
# What the mod keeps, in <plugins dir>/store/cc-plugin-you-should-know_builtin-<hash>.json
# (the hash changes across Claude Code releases, hence the glob):
#   {known, seen, looksToSkip, typedPastInARow,
#    sessions:[{id, askedTurn?, offeredTurn?, tag?, view?}]}
# Only the LATEST view per session survives; `view.kind == "offer"` is an unread
# note ({line, explanation, shownAt}). The other known kinds are UI states after a
# human interacted with the note — nothing to relay, but not drift either.
#
# The mod checks from a turn.step hook at a turn's step index 6, 12, … and stamps
# askedTurn on the session's entry each time, so a session with one turn of
# HOTLINE_YSK_CANARY_STEPS (default 7) steps and no entry means the reader no
# longer understands the store — the canary. It only runs when a surface is
# attached, so a headless (`claude -p`) callee legitimately has no entry and no
# store file, and both checks are skipped for it.
#
# The plugins dir is probed at <config-dir>/plugins/store, then
# ~/.claude/plugins/store: whether Claude Code puts plugins under
# CLAUDE_CONFIG_DIR was not settled from the bundle.
# =============================================================================

YSK_KNOWN_KINDS='["offer","asked","making","ready","explaining","explained","off","failed"]'
YSK_MARK_FILE=you_should_know_since.txt

# A call dir's seed: notes shown at or before it are not relayed. Written once at
# dial time and never moved, so a resumed or adopted session's older notes never
# reach this caller.
ysk_mark_seed() { # <call-dir>
  [[ -d "${1:-}" && ! -e "$1/$YSK_MARK_FILE" ]] || return 0
  printf '%s000\n' "$(date +%s)" > "$1/$YSK_MARK_FILE" 2>/dev/null || true
}

# Collect-then-show. New notes are appended to call_dir/you_should_know.jsonl
# BEFORE anything is printed, and every run prints the whole collected list: a
# waiter killed between reading and emitting loses nothing, at the price of a
# re-run showing a note again. The append is read-dedupe-write, so it runs under a
# per-call mkdir lock; a run that cannot get it within HOTLINE_YSK_LOCK_TRIES
# tenths of a second skips collecting rather than holding up the waiter.
YSK_NOTES_FILE=you_should_know.jsonl

_ysk_lock() { # <lock-dir> → 0 when held
  local l="$1" i m tries="${HOTLINE_YSK_LOCK_TRIES:-50}"
  for ((i = 0; i < tries; i++)); do
    mkdir "$l" 2>/dev/null && return 0
    # A holder that died leaves the dir behind; past 60s it is not a live holder.
    m=$(stat -c %Y "$l" 2>/dev/null || stat -f %m "$l" 2>/dev/null)
    [[ "$m" =~ ^[0-9]+$ ]] && (( $(date +%s) - m > 60 )) && rmdir "$l" 2>/dev/null && continue
    sleep 0.1
  done
  return 1
}

# Prints {"notes":[every note collected for this call],"broken":…}; prints
# nothing for a call this does not apply to (Codex, remote, or a call dir dialed
# before seeds existed). Never fails its caller.
ysk_relay() { # <call-dir> <callee-session-id>
  local d="$1" sid="$2" since kind cwd tp out args=() f lock broken
  [[ -n "$sid" && -s "$d/$YSK_MARK_FILE" ]] || return 0
  kind=$(tr -d "[:space:]" 2>/dev/null < "$d/agent_kind.txt")
  [[ "${kind:-claude}" == claude && ! -s "$d/remote_target.txt" ]] || return 0
  since=$(tr -dc '0-9' < "$d/$YSK_MARK_FILE")
  [[ -n "$since" ]] || return 0
  args=(--session "$sid" --since "$since")
  [[ -s "$d/claude_config_dir.txt" ]] && args+=(--config-dir "$(cat "$d/claude_config_dir.txt")")
  [[ "$(tr -d "[:space:]" 2>/dev/null < "$d/transport.txt")" == headless ]] && args+=(--headless)
  cwd=$(cat "$d/cwd.txt" 2>/dev/null)
  if [[ -n "$cwd" ]]; then
    tp=$(bash "$(dirname "${BASH_SOURCE[0]}")/transcript-path.sh" --cwd "$cwd" --session "$sid" 2>/dev/null) \
      && args+=(--transcript "$tp")
  fi
  out=$(bash "${BASH_SOURCE[0]}" "${args[@]}" 2>/dev/null) || out=""
  jq -e 'type == "object" and (.notes | type == "array")' <<<"$out" >/dev/null 2>&1 || out='{"notes":[],"broken":null}'
  f="$d/$YSK_NOTES_FILE" lock="$d/you_should_know.lock"
  if jq -e '.notes | length > 0' <<<"$out" >/dev/null && _ysk_lock "$lock"; then
    jq -c --slurpfile have <(cat "$f" 2>/dev/null) '
      ($have | map("\(.shownAt)\u0000\(.line)")) as $keys
      | .notes[] | select(("\(.shownAt)\u0000\(.line)") as $k | $keys | index($k) | not)' <<<"$out" >> "$f" 2>/dev/null
    rmdir "$lock" 2>/dev/null
  fi
  broken=$(jq -c '.broken' <<<"$out")
  if [[ -s "$f" ]] && jq -sc --argjson b "$broken" '{notes: ., broken: $b}' "$f" 2>/dev/null; then :
  else jq -nc --argjson b "$broken" '{notes: [], broken: $b}'
  fi
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

# ----------------------------------------------------------------------------- CLI
set -uo pipefail
SESSION="" CONFIG_DIR="" SINCE=0 TRANSCRIPT="" HEADLESS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session)    SESSION="${2-}";    shift 2 ;;
    --config-dir) CONFIG_DIR="${2-}"; shift 2 ;;
    --since)      SINCE="${2-}";      shift 2 ;;
    --transcript) TRANSCRIPT="${2-}"; shift 2 ;;
    --headless)   HEADLESS=true;      shift ;;
    *) echo "you-should-know: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$SESSION" ]] || { echo "you-should-know: --session is required" >&2; exit 2; }
[[ "$SINCE" =~ ^[0-9]+$ ]] || { echo "you-should-know: --since must be epoch ms" >&2; exit 2; }
CANARY_STEPS="${HOTLINE_YSK_CANARY_STEPS:-7}"
[[ "$CANARY_STEPS" =~ ^[0-9]+$ ]] || CANARY_STEPS=7

quiet()  { printf '{"notes":[],"broken":null}\n'; exit 0; }
broken() { jq -nc --arg r "maybe the you-should-know relay is broken: $1" '{notes:[], broken:$r}'; exit 0; }

# The most main-agent steps any single turn of the callee took: distinct assistant
# message ids (one streamed message spans several rows) between real user prompts
# (a tool_result-only user row continues the turn), sidechains excluded. Per turn
# because the mod checks only at a turn's step index 6, 12, … (the index resets
# each turn), so many short turns never get checked at all.
main_steps() {
  [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || { echo 0; return; }
  grep -F -e '"type":"assistant"' -e '"type":"user"' "$TRANSCRIPT" 2>/dev/null \
    | jq -nR 'reduce (inputs | fromjson? | select(type == "object" and (.isSidechain | not))) as $r
        ({cur: {}, best: 0};
         if $r.type == "user" then
           (($r.message.content // "") as $c
            | if ($c | type) == "array" and ($c | length) > 0 and all($c[]; .type == "tool_result")
              then . else .cur = {} end)
         elif $r.type == "assistant" then
           .cur[($r.message.id // $r.uuid // "?") | tostring] = true
           | .best = ([.best, (.cur | length)] | max)
         else . end) | .best' 2>/dev/null || echo 0
}
past_canary() { (( $(main_steps) >= CANARY_STEPS )); }

ACCOUNT_DIR="${CONFIG_DIR:-$HOME/.claude}"
# An explicit false is the only "off": a builtin's absent key is read as its
# default, which is on.
[[ "$(jq -r '.enabledPlugins["cc-plugin-you-should-know@builtin"] | tostring' "$ACCOUNT_DIR/settings.json" 2>/dev/null)" == false ]] && quiet

STORE_FILES=()
for dir in ${CONFIG_DIR:+"$CONFIG_DIR/plugins/store"} "$HOME/.claude/plugins/store"; do
  for f in "$dir"/cc-plugin-you-should-know_builtin-*.json; do
    [[ -f "$f" ]] && STORE_FILES+=("$f")
  done
  (( ${#STORE_FILES[@]} )) && break
done

if (( ${#STORE_FILES[@]} == 0 )); then
  $HEADLESS && quiet
  # The store is shared by every session on the account, so it is absent only
  # until the mod's first check anywhere; give this callee that long.
  past_canary && broken "no store file (cc-plugin-you-should-know_builtin-*.json) under ${CONFIG_DIR:+$CONFIG_DIR/plugins/store or }$HOME/.claude/plugins/store"
  quiet
fi

# Newest by mtime first; an older one is a previous release's leftover. Only when
# none of them parse is the store unreadable.
STORE=""
while IFS= read -r f; do
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 && { STORE="$f"; break; }
done < <(ls -t "${STORE_FILES[@]}" 2>/dev/null)
[[ -n "$STORE" ]] || broken "store file is not parseable JSON: ${STORE_FILES[*]}"

jq -e '.sessions | type == "array"' "$STORE" >/dev/null 2>&1 \
  || broken "store .sessions is not an array: $STORE"

ENTRY=$(jq -c --arg s "$SESSION" '[.sessions[] | select(type == "object" and .id == $s)] | last // empty' "$STORE")
if [[ -z "$ENTRY" ]]; then
  $HEADLESS && quiet
  past_canary && broken "callee session $SESSION had a turn of $(main_steps) main-agent steps but has no entry in $STORE"
  quiet
fi

jq -e 'has("view") and .view != null' <<<"$ENTRY" >/dev/null || quiet
KIND=$(jq -r '.view.kind | if type == "string" then . else "<\(type)>" end' <<<"$ENTRY")
jq -e --arg k "$KIND" 'index($k) != null' <<<"$YSK_KNOWN_KINDS" >/dev/null \
  || broken "unknown view kind '$KIND' for session $SESSION in $STORE"
[[ "$KIND" == offer ]] || quiet
jq -e '(.view.line | type == "string") and (.view.shownAt | type == "number")' <<<"$ENTRY" >/dev/null \
  || broken "offer view for session $SESSION lacks line/shownAt in $STORE"

jq -c --argjson since "$SINCE" '
  {notes: (if .view.shownAt > $since
           then [{tag: (.tag // "You should know"), line: .view.line,
                  explanation: (.view.explanation // ""), shownAt: .view.shownAt}]
           else [] end),
   broken: null}' <<<"$ENTRY"
