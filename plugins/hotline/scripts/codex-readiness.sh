#!/usr/bin/env bash
# Read-only startup observation. Never retries start or answers a gate. A current
# composer and live ready state must agree twice; stale words alone prove no gate.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/codex-rollout.sh"

codex_readiness_now() { date +%s; }
codex_readiness_pause() { sleep "$1"; }

codex_gate_choices_present() {
  [[ "$1" =~ Trust\ and\ continue|Cancel\ and\ exit|Review\ hooks|Enter\ to\ confirm|Update\ now|Yes,\ I\ trust|No,\ exit ]]
}

codex_current_startup_dialog() {
  local frame="$1" dialog
  dialog=$(codex_startup_dialog "$frame") || return 1
  if codex_composer_ready "$frame"; then
    # A complete choice UI remains a refusal even if its background composer is
    # visible. Only an isolated old header ABOVE the current composer is stale.
    if ! codex_gate_choices_present "$frame"; then
      if awk '
        /Trust this folder\?|Hooks need review|Update available/ {gate=NR}
        /Ask Codex to do anything|\? for shortcuts|context left/ {composer=NR}
        END {exit !(composer>gate)}' <<<"$frame"; then
        return 1
      fi
    fi
  fi
  printf '%s' "$dialog"
}

# <agent> <pane-or-empty> <cwd> <seconds> <max-probes> <poll-seconds>
# CODEX_READY_AGENT is the successful live snapshot; CODEX_READINESS_ERR explains
# a refusal. Both the wall clock and probe cap bound every outcome.
codex_wait_composer() {
  local agent="$1" pane="$2" cwd="$3" budget="$4" tries="$5" nap="$6"
  local deadline remaining bounded_nap probe=0 ready_reads=0 dialog_reads=0 last_dialog="" live frame dialog status ready candidate
  CODEX_READY_AGENT=""
  CODEX_READINESS_ERR='Codex readiness budget must be numeric and bounded'
  [[ "$budget" =~ ^[0-9]+$ && "$tries" =~ ^[1-9][0-9]*$ && "$nap" =~ ^[0-9]*[.]?[0-9]+$ ]] || return 1
  deadline=$(( $(codex_readiness_now) + budget ))
  dialog=""
  while [[ $probe -lt $tries ]]; do
    probe=$((probe+1)); live=""; frame=""; dialog=""
    if herdr_cli agent get "$agent"; then
      live="$HERDR_CLI_OUT"
      candidate=$(jq -r '.result.agent.pane_id // empty' <<<"$live" 2>/dev/null)
      [[ -n "$pane" ]] || pane="$candidate"
      if ! jq -e --arg a "$agent" --arg p "$pane" \
        '.result.agent | .name == $a and .agent == "codex" and .pane_id == $p' <<<"$live" >/dev/null 2>&1; then
        CODEX_READINESS_ERR='Codex startup agent kind/name/pane does not match its launch; nothing was submitted'
        return 1
      fi
      herdr_agent_screen "$agent" visible
      frame="$HERDR_AGENT_SCREEN"
    elif [[ -n "$pane" ]] && herdr_cli pane read "$pane" --source visible; then
      frame="$HERDR_CLI_OUT"
    fi
    [[ -z "$frame" ]] || dialog=$(codex_current_startup_dialog "$frame") || dialog=""
    if [[ -n "$dialog" && "$dialog" == "$last_dialog" ]]; then
      dialog_reads=$((dialog_reads+1))
    elif [[ -n "$dialog" ]]; then
      dialog_reads=1
    else
      dialog_reads=0
    fi
    last_dialog="$dialog"
    status=$(jq -r '.result.agent.agent_status // empty' <<<"$live" 2>/dev/null)
    ready=$(jq -r '.result.agent.interactive_ready // false' <<<"$live" 2>/dev/null)
    if [[ -n "$live" && "$ready" == true && "$status" != blocked && "$status" != unknown \
          && -n "$status" && -z "$dialog" ]] && codex_composer_ready "$frame"; then
      ready_reads=$((ready_reads+1))
      if [[ $ready_reads -ge 2 && $(codex_readiness_now) -le $deadline ]]; then
        CODEX_READY_AGENT="$live"
        CODEX_READINESS_ERR=""
        return 0
      fi
    else
      ready_reads=0
    fi
    [[ $(codex_readiness_now) -lt $deadline && $probe -lt $tries ]] || break
    remaining=$(( deadline - $(codex_readiness_now) ))
    [[ $remaining -gt 0 ]] || break
    bounded_nap=$(awk -v n="$nap" -v r="$remaining" 'BEGIN{if(n>1)n=1; if(n>r)n=r; printf "%g",n}')
    codex_readiness_pause "$bounded_nap"
  done
  if [[ -n "$dialog" && $dialog_reads -ge 2 ]] && codex_gate_choices_present "$frame"; then
    CODEX_READINESS_ERR="$(codex_startup_dialog_recovery "$dialog" "$cwd") The current startup gate persisted through the bounded readiness observations. Nothing was submitted."
  else
    CODEX_READINESS_ERR="Codex never drew its input composer with a matching ready agent within the bounded readiness budget; current startup evidence is unresolved. Inspect pane ${pane:-unknown}; nothing was submitted."
  fi
  return 1
}
