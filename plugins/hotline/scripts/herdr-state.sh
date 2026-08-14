#!/usr/bin/env bash
# =============================================================================
# herdr state: talking to the herdr CLI, and reading a herdr-hosted callee's
# condition.
#
# SOURCE this, don't execute it. Four scripts need the same judgements about herdr
# and must never disagree about them:
#
#   skills/dial/scripts/check-herdr.sh       — is this backend usable at all?
#   skills/dial/scripts/herdr-call-async.sh  — split a pane, start the agent
#   skills/dial/scripts/herdr-prompt.sh      — deliver the prompt to the agent
#   skills/dial/scripts/wait-for-response.sh — gate on the agent's lifecycle state
#
# WHY EVERY CALL GOES THROUGH herdr_cli. herdr reports a server-side failure as
# `{"error":{"code":…,"message":…}}` — and its EXIT STATUS IS NOT DEPENDABLE for
# that class of failure. Verified on herdr 0.8.0: `herdr agent get <unknown>`
# prints `{"error":{"code":"agent_not_found",…}}` and exits 0. A caller that
# branches on `$?` alone therefore reads "no such agent" as success and carries on
# with an empty session id. So the JSON decides, and the exit status is only the
# backstop for failures that produce no JSON at all (herdr absent, socket gone, a
# CLI usage error — which exits 2).
#
# EVERY FUNCTION HERE THAT TALKS TO herdr RETURNS ITS RESULT IN A GLOBAL, NOT ON
# STDOUT. That is not a style choice, it is the only shape that works:
#   • A global assigned inside `$( )` never reaches the caller — the substitution
#     runs in a subshell. So a function that printed its answer could not also
#     report WHY it failed, and every diagnostic would arrive empty.
#   • Under `set -e` (wait-for-response.sh) a failing `x=$(herdr …)` aborts the
#     enclosing shell — or, inside a substitution, silently truncates the function
#     mid-body before it can classify the error. Hence the `if x=$(…)` form below,
#     which puts the assignment in a tested context where `set -e` stays quiet.
# Callers therefore run `herdr_thing args` and then read the documented global.
# The two pure functions (herdr_mint_agent_name, herdr_settled_states) touch no
# CLI and are safe to use in a substitution.
#
# The herdr vocabulary this file assumes, all verified live on 0.8.0:
#   pane ids are opaque workspace-qualified strings — `w6:p1`, never reused.
#   `pane split` returns the new pane at `.result.pane.pane_id`.
#   `agent start <name> --kind claude --pane <id>` BLOCKS until herdr has detected
#     that agent interactive-ready (default 30s), and reports it at `.result.agent`
#     with `interactive_ready`, `agent_status`, and the claude session id at
#     `agent_session.value`.
#   agent names must match [a-z][a-z0-9_-]{0,31} and be unique among LIVE agents.
#   lifecycle states are idle | working | blocked | done | unknown. `done` is the
#     same underlying idle state as `idle` for a tab that has NOT been seen in the
#     focused UI — which is every hotline callee, since hotline never focuses one.
#     Waiting on `idle` alone therefore hangs on a finished callee; the settled set
#     is idle+done+blocked, and that is what herdr_settled_states names.
# =============================================================================

# Set by herdr_cli on every call. OUT is herdr's stdout verbatim; ERR is a
# one-line diagnostic (empty on success) that is safe to embed in JSON.
HERDR_CLI_OUT=""
HERDR_CLI_ERR=""

# herdr_cli <args...> — run the herdr CLI once.
#   0 — success; the response is in $HERDR_CLI_OUT.
#   1 — failure; $HERDR_CLI_ERR says why. See the header for why the JSON is
#       consulted before the exit status.
herdr_cli() {
  local rc err_file blob code msg
  HERDR_CLI_OUT=""
  HERDR_CLI_ERR=""
  err_file=$(mktemp)
  # `if x=$(…)` rather than a bare assignment: a tested context, so `set -e` in a
  # sourcing script cannot abort this function before it classifies the failure.
  if HERDR_CLI_OUT=$(herdr "$@" 2>"$err_file"); then rc=0; else rc=$?; fi

  # stderr first: that is where herdr puts a server error when it also has real
  # output to write on stdout, and an error there outranks a partial success here.
  for blob in "$(cat "$err_file" 2>/dev/null)" "$HERDR_CLI_OUT"; do
    [[ -z "$blob" ]] && continue
    code=$(jq -r '.error.code // empty' <<<"$blob" 2>/dev/null || true)
    msg=$(jq -r '.error.message // empty' <<<"$blob" 2>/dev/null || true)
    if [[ -n "$code" || -n "$msg" ]]; then
      HERDR_CLI_ERR="${code:-herdr_error}: ${msg:-no message}"
      break
    fi
  done

  if [[ -z "$HERDR_CLI_ERR" && $rc -ne 0 ]]; then
    HERDR_CLI_ERR=$(tr '\n\r\t' '   ' < "$err_file" 2>/dev/null | cut -c1-200 | sed 's/[[:space:]]*$//')
    [[ -z "$HERDR_CLI_ERR" ]] && HERDR_CLI_ERR="herdr ${1:-} ${2:-} exited $rc with no diagnostic"
  fi
  rm -f "$err_file"

  [[ -n "$HERDR_CLI_ERR" ]] && return 1
  return 0
}

# --- Preflight ---------------------------------------------------------------
# Is the backend usable? Two independent questions, answered separately because a
# caller has to say something different about each: a missing binary is an install
# problem, an unreachable server is a "start herdr" problem.
herdr_on_path() { command -v herdr >/dev/null 2>&1; }

# True when a herdr server is actually there to talk to.
#
# HERDR_ENV=1 is accepted as proof on its own: it is only ever injected INTO a
# herdr-managed pane, so its presence means a server is hosting this very process.
# Otherwise `session list` is the probe — read-only, and the one command that
# answers "is a server up" without creating or focusing anything. (Note it prints a
# TABLE, not JSON, so only its exit status is meaningful here.)
herdr_reachable() {
  [[ "${HERDR_ENV:-}" == "1" ]] && return 0
  herdr session list >/dev/null 2>&1
}

# --- Where does a herdr callee live? -----------------------------------------
# HERDR_PANE ← the pane to SPLIT for a herdr-hosted callee, chosen in this order:
#   1. $HOTLINE_HERDR_PANE — an explicit override, and the seam the test suite
#      drives (nothing else can name a pane that does not exist yet).
#   2. $HERDR_PANE_ID — the caller's own pane, when the caller itself runs inside
#      herdr. Preferred over `--current` because it is explicit: omitting a target
#      lets herdr fall back to the UI-FOCUSED pane, which may belong to the user or
#      to another client entirely.
#   3. the first pane herdr reports — the caller is outside herdr but a server is
#      up. Any pane will do: we split it, and the split's child is a fresh shell
#      whether or not the parent is running an agent.
#   0 — $HERDR_PANE holds the pane id; 1 — $HERDR_CLI_ERR says why not.
HERDR_PANE=""
herdr_resolve_split_pane() {
  HERDR_PANE=""
  if [[ -n "${HOTLINE_HERDR_PANE:-}" ]]; then HERDR_PANE="$HOTLINE_HERDR_PANE"; return 0; fi
  if [[ -n "${HERDR_PANE_ID:-}"      ]]; then HERDR_PANE="$HERDR_PANE_ID";      return 0; fi
  herdr_cli pane list || return 1
  HERDR_PANE=$(jq -r '.result.panes[0].pane_id // empty' <<<"$HERDR_CLI_OUT" 2>/dev/null || true)
  if [[ -z "$HERDR_PANE" ]]; then
    HERDR_CLI_ERR="herdr reported no panes, so there is nothing to split for the callee"
    return 1
  fi
  return 0
}

# --- Naming the callee's agent -----------------------------------------------
# The agent name IS the durable host handle for a herdr call: `agent prompt
# <name>`, `agent wait <name>` and `agent get <name>` all address it, and it
# survives the detach/lid/SSH-drop events that kill a cmux surface. It is what goes
# in herdr_agent.txt and what dial.sh reports as the call's host ref.
#
# Shape is a herdr constraint, not a preference: [a-z][a-z0-9_-]{0,31}, unique among
# live agents. `hotline-` prefixes every one so an agent left behind by a call is
# attributable at a glance in `herdr agent list`; the slug says which call it was;
# the random tail is what keeps two dials into the same directory from colliding.
# 8 + 14 + 1 + 6 = 29 characters at most. Pure — no CLI, safe in a substitution.
herdr_mint_agent_name() {  # <callee-cwd-or-label>
  local slug tail
  slug=$(printf '%s' "$(basename "${1:-call}")" \
         | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' \
         | tr -s '-' | sed 's/^-*//; s/-*$//' | cut -c1-14)
  [[ -z "$slug" ]] && slug="call"
  tail=$(openssl rand -hex 3 2>/dev/null \
         || od -A n -N 3 -t x1 /dev/urandom 2>/dev/null | tr -d ' \n' \
         || true)
  [[ -z "$tail" ]] && tail=$(printf '%06x' $(( $$ % 16777216 )))
  printf 'hotline-%s-%s' "$slug" "$tail"
}

# True when no LIVE agent already answers to this name. herdr rejects a duplicate
# outright, and a name freed by an exited agent is reusable — so this is a collision
# check, not a reservation. Mint again if it says no.
herdr_agent_name_free() {  # <name>
  herdr_cli agent get "$1" || return 0
  [[ -z "$(jq -r '.result.agent // empty' <<<"$HERDR_CLI_OUT" 2>/dev/null || true)" ]]
}

# --- Reading a live agent ----------------------------------------------------
# The settled lifecycle set: what "the callee stopped working" means, ready to
# splice into an `agent wait` argv. Passed EXPLICITLY even though it is also herdr's
# own default, because `done` vs `idle` is a distinction hotline can get wrong in
# only one direction — a hotline callee's tab is never focused, so herdr reports it
# `done` rather than `idle`, and waiting on `idle` alone hangs forever on a callee
# that has finished. A future change to herdr's defaults must not silently
# reintroduce that hang.
#
# An array rather than a string: a string would have to be word-split at the call
# site, which is exactly the construct that turns one stray space in this value into
# a malformed herdr invocation.
# The state names are quoted because one of them is `done`, which reads as the loop
# keyword to enough tooling to be worth spelling out as data.
HERDR_SETTLED_ARGS=(--until "idle" --until "done" --until "blocked")

# HERDR_AGENT_STATUS ← the agent's current lifecycle state, or "" when it cannot be
# read — which INCLUDES an agent that has exited, since herdr clears the name along
# with it. Always returns 0: "no state" is an answer, not an error, and every caller
# wants to report it rather than abort on it.
HERDR_AGENT_STATUS=""
herdr_agent_status() {  # <name>
  HERDR_AGENT_STATUS=""
  herdr_cli agent get "$1" || return 0
  HERDR_AGENT_STATUS=$(jq -r '.result.agent.agent_status // empty' <<<"$HERDR_CLI_OUT" 2>/dev/null || true)
  return 0
}

# HERDR_AGENT_SESSION_ID ← the claude session id herdr OBSERVED for this agent, or
# "" if it has none. Worth asking even though hotline presets the id with
# `--session-id`: herdr reads this from claude's own state, so a disagreement with
# the preset is evidence the passthrough did not take — and a transcript path
# derived from the wrong id would then miss silently for the whole call.
HERDR_AGENT_SESSION_ID=""
herdr_agent_session_id() {  # <name>
  HERDR_AGENT_SESSION_ID=""
  herdr_cli agent get "$1" || return 0
  HERDR_AGENT_SESSION_ID=$(jq -r '.result.agent.agent_session.value // empty' <<<"$HERDR_CLI_OUT" 2>/dev/null || true)
  return 0
}
