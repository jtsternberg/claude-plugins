#!/usr/bin/env bash
# =============================================================================
# Transcript confirmation: prove a delivered payload actually reached a callee by
# finding its per-call nonce in the callee's own Claude Code transcript.
#
# SOURCE this, don't execute it.
#
# This is the ONE delivery proof that is transport-independent. A local claude
# session writes the same JSONL whether cmux, herdr or nothing at all owns its
# PTY, and the nonce is minted for a single delivery and travels nowhere else — so
# any occurrence of it in the callee's transcript proves the payload arrived.
#
# A PLAIN grep, deliberately, rather than a match on specific JSONL shapes. An
# idle REPL records the payload as a user turn; a busy one records it as a
# `queued_command` attachment with no user turn at all; a third shape
# (`queue-operation`) turned up live that no design had predicted. Every shape
# whitelist written against this has read a landed payload as lost and re-sent it.
#
# cmux-paste.sh carries the same two functions inline (its `TRANSCRIPTS` array and
# `confirmed_by_transcript`) and is deliberately NOT refactored onto them by the
# phase that added this file: that phase's hard constraint was that the cmux
# delivery path stay bit-identical. Adopt these there the next time cmux-paste.sh
# is touched for its own reasons, and delete the inline copies — two readers of one
# rule is how this repo lost time in the transcript parser, twice.
# =============================================================================

HOTLINE_TRANSCRIPT_CONFIRM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# hotline_transcript_candidates <cwd> <session-id> → one absolute path per line.
#
# BOTH SPELLINGS OF THE CWD, which is the whole reason this is a function and not
# a one-liner at each call site. Claude Code derives its project directory from
# the cwd it actually RESOLVED, so a callee under a symlinked path writes to the
# REALPATH encoding: a session in /tmp/x on macOS lands in
# ~/.claude/projects/-private-tmp-x, not -tmp-x. Deriving only from the path the
# caller happened to pass makes confirmation miss every time for such a callee,
# and miss SILENTLY.
#
# Emits nothing (exit 0) when either argument is empty — a caller that was never
# told the callee's cwd or session simply has no transcript to read.
hotline_transcript_candidates() {  # <cwd> <session-id>
  local cwd="$1" session="$2" spelling path seen
  [[ -z "$cwd" || -z "$session" ]] && return 0
  seen=""
  for spelling in "$cwd" "$(realpath "$cwd" 2>/dev/null || true)"; do
    [[ -z "$spelling" ]] && continue
    path=$(bash "$HOTLINE_TRANSCRIPT_CONFIRM_DIR/transcript-path.sh" \
             --cwd "$spelling" --session "$session" 2>/dev/null) || continue
    [[ -z "$path" ]] && continue
    case "$seen" in
      *"|$path|"*) continue ;;
    esac
    seen="$seen|$path|"
    printf '%s\n' "$path"
  done
  return 0
}

# hotline_confirm_nonce_in_transcripts <nonce> <tries> <sleep> <path>...
#   0 — the nonce is in one of the transcripts (the payload landed)
#   1 — it never appeared within the budget, or there was nothing to read
#
# Polled rather than checked once: the transcript flush is fast but not
# instantaneous, and a caller that reads it a single time reports a landed
# delivery as lost. Ten tries at 0.3s is generous enough for the flush and short
# enough that a genuinely lost payload is reported in seconds.
hotline_confirm_nonce_in_transcripts() {
  local nonce="$1" tries="$2" nap="$3"
  shift 3
  local i path
  [[ -z "$nonce" || $# -eq 0 ]] && return 1
  for ((i = 0; i < tries; i++)); do
    for path in "$@"; do
      [[ -s "$path" ]] && grep -qF "$nonce" "$path" 2>/dev/null && return 0
    done
    sleep "$nap"
  done
  return 1
}
