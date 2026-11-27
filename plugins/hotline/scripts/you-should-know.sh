#!/usr/bin/env bash
# =============================================================================
# You Should Know: read the notes Claude Code's built-in "You should know" mod
# (cc-plugin-you-should-know@builtin) showed above a callee's prompt.
#
# A hotline callee's terminal has no human watching it, so a note the mod shows
# there is never read unless something relays it. The waiter does
# (wait-for-response.sh → ysk_relay below); this file is the one reader.
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
# The mod checks from a turn.step hook every few main-agent steps and stamps
# askedTurn on the session's entry each time, so a session that has taken
# HOTLINE_YSK_CANARY_STEPS (default 6) steps with no entry means the reader no
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

# A call dir's mark: notes shown at or before it are not relayed. Seeded at dial
# time, so a resumed or adopted session's older notes never reach this caller.
ysk_mark_seed() { # <call-dir>
  [[ -d "${1:-}" && ! -e "$1/$YSK_MARK_FILE" ]] || return 0
  printf '%s000\n' "$(date +%s)" > "$1/$YSK_MARK_FILE" 2>/dev/null || true
}

# Prints the reader's JSON for the call dir's callee, advancing the mark past any
# note it returns; prints nothing for a call this does not apply to (Codex, remote,
# or a call dir dialed before marks existed). Never fails its caller.
ysk_relay() { # <call-dir> <callee-session-id>
  local d="$1" sid="$2" since kind cwd tp out newest args=()
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
  out=$(bash "${BASH_SOURCE[0]}" "${args[@]}" 2>/dev/null) || return 0
  jq -e 'type == "object" and (.notes | type == "array")' <<<"$out" >/dev/null 2>&1 || return 0
  newest=$(jq -r '[.notes[].shownAt] | max // empty' <<<"$out")
  # max(old,new) through a rename, so two waiters on one call never move it back.
  if [[ -n "$newest" ]] && (( newest > since )); then
    printf '%s\n' "$newest" > "$d/$YSK_MARK_FILE.tmp.$$" 2>/dev/null \
      && mv -f "$d/$YSK_MARK_FILE.tmp.$$" "$d/$YSK_MARK_FILE" 2>/dev/null
    rm -f "$d/$YSK_MARK_FILE.tmp.$$" 2>/dev/null
  fi
  printf '%s\n' "$out"
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
CANARY_STEPS="${HOTLINE_YSK_CANARY_STEPS:-6}"
[[ "$CANARY_STEPS" =~ ^[0-9]+$ ]] || CANARY_STEPS=6

quiet()  { printf '{"notes":[],"broken":null}\n'; exit 0; }
broken() { jq -nc --arg r "maybe the you-should-know relay is broken: $1" '{notes:[], broken:$r}'; exit 0; }

# Main-agent steps the callee has taken: distinct assistant message ids outside
# sidechains (one streamed message can span several rows).
main_steps() {
  [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || { echo 0; return; }
  grep -F '"type":"assistant"' "$TRANSCRIPT" 2>/dev/null \
    | jq -R 'fromjson? | select(.type == "assistant" and (.isSidechain | not)) | .message.id // .uuid' 2>/dev/null \
    | sort -u | wc -l | tr -d ' '
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
  past_canary && broken "callee session $SESSION has taken $(main_steps) main-agent steps but has no entry in $STORE"
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
