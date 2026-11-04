#!/usr/bin/env bash
# Explicit process-account selection. Tool shell policy is not authentication:
# herdr's server launches Codex, so the pane must receive CODEX_HOME at creation.
# No credentials are inspected. Unset leaves every existing launch untouched.
codex_home_validate() { # <agent> <transport> <remote> <resume> [launch|reuse]
  CODEX_HOME_ERR=""
  [[ ${HOTLINE_CODEX_HOME+x} ]] || return 0
  if [[ "$1" != codex || "$2" != herdr || -n "$3" || -n "$4" \
        || ( "${5:-launch}" == launch && "${HOTLINE_HERDR_PLACEMENT:-split}" != tab && "${HOTLINE_HERDR_PLACEMENT:-split}" != workspace ) ]]; then
    CODEX_HOME_ERR='HOTLINE_CODEX_HOME requires local Codex herdr: a fresh tab/workspace or verified same-home cached continuation; remote and explicit resume are unsupported'
    return 1
  fi
  if [[ "$HOTLINE_CODEX_HOME" != /* || "$HOTLINE_CODEX_HOME" == *$'\n'* || "$HOTLINE_CODEX_HOME" == *$'\r'* \
        || ! -d "$HOTLINE_CODEX_HOME" || ! -r "$HOTLINE_CODEX_HOME" || ! -w "$HOTLINE_CODEX_HOME" || ! -x "$HOTLINE_CODEX_HOME" ]]; then
    CODEX_HOME_ERR='HOTLINE_CODEX_HOME must name an absolute, readable, writable directory (no line breaks)'
    return 1
  fi
  HOTLINE_CODEX_HOME=$(cd "$HOTLINE_CODEX_HOME" && pwd -P) || return 1
  export HOTLINE_CODEX_HOME
}

# Validate the launch record before touching a cached process. The cache also
# retains codex_home, so a swept/missing call directory cannot erase its pin.
codex_home_reuse_validate() { # <previous-call-dir> <agent-name> <thread-id> <cwd>
  local previous="$1" agent="$2" thread="$3" cwd="$4" stored pinned requested=""
  CODEX_HOME_ERR='Codex account home continuation requires intact local launch metadata; use --fresh with an explicit home to start a new call'
  [[ -z "${HOTLINE_HERDR_REMOTE:-}" && -d "$previous" ]] || return 1
  local field
  for field in codex_home codex_rollout herdr_agent herdr_pane session_id cwd agent_kind transport; do
    [[ -s "$previous/$field.txt" ]] || return 1
  done
  [[ "$(cat "$previous/agent_kind.txt")" == codex && "$(cat "$previous/transport.txt")" == herdr \
     && ! -s "$previous/remote_target.txt" && "$(cat "$previous/herdr_agent.txt")" == "$agent" \
     && "$(cat "$previous/session_id.txt")" == "$thread" && "$(cat "$previous/cwd.txt")" == "$cwd" ]] || return 1
  if [[ ${HOTLINE_CODEX_HOME+x} ]]; then
    codex_home_validate codex herdr "" "" reuse || return 1
    requested="$HOTLINE_CODEX_HOME"
  fi
  stored=$(cat "$previous/codex_home.txt") || return 1
  CODEX_HOME_ERR='Cached Codex account home is missing or inaccessible; no input was delivered'
  pinned=$(HOTLINE_CODEX_HOME="$stored"; codex_home_validate codex herdr "" "" reuse && printf '%s' "$HOTLINE_CODEX_HOME") || return 1
  CODEX_HOME_ERR='Codex account home mismatch: the requested home differs from the cached process home; no input was delivered'
  [[ -z "$requested" || "$requested" == "$pinned" ]] || return 1
  CODEX_PINNED_ROLLOUT=$(cat "$previous/codex_rollout.txt") || return 1
  CODEX_HOME_ERR='Codex account home continuation cannot verify its pinned rollout/thread; no input was delivered'
  [[ "$CODEX_PINNED_ROLLOUT" == "$pinned/sessions/"* && -f "$CODEX_PINNED_ROLLOUT" && ! -L "$CODEX_PINNED_ROLLOUT" ]] || return 1
  local physical
  physical="$(cd "$(dirname "$CODEX_PINNED_ROLLOUT")" && pwd -P)/$(basename "$CODEX_PINNED_ROLLOUT")" || return 1
  [[ "$physical" == "$pinned/sessions/"* && "$physical" == *"-$thread.jsonl" ]] || return 1
  head -1 "$physical" | jq -e --arg id "$thread" 'select(.type == "session_meta") | (.payload.id // .payload.session_id) == $id' >/dev/null || return 1
  CODEX_PINNED_PANE=$(cat "$previous/herdr_pane.txt") || return 1
  export HOTLINE_CODEX_HOME="$pinned"
  CODEX_HOME_ERR=""
}
