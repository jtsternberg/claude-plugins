#!/usr/bin/env bash
# =============================================================================
# The Claude Code config dirs hotline looks in for sessions and transcripts —
# the ONE definition of that list. send.py and the switchboard execute this file
# to read it; shell scripts source it.
#
# Lookup order: $CLAUDE_CONFIG_DIR (default ~/.claude), then each entry of
# $AGENT_CLAUDE_CONFIG_DIRS (colon-separated; session-tools reads the same var),
# or of $HOTLINE_CLAUDE_CONFIG_DIRS when the neutral var is unset. Duplicates are
# dropped by resolved path. A second account is opted in by naming its dir; never glob ~/.claude-*.
#
# Usage:
#   source claude-config-dirs.sh; hotline_claude_config_dirs   # one dir per line
#   bash claude-config-dirs.sh                                  # same, executed
# =============================================================================

hotline_claude_config_dirs() {
  local d key seen=$'\n'
  local -a extra=()
  IFS=':' read -r -a extra <<< "${AGENT_CLAUDE_CONFIG_DIRS-${HOTLINE_CLAUDE_CONFIG_DIRS:-}}"
  for d in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ${extra[@]+"${extra[@]}"}; do
    [[ -z "$d" ]] && continue
    # One dir reached by two spellings would otherwise refuse its own sessions
    # as ambiguous.
    key=$(cd -P "$d" 2>/dev/null && pwd -P) || key="${d%/}"
    [[ "$seen" == *$'\n'"$key"$'\n'* ]] && continue
    seen+="$key"$'\n'
    printf '%s\n' "$d"
  done
}

# hotline_claude_real_file <path> → the path with its directory symlinks resolved.
# A second account often symlinks projects/ to the first account's, so one
# transcript is reachable through two config dirs; comparing resolved paths is
# what keeps that from reading as two sessions.
hotline_claude_real_file() {
  local dir
  dir=$(cd -P "$(dirname "$1")" 2>/dev/null && pwd -P) || { printf '%s\n' "$1"; return; }
  printf '%s/%s\n' "$dir" "$(basename "$1")"
}

# hotline_claude_find_transcript <session-id> → the transcript path on stdout.
#   0 found · 1 in no config dir · 2 in more than one (ambiguous, named on stderr)
# Within one dir the first project match wins, as it always has; the ambiguity
# rule is about two config dirs holding two DIFFERENT files for one id.
hotline_claude_find_transcript() {
  local id="$1" d f real seen=$'\n'
  local -a hits=()
  [[ -z "$id" ]] && return 1
  while IFS= read -r d; do
    for f in "$d/projects"/*/"$id.jsonl"; do
      [[ -f "$f" ]] || continue
      real=$(hotline_claude_real_file "$f")
      [[ "$seen" != *$'\n'"$real"$'\n'* ]] && { seen+="$real"$'\n'; hits+=("$f"); }
      break
    done
  done < <(hotline_claude_config_dirs)
  case ${#hits[@]} in
    0) return 1 ;;
    1) printf '%s\n' "${hits[0]}" ;;
    *) printf 'ambiguous Claude transcripts for %s: %s\n' "$id" "${hits[*]}" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  hotline_claude_config_dirs
fi
