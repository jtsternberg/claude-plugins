#!/usr/bin/env bash
# =============================================================================
# Codex rollout: the response channel for a Codex callee.
#
# SOURCE this, don't execute it.
#
# A Codex callee writes no Claude transcript. What it does write is its rollout —
# ${CODEX_HOME:-~/.codex}/sessions/YYYY/MM/DD/rollout-<ts>-<thread-id>.jsonl — one
# JSON row per event, flushed as the turn runs. That is the structured source of
# truth hotline's Claude reader already depends on, in a different shape: the typed
# prompt (nonce included) is a `response_item` user message, every reply is a
# `response_item` assistant message, and the end of a turn is an `event_msg`
# `task_complete`. So the protocol reader is NOT forked. `codex_rollout_normalize`
# maps those rows onto the Claude rows transcript-extract.sh reads, and the nonce
# correlation, STATUS bracketing, preemption and BLOCKED logic run unchanged.
#
# WHY NOT `herdr agent read`. It is the rendered screen: wrapped, chrome-laden, and
# bounded by what is still on it. The rollout is the record, it survives the pane,
# and it names the nonce in event DATA rather than pixels — the same reason the
# Claude path stopped screen-scraping.
#
# WHY THE ROLLOUT IS FOUND BY NONCE. Codex cannot be told its thread id up front the
# way `claude --session-id` can, and herdr only reports it (`agent_session`) after
# the first turn. The per-call nonce is in the first user message and nowhere else,
# so the one rollout that contains it IS this call's — no cwd or clock heuristics.
# Verified live on codex-cli 0.165.0 / herdr 0.9.5.
# =============================================================================

codex_sessions_root() {
  local selected="${HOTLINE_CODEX_HOME:-${CODEX_HOME:-$HOME/.codex}}"
  # A waiter may run outside its dialer's environment, even under another account.
  # Persisted call identity takes precedence over every ambient default.
  if [[ -n "${CALL_DIR:-}" && -s "$CALL_DIR/codex_home.txt" ]]; then
    selected=$(cat "$CALL_DIR/codex_home.txt") || return 1
  fi
  printf '%s/sessions' "$selected"
}

# codex_find_rollout <nonce> [max-age-minutes] [remote-tries] [remote-sleep]
# → the rollout path on stdout, exit 0;
# exit 1 when none carries the nonce yet. Only recent files are scanned: a rollout is
# appended while its session lives, so its mtime is fresh by the time we look, and
# the sessions tree accumulates months of history.
# The remote confirmation loop stays in one hop so every poll shares one budget.
codex_find_rollout() {
  local nonce="$1" age="${2:-240}" root hit
  [[ -n "$nonce" ]] || return 1
  if declare -F hotline_remote_active >/dev/null && hotline_remote_active; then
    local cmd tries="${3:-1}" nap="${4:-0}" saved="${HOTLINE_REMOTE_HOP_BUDGET:-}" rc
    cmd='root="$HOME/.codex/sessions"; i=0; while [ "$i" -lt '
    cmd+="$(hotline_remote_shquote "$tries") ]; do hit=\$(find \"\$root\" -type f -name 'rollout-*.jsonl' -mmin $(hotline_remote_shquote "-$age") -exec grep -lF -- $(hotline_remote_shquote "CALL_ID: $nonce") {} + 2>/dev/null | head -1);"
    cmd+=' if [ -n "$hit" ]; then printf %s "$hit"; exit 0; fi; i=$((i+1));'
    cmd+=" sleep $(hotline_remote_shquote "$nap"); done; exit 1"
    HOTLINE_REMOTE_HOP_BUDGET=$(awk -v t="$tries" -v s="$nap" 'BEGIN{printf "%d", (t*s)+20}')
    hotline_remote_run "$cmd"; rc=$?
    HOTLINE_REMOTE_HOP_BUDGET="$saved"
    [[ $rc -eq 0 && -n "$HOTLINE_REMOTE_OUT" ]] || return 1
    printf '%s' "$HOTLINE_REMOTE_OUT"
    return 0
  fi
  root=$(codex_sessions_root)
  [[ -d "$root" ]] || return 1
  hit=$(find "$root" -type f -name 'rollout-*.jsonl' -mmin "-$age" -print0 2>/dev/null \
        | xargs -0 grep -l -F "CALL_ID: $nonce" 2>/dev/null | head -1)
  [[ -n "$hit" ]] || return 1
  printf '%s' "$hit"
}

# Thread adoption has no age limit: a resumed conversation can have been idle for months.
codex_find_thread() {
  local id="$1" root hit
  [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
  if declare -F hotline_remote_active >/dev/null && hotline_remote_active; then
    hotline_remote_run "find \"\$HOME/.codex/sessions\" -type f -name $(hotline_remote_shquote "rollout-*-$id.jsonl") -print 2>/dev/null | head -1" || return 1
    hit="$HOTLINE_REMOTE_OUT"
  else
    root=$(codex_sessions_root)
    hit=$(find "$root" -type f -name "rollout-*-$id.jsonl" -print 2>/dev/null | head -1)
  fi
  [[ -n "$hit" ]] || return 1
  printf '%s' "$hit"
}

codex_thread_cwd() {
  local file="$1" data
  if declare -F hotline_remote_active >/dev/null && hotline_remote_active; then
    hotline_remote_run "head -1 $(hotline_remote_shquote "$file")" || return 1
    data="$HOTLINE_REMOTE_OUT"
  else
    data=$(head -1 "$file") || return 1
  fi
  jq -er 'select(.type == "session_meta") | .payload.cwd | select(type == "string" and length > 0)' <<<"$data"
}

# codex_thread_id_of <rollout-path> → the thread id the filename ends in.
codex_thread_id_of() {
  local base="${1##*/}"; base="${base%.jsonl}"
  [[ "$base" =~ ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$ ]] \
    && printf '%s' "${BASH_REMATCH[1]}"
}

# codex_rollout_normalize <rollout> <out> — write the Claude-shaped rows
# transcript-extract.sh reads. Atomic (temp + mv), so a reader never sees half a file.
#
# The mapping, and what each half of it is for:
#   user message      → {type:"user", message:{content:<text>}}. Codex injects its own
#                       context as user messages too (AGENTS.md, environment_context,
#                       and the <skill> body a `$plugin:skill` mention loads — right
#                       AFTER our prompt, verified live);
#                       those are dropped, or the extractor would read the next turn's
#                       context block as a human reassigning the callee.
#   assistant message → {type:"assistant", message:{id, content:[text], stop_reason}}.
#                       stop_reason is end_turn on the turn's LAST assistant message —
#                       the one before its task_complete, or phase:"final_answer" —
#                       which is what lets a BLOCKED ending resolve.
#   turn_aborted      → the user record Claude writes for an interrupt, so preemption
#                       reads a Codex interrupt the way it reads Claude's.
#   error event       → an isApiErrorMessage assistant row, so a turn that died on an
#                       API error is reported STALLED rather than waited out.
# Everything else (tool calls, reasoning, token counts) has no text the protocol reads.
codex_rollout_normalize() {
  local in="$1" out="$2" tmp
  [[ -r "$in" ]] || return 1
  tmp="$out.tmp.$$"
  jq -R -n -c '
    [inputs | fromjson? | select(type == "object")] as $rows
    | ($rows | map(select(.type == "session_meta") | .payload.id // .payload.session_id) | first // "") as $sid
    | [ $rows | to_entries[] | .key as $i | .value as $r
        | if $r.type == "response_item" and ($r.payload.type // "") == "message"
             and ($r.payload.role == "user" or $r.payload.role == "assistant") then
            {i: $i, role: $r.payload.role, phase: ($r.payload.phase // null),
             id: ($r.payload.id // ("codex-row-" + ($i | tostring))),
             text: ([$r.payload.content[]? | (.text // empty)] | join("\n"))}
          elif $r.type == "event_msg" and ($r.payload.type // "") == "task_complete" then
            {i: $i, role: "turn_end"}
          elif $r.type == "event_msg" and ($r.payload.type // "") == "turn_aborted" then
            {i: $i, role: "abort"}
          elif $r.type == "event_msg" and (($r.payload.type // "") | test("^(error|stream_error)$")) then
            {i: $i, role: "error", text: ($r.payload.message // "API Error")}
          else empty end ] as $ev
    # The index (into $ev) of each turn-ending assistant message: the last assistant
    # before every turn_end.
    | ([ range(0; $ev | length) | select($ev[.].role == "turn_end") as $t
         | ([ range(0; $t) | select($ev[.].role == "assistant") ] | last) ]
       | map(select(. != null))) as $enders
    | range(0; $ev | length) as $k | $ev[$k]
    | if .role == "user" then
        select((.text | test("^\\s*(# AGENTS\\.md instructions|<environment_context>|<user_instructions>|<INSTRUCTIONS>|<skill>)")) | not)
        | {type: "user", sessionId: $sid, message: {content: .text}}
      elif .role == "assistant" then
        {type: "assistant", sessionId: $sid,
         message: {id: .id, content: [{type: "text", text: .text}],
                   stop_reason: (if (.phase == "final_answer") or ($enders | index($k)) != null
                                 then "end_turn" else null end)}}
      elif .role == "abort" then
        {type: "user", sessionId: $sid, message: {content: "[Request interrupted by user]"}}
      elif .role == "error" then
        {type: "assistant", sessionId: $sid, isApiErrorMessage: true,
         message: {id: ("codex-error-" + ($k | tostring)), content: [{type: "text", text: .text}], stop_reason: null}}
      else empty end
  ' "$in" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$out"
}

# codex_startup_dialog <screen-text> → the dialog's name on stdout, exit 0, when Codex
# is sitting on a startup gate; exit 1 otherwise.
#
# herdr reports the FOLDER-TRUST gate as `blocked` (so `agent start` refuses it), but
# it reports the HOOKS-REVIEW gate as idle + interactive_ready — the same blind spot it
# has for Claude's trust dialog. A work order typed into either dialog answers it
# instead of becoming a turn. Verified live on codex-cli 0.165.0 / herdr 0.9.5.
codex_startup_dialog() {
  local flat
  flat=$(tr -s '[:space:]' ' ' <<<"$1")
  [[ "$flat" == *"Trust this folder?"* ]]  && { printf 'folder-trust'; return 0; }
  [[ "$flat" == *"Hooks need review"* ]]   && { printf 'hooks-review'; return 0; }
  [[ "$flat" == *"Update available"* && "$flat" == *"Update now"* ]] && { printf 'update-prompt'; return 0; }
  return 1
}

# codex_composer_ready <screen-text> → exit 0 when Codex's input composer is drawn.
#
# A POSITIVE signal, because the negative one races: herdr calls a codex agent ready
# BEFORE its hooks-review dialog draws (seconds later, verified live), so "no dialog
# on screen yet" proved nothing and the opening Enter answered the dialog. The
# composer's footer is drawn only once every startup gate is cleared.
codex_composer_ready() {
  local flat
  flat=$(tr -s '[:space:]' ' ' <<<"$1")
  [[ "$flat" == *"? for shortcuts"* || "$flat" == *"Ask Codex to do anything"* \
     || "$flat" == *"context left"* ]]
}

# codex_startup_dialog_recovery <dialog> <cwd> → what the human should do, on stdout.
codex_startup_dialog_recovery() {
  case "$1" in
    folder-trust) printf "Codex's FOLDER-TRUST dialog is up for %s — run \`codex\` in that directory once and choose 'Trust and continue', then re-dial." "${2:-the callee cwd}" ;;
    hooks-review) printf "Codex's HOOKS-REVIEW dialog is up (hooks are new or changed) — run \`codex\` once, review or trust the hooks, then re-dial. hotline will not answer a trust decision for you." ;;
    update-prompt) printf "Codex's UPDATE prompt is up — hotline launches with \`-c check_for_update_on_startup=false\`, so something else re-enabled it; run \`codex\` once and pick Skip, then re-dial." ;;
    *) printf 'Codex is on a startup dialog; attach to the pane and clear it, then re-dial.' ;;
  esac
}
