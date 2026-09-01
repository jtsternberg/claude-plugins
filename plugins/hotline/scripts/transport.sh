#!/usr/bin/env bash
# =============================================================================
# The call dir's transport signal: which backend owns this call.
#
# SOURCE this, don't execute it. Both waiters read transport.txt and must never
# disagree about what counts as a backend name, and Phase 1 gives both of them a
# herdr branch — so the judgement has two callers before it has its second value.
#
#   skills/dial/scripts/wait-for-session.sh   — which host do I boot-wait on?
#   skills/dial/scripts/wait-for-response.sh  — which host do I poll for STATUS?
# =============================================================================

# Every backend the call-dir contract names. The set is the spec's
# (docs/plans/2026-08-13-hotline-transport-adapter-herdr.md §2.1), not this tree's:
# 'herdr' is accepted here before Phase 1 implements its verbs, so a herdr call
# dir stays READABLE by a Phase 0 waiter instead of being rejected by it.
HOTLINE_TRANSPORTS=(cmux herdr headless)

# call_dir_transport <call-dir>
#
# Echoes the backend named in <call-dir>/transport.txt, or "" when no backend is
# named — an absent file (a legacy or hand-staged call dir) or an empty one. Both
# mean "infer from the host handles, as before the signal existed": a launcher
# that died between creating the dir and writing the value hands the waiter its
# own done+error.txt, and that is a better diagnosis than anything this function
# could say about a file it never finished writing.
#
# A value OUTSIDE the set above is a hard error. It says the call dir was made by
# a hotline that knows a backend this one does not, and every way of guessing is
# worse than saying so: inferring cmux polls a host of the wrong kind, and
# inferring headless file-watches a `done` nobody will write until --timeout
# expires — up to 30 minutes of silence bought by a one-word mismatch.
#
# Returns 1 on that error, message on stderr. Callers must run it as
#   TRANSPORT=$(call_dir_transport "$CALL_DIR") || exit 1
# because an `exit` inside the command substitution would leave only the subshell.
call_dir_transport() {  # <call-dir>
  local dir="${1:-}" value known
  [[ -f "$dir/transport.txt" ]] || return 0
  value=$(tr -d '[:space:]' < "$dir/transport.txt" 2>/dev/null || true)
  [[ -n "$value" ]] || return 0
  for known in "${HOTLINE_TRANSPORTS[@]}"; do
    [[ "$value" == "$known" ]] && { printf '%s' "$value"; return 0; }
  done
  printf "call_dir names transport '%s', which this hotline has no verbs for — known: %s (%s/transport.txt)\n" \
    "$value" "${HOTLINE_TRANSPORTS[*]}" "$dir" >&2
  return 1
}
