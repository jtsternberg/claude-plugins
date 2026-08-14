#!/usr/bin/env bash
# =============================================================================
# Wait for Response: poll until an async hotline call completes.
#
# Three modes. The launcher names its backend in call_dir/transport.txt ('cmux',
# 'herdr' or 'headless') and that is read first; an absent transport.txt names
# nothing, so the backend is inferred from the call dir's host handles. The cmux
# SUB-mode (surface vs workspace) is still the host-handle file distinction either
# way — see the dispatch block below, and wait-for-session.sh for the full contract.
#
#   Headless mode (transport.txt=headless, or no host handle at all): poll
#   call_dir/done at 2s intervals. headless-call-async.sh's own poller writes
#   response.json + done.
#
#   CMUX mode (surface_ref.txt / workspace_ref.txt present): cmux-call-async.sh
#   doesn't run a background poller (under cmux access_mode=cmuxOnly, an orphaned
#   subshell gets "Broken pipe" on every cmux call). This script (a child of the
#   caller's cmux-spawned bash, so cmux access works) does the polling itself,
#   via two tiers:
#     PRIMARY — read the callee's Claude Code JSONL transcript (structured source
#       of truth; correlate on the CALL_ID nonce in event data, not scraped
#       pixels). transcript-extract.sh does the read; this is rendering-
#       independent and separates "never submitted" from "submitted, working".
#       Used whenever the transcript path is derivable (cwd.txt + session id).
#     FALLBACK — the legacy screen scrape (cmux read-screen + STATUS regex +
#       chrome stripping). Used for old call_dirs, a missing cwd/session, or if
#       the transcript file never appears. (claude-plugins-0pwc)
#   Either tier writes response.json + done and closes the workspace unless
#   keep_workspace.txt said otherwise.
#
#   herdr mode (transport.txt=herdr): the SAME transcript reader, gated differently.
#   herdr reports native lifecycle states, so `herdr agent wait` replaces the 2s
#   screen poll as the when-to-read gate, and transcript-extract.sh then decides
#   what the transcript MEANS exactly as above — same nonce/STATUS bracketing, same
#   0/3/4 contract. There is NO screen-scrape tier: a claude REPL runs on the
#   terminal's alternate screen, whose rows never enter herdr's scrollback, so an
#   unconfirmable herdr call is reported as unconfirmable rather than scraped.
#   Nothing is closed afterwards — outliving disconnects is the point of herdr.
#
# Output (stdout, every mode):
#   {"session_id":"...","response":"..."}
# plus, on exit 4 only, an additive `"awaiting_review":true` — every other status
# emits byte-identical JSON to before.
#
# The emitted JSON is compact (single line) and re-validated via jq before
# being written to stdout — so stdout is guaranteed to be parseable JSON on
# exit 0, or the script exits non-zero with an error on stderr.
#
# Caller note: agents running under zsh MUST NOT pipe the captured output
# through `echo` (zsh's echo interprets backslash escapes and will corrupt
# any JSON with escape sequences). Use `<<<"$VAR"` or read from the
# call_dir/response.json file directly.
#
# Exit codes:
#   0 — response received, call finished (valid JSON on stdout)
#   1 — error (timeout, remote failure, unparseable response.json, or — in
#       transcript mode — no submit evidence for the nonce within
#       --submit-deadline while the payload sits in the callee's input box, either
#       as visible text or as a collapsed `[Pasted text` placeholder; message on
#       stderr)
#   3 — PREEMPTED: the callee was handed a different task mid-call AND no STATUS
#       for this nonce arrived within the grace window that followed, so it is
#       never coming. error.txt names the preempting prompt and the surface to look
#       at. The work may have completed anyway. A mid-call redirect of the SAME
#       order resolves normally instead of landing here — see the grace window
#       below. The surface/session is left LIVE (whatever keep_workspace.txt says),
#       exactly as on exit 4: this verdict is a judgement about a human's intent
#       read off a transcript, and closing the surface would destroy the only place
#       to check it — the very thing the message tells the caller to do.
#       (claude-plugins-dvjo, claude-plugins-mrpi)
#   4 — AWAITING_REVIEW: response received, but the work order is NOT finished —
#       the callee reported a checkpoint and is idle waiting for your review or
#       follow-up. Same valid JSON on stdout as exit 0, plus
#       `"awaiting_review": true`; the surface/session is deliberately left LIVE
#       (never closed, whatever keep_workspace.txt says) so you can reply into it
#       via cmux-reuse-surface.sh. Not a failure. (claude-plugins-n4vy)
#
# Why 4 exists: "is the work finished" and "is the reply ready" are separate
# facts, and the protocol used to have one word for both. A callee doing step 1
# of 3 with a report-and-hold instruction could only honestly say
# WORK_IN_PROGRESS — which is exactly what this script treats as "keep polling".
# Observed live: the waiter blocked past its 600s tool timeout, was backgrounded,
# and had to be killed while the finished report sat complete in the callee's
# transcript. WORK_IN_PROGRESS still means keep polling, unchanged.
#
# Usage:
#   wait-for-response.sh <call_dir> [--timeout <seconds>] [--submit-deadline <seconds>]
#
# Re-invoking on the same call_dir is supported and always opens a FRESH --timeout
# budget. A previous waiter's timeout is a fact about how long that waiter was
# willing to wait, not about the call, so it is recorded as a resumable marker
# instead of a terminal verdict — see WAITER_TIMEOUT_MARKER below. A real remote
# failure (launcher error, preemption) still short-circuits instantly.
# (claude-plugins-tyaj)
#
# Environment:
#   HOTLINE_POLL_SLEEP — real seconds to sleep per poll tick (default 2, i.e.
#     $POLL_INTERVAL). The budget is accounted in fixed integer POLL_INTERVAL
#     ticks either way, so lowering this collapses wall-clock WITHOUT changing
#     how many iterations run or what they decide. Tests set it to ~0.
#     (claude-plugins-fhn3)
#   HOTLINE_PREEMPT_GRACE — how long (default 180, in the same integer POLL_INTERVAL
#     tick accounting as --timeout) to keep polling after the callee's session shows
#     a preempting prompt, before giving up with exit 3. A human who interrupts to
#     REDIRECT the same work order looks identical to one who reassigns the session;
#     only the callee's next STATUS tells them apart, so the waiter waits for it.
#     Tests set it small. (claude-plugins-mrpi)
# =============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRANSCRIPT_EXTRACT="$SELF_DIR/transcript-extract.sh"
HOTLINE_SCRIPTS="$(cd "$SELF_DIR/../../.." && pwd)/scripts"
TRANSCRIPT_PATH_SH="$HOTLINE_SCRIPTS/transcript-path.sh"
# input_box_content: what is sitting in the callee's live input box, as opposed to
# anywhere on its screen. The same one definition cmux-paste.sh confirms against —
# two readers of the REPL's box would drift (repl-state.sh's header says why).
# shellcheck source=../../../scripts/repl-state.sh
source "$HOTLINE_SCRIPTS/repl-state.sh"
# shellcheck source=../../../scripts/transport.sh
source "$HOTLINE_SCRIPTS/transport.sh"

CALL_DIR="${1:-}"
TIMEOUT=""
# Two separate numbers on purpose:
#   POLL_INTERVAL — the tick the timeout budget is accounted in. Must stay an
#     integer; the ELAPSED counters below are $(( )) arithmetic.
#   POLL_SLEEP    — the real time one tick costs.
# They are equal in production. Splitting them is what lets the suite run the
# poller's full logic — same iteration count, same branch decisions, same
# messages — for ~0 wall-clock. Note the budget deliberately is NOT anchored to
# $SECONDS: a wall-clock budget could not be collapsed this way, and the counter
# already restarts at 0 on every invocation. (claude-plugins-fhn3)
POLL_INTERVAL=2
POLL_SLEEP="${HOTLINE_POLL_SLEEP:-$POLL_INTERVAL}"
# How long a preempting prompt buys the callee before we call the call lost. Same
# integer tick accounting as TIMEOUT, so the suite can collapse it too.
# (claude-plugins-mrpi)
PREEMPT_GRACE="${HOTLINE_PREEMPT_GRACE:-180}"
# Transcript mode: how long to wait for the transcript to show ANY evidence the
# nonce reached the callee (user record, queued-command injection, enqueue, or a
# STATUS naming our call_id — see transcript-extract.sh) before asking the input
# box what happened. Evidence appears within ~1-2s of a real submit, so this is
# deliberately short — it separates "sitting in the prompt box" (fast-fail) from
# "submitted, model working" (patient until --timeout).
SUBMIT_DEADLINE=15

if [[ -z "$CALL_DIR" || ! -d "$CALL_DIR" ]]; then
  echo "Call directory not provided or does not exist" >&2
  exit 1
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)         TIMEOUT="$2";         shift 2 ;;
    --submit-deadline) SUBMIT_DEADLINE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# --- Backend dispatch --------------------------------------------------------
# Same contract as wait-for-session.sh, which documents it in full: transport.txt
# is read FIRST and names the backend ('cmux' | 'herdr' | 'headless'); it is COARSE, so the
# cmux sub-mode is still surface_ref.txt vs workspace_ref.txt. An absent
# transport.txt is a legacy call dir and falls back to the old inference; a value
# outside the contract's set is refused outright (scripts/transport.sh). cmux
# still resolves through its host handle, because that is what the branch below
# polls and because a launcher that failed before placing a host hands us a
# handle-less dir whose error.txt only the file-watch path reports.
TRANSPORT=$(call_dir_transport "$CALL_DIR") || exit 1
HAS_SURFACE=false
HAS_WORKSPACE=false
[[ -f "$CALL_DIR/surface_ref.txt"   ]] && HAS_SURFACE=true
[[ -f "$CALL_DIR/workspace_ref.txt" ]] && HAS_WORKSPACE=true

CMUX_MODE=false
SURFACE_MODE=false
HERDR_MODE=false
case "$TRANSPORT" in
  headless)
    # Stated headless: never poll a cmux host, whatever else the dir holds.
    ;;
  herdr)
    # herdr mode: `herdr agent wait` is the WHEN-TO-READ gate and
    # transcript-extract.sh is still the answer. See the herdr block below.
    HERDR_MODE=true
    ;;
  *)
    # 'cmux', or absent (legacy inference); 'herdr' until Phase 1 gives it its own
    # branch. A value outside the known set never reaches here —
    # call_dir_transport already refused it.
    if $HAS_SURFACE || $HAS_WORKSPACE; then CMUX_MODE=true; fi
    ;;
esac
if $CMUX_MODE && $HAS_SURFACE; then SURFACE_MODE=true; fi
# CMUX mode gets a longer default (30 min) since work orders can run a while.
# herdr shares it: the same work orders, and its whole selling point is outliving
# the events that would have killed a cmux surface.
if [[ -z "$TIMEOUT" ]]; then
  if $CMUX_MODE || $HERDR_MODE; then TIMEOUT=1800; else TIMEOUT=300; fi
fi

# A waiter that runs out of budget writes done+error.txt so a caller who does NOT
# want to wait again sees the failure without re-polling. That is deliberate, and
# it is also what made a long work order unwaitable: once the 1800s budget expired,
# every later invocation on the same call_dir replayed "Timed out" within seconds
# instead of opening a fresh window, so a caller could not resume the wait at all.
#
# The fix separates the two facts. A timeout drops this marker alongside
# done+error.txt, and finding it here means "a waiter gave up", not "the call
# failed" — so we clear the terminal state and poll again with a full budget
# measured from now. A real remote failure (launcher error, preemption) writes
# error.txt WITHOUT the marker and still short-circuits immediately, unchanged.
# response.json is the guard against clearing a call that genuinely finished.
# (claude-plugins-tyaj)
WAITER_TIMEOUT_MARKER="$CALL_DIR/waiter_timeout.txt"
if [[ -f "$WAITER_TIMEOUT_MARKER" && ! -f "$CALL_DIR/response.json" ]]; then
  echo "hotline: a previous waiter gave up on this call ($(tr -d '\n' < "$WAITER_TIMEOUT_MARKER")) — resuming with a fresh ${TIMEOUT}s budget from now." >&2
  rm -f "$CALL_DIR/done" "$CALL_DIR/error.txt" "$WAITER_TIMEOUT_MARKER"
fi

# Record an expired budget as resumable. Called only where the wait itself ran
# out — never on a remote failure, which must stay terminal.
record_waiter_timeout() {   # $1 = which loop expired
  printf 'budget=%ss %s' "$TIMEOUT" "$1" 2>/dev/null > "$WAITER_TIMEOUT_MARKER" || true
}

emit_response_json() {
  # Re-emit as compact, validated JSON. If response.json is somehow
  # unparseable, jq exits non-zero with an error on stderr — we surface that
  # loudly rather than hand a caller visibly-valid-but-broken bytes.
  if ! jq -c . "$CALL_DIR/response.json"; then
    echo "response.json is not parseable JSON — hotline emission bug" >&2
    exit 1
  fi
}

if $HERDR_MODE; then
  # =========================================================================
  # herdr mode. The gate changes; the answer does not.
  #
  # herdr reports native lifecycle states (idle / working / blocked / done /
  # unknown), so "when should I read the transcript" stops being a 2s screen poll
  # and becomes one blocking `herdr agent wait`. What the transcript MEANS is
  # unchanged: transcript-extract.sh runs here byte-identically to the cmux
  # transcript-PRIMARY path above, with the same nonce/STATUS bracketing and the
  # same exit-code contract (0 / 4 / 3 / 1).
  #
  # WHY THE STATES CANNOT REPLACE THE PROTOCOL. herdr's lifecycle is COARSER than
  # hotline's semantics: a callee ending on `STATUS: WORK_COMPLETE` and one ending
  # on `STATUS: AWAITING_REVIEW` both settle to the same state. The STATUS line
  # carries a distinction the lifecycle cannot express, and the callee is
  # transport-blind — the ringing skill emits the same protocol whichever
  # multiplexer hosts it. So the state is the gate and the nonce is the meaning.
  #
  # AND THERE IS NO SCREEN FALLBACK. The cmux path degrades to scraping the
  # rendered screen when it cannot derive a transcript path. herdr cannot: a claude
  # REPL is a full-screen alternate-screen TUI, and rows that leave the alternate
  # screen never enter herdr's host scrollback, so `agent read` cannot recover what
  # the transcript missed. An undecidable herdr call is reported as undecidable.
  # =========================================================================
  HERDR_SCRIPTS="$SELF_DIR/../../../scripts"
  # shellcheck source=../../../scripts/herdr-state.sh
  source "$HERDR_SCRIPTS/herdr-state.sh"
  # The dual-cwd-spelling rule lives in ONE place and this is a second caller of it,
  # not a second copy. Delivery already reads the callee's transcript through this
  # helper; the wait deriving its own single-spelling path is precisely how the two
  # disagreed live — delivery confirmed the nonce while the wait reported "the prompt
  # never reached the agent" about a transcript that held the finished answer.
  # shellcheck source=../../../scripts/transcript-confirm.sh
  source "$HERDR_SCRIPTS/transcript-confirm.sh"

  AGENT=""
  [[ -s "$CALL_DIR/herdr_agent.txt" ]] && AGENT=$(tr -d '[:space:]' < "$CALL_DIR/herdr_agent.txt")
  SESSION_ID=""
  [[ -f "$CALL_DIR/session_id.txt"        ]] && SESSION_ID=$(cat "$CALL_DIR/session_id.txt")
  [[ -z "$SESSION_ID" && -f "$CALL_DIR/session_id_preset.txt" ]] && \
    SESSION_ID=$(cat "$CALL_DIR/session_id_preset.txt")
  CALL_ID=""
  [[ -f "$CALL_DIR/call_id.txt" ]] && CALL_ID=$(cat "$CALL_DIR/call_id.txt")

  # If the launcher already wrote done+error.txt, surface that immediately.
  if [[ -f "$CALL_DIR/done" && -f "$CALL_DIR/error.txt" ]]; then
    cat "$CALL_DIR/error.txt" >&2
    exit 1
  fi

  # Everything the extraction needs, checked UP FRONT and reported as one message.
  # There is no weaker tier to fall through to, so a missing input is a hard stop
  # rather than a silent downgrade — and saying which input is missing is the
  # difference between a fixable report and "it timed out".
  #
  # CANDIDATES, PLURAL. The transcript may be under either spelling of the callee's
  # cwd, because Claude Code encodes the path it RESOLVED: a callee under a symlink
  # (/tmp on macOS) writes to the realpath encoding. The launcher now canonicalizes
  # cwd.txt so the two normally coincide, but a hand-staged or older call dir does
  # not, and asking the shared helper costs nothing.
  TRANSCRIPT_CANDIDATES=()
  if [[ -n "$SESSION_ID" && -n "$CALL_ID" && -f "$CALL_DIR/cwd.txt" && -x "$TRANSCRIPT_PATH_SH" ]]; then
    RECV_CWD=$(cat "$CALL_DIR/cwd.txt")
    while IFS= read -r _cand; do
      [[ -n "$_cand" ]] && TRANSCRIPT_CANDIDATES+=("$_cand")
    done < <(hotline_transcript_candidates "$RECV_CWD" "$SESSION_ID")
  fi
  if [[ ${#TRANSCRIPT_CANDIDATES[@]} -eq 0 ]]; then
    {
      echo "Cannot read a herdr callee's response: no transcript path could be derived from $CALL_DIR."
      echo "Needed: session_id.txt (or session_id_preset.txt)=${SESSION_ID:-MISSING}, call_id.txt=${CALL_ID:-MISSING}, cwd.txt=$( [[ -f "$CALL_DIR/cwd.txt" ]] && cat "$CALL_DIR/cwd.txt" || echo MISSING )."
      echo "herdr has no screen fallback — a claude REPL runs on the terminal's alternate screen, so its output is not in herdr's scrollback. Read the callee's transcript directly, or re-dial."
    } >&2
    exit 1
  fi
  # The one that exists, re-resolved every poll: the file does not exist until the
  # first prompt lands, so which candidate is live is not knowable up front.
  # TRANSCRIPT_PATH is the reported path — the live one when there is one, otherwise
  # the first candidate, so a diagnostic always names something concrete.
  TRANSCRIPT_PATH="${TRANSCRIPT_CANDIDATES[0]}"
  ALL_CANDIDATES="${TRANSCRIPT_CANDIDATES[*]}"
  herdr_live_transcript() {
    local c
    for c in "${TRANSCRIPT_CANDIDATES[@]}"; do
      if [[ -f "$c" ]]; then printf '%s' "$c"; return 0; fi
    done
    return 1
  }

  # A herdr call dir with no agent name is a launcher bug, and it stays one — but the
  # ANSWER may already be on disk, and refusing to look for it because the gate is
  # missing would throw away a completed work order. So the loop below runs its
  # transcript read first and only refuses when it reaches the point of needing the
  # gate. (HAS_GATE is also what keeps the lifecycle probes from querying an empty
  # agent name.)
  HAS_GATE=true
  [[ -z "$AGENT" ]] && HAS_GATE=false

  # herdr never closes anything after a call: outliving disconnects is the reason
  # to pick this transport, and Phase 2's follow-up re-targets this same agent by
  # name. keep_workspace.txt is written 'true' by the launcher and this is where
  # that promise is kept — the agent and its pane are left live on every exit path.
  # (`herdr pane close $(cat $CALL_DIR/herdr_pane.txt)` is the manual teardown.)

  # The gate's per-iteration budget. `agent wait` blocks until the agent settles,
  # so a slice bounds how long we go without re-reading the transcript: a callee
  # that emits its terminal STATUS mid-turn and keeps working would otherwise not
  # be noticed until it settled. It also bounds a wait on an agent that has already
  # settled (which returns instantly) into a poll rather than a spin.
  GATE_SLICE_MS="${HOTLINE_HERDR_WAIT_SLICE_MS:-30000}"

  H_ELAPSED=0
  H_SUBMITTED=false
  SUBMIT_UNCONFIRMED=false
  LAST_STATUS=""
  FILE_GRACE=10
  while [[ $H_ELAPSED -lt $TIMEOUT ]]; do
    # --- The transcript FIRST, every iteration. -----------------------------
    # Before the gate, deliberately: the answer may already be on disk (the callee
    # settled while a previous waiter was between polls, or before this waiter
    # started at all), and asking herdr to wait for a state change that has already
    # happened would burn a whole slice to learn nothing.
    LIVE_TRANSCRIPT=$(herdr_live_transcript) || LIVE_TRANSCRIPT=""
    [[ -n "$LIVE_TRANSCRIPT" ]] && TRANSCRIPT_PATH="$LIVE_TRANSCRIPT"
    if [[ -n "$LIVE_TRANSCRIPT" ]]; then
      set +e
      T_OUT=$(bash "$TRANSCRIPT_EXTRACT" "$LIVE_TRANSCRIPT" "$CALL_ID" 2>/dev/null)
      T_RC=$?
      set -e
      case $T_RC in
        0)   # turn complete
          printf '%s' "$T_OUT" > "$CALL_DIR/response.json"
          touch "$CALL_DIR/done"
          emit_response_json
          exit 0
          ;;
        13)  # checkpoint reached — reply ready, work order unfinished, agent live
          printf '%s' "$T_OUT" > "$CALL_DIR/response.json"
          touch "$CALL_DIR/done"
          emit_response_json
          exit 4
          ;;
        10) H_SUBMITTED=true ;;   # submitted, model working — be patient
        12)                       # preempted: a new human prompt landed after ours
          {
            echo "Callee reassigned mid-call — a new prompt arrived in its session after ours, so it will never emit STATUS for call_id=$CALL_ID."
            echo "Preempting prompt: $T_OUT"
            echo "herdr agent: $AGENT · transcript: $TRANSCRIPT_PATH"
            echo "Our work order may well have completed anyway — read the transcript, or \`herdr agent attach $AGENT\`, before re-dialing."
          } > "$CALL_DIR/error.txt"
          touch "$CALL_DIR/done"
          cat "$CALL_DIR/error.txt" >&2
          exit 3
          ;;
        11)                       # nothing in the transcript carries the nonce yet
          # cmux answers "unsubmitted or merely queued?" by reading the callee's
          # input box. herdr cannot see that box at all (alternate screen), so the
          # honest substitute is its lifecycle state — which is a genuine signal and
          # not a guess: an agent sitting `idle`/`done` with no record of our nonce
          # anywhere is very unlikely to be about to answer it, while a `working`
          # one plainly has something in flight. Neither is proof, so this REPORTS
          # and keeps waiting rather than concluding.
          if ! $H_SUBMITTED && [[ $H_ELAPSED -ge $SUBMIT_DEADLINE ]] && ! $SUBMIT_UNCONFIRMED; then
            SUBMIT_UNCONFIRMED=true
            LAST_STATUS=""
            $HAS_GATE && { herdr_agent_status "$AGENT"; LAST_STATUS="$HERDR_AGENT_STATUS"; }
            echo "hotline: no submit confirmation within ${SUBMIT_DEADLINE}s — nothing in $TRANSCRIPT_PATH carries call_id=$CALL_ID. herdr reports agent ${AGENT:-<none recorded>} as '${LAST_STATUS:-unreadable}'. Still waiting (up to ${TIMEOUT}s); \`herdr agent attach $AGENT\` shows what it is actually doing." >&2
          fi
          ;;
        *)   # extractor usage / read error — no second tier to fall back to
          echo "transcript-extract.sh failed on $TRANSCRIPT_PATH (rc=$T_RC). herdr has no screen fallback; read the transcript directly." >&2
          exit 1
          ;;
      esac
    elif [[ $H_ELAPSED -ge $FILE_GRACE ]]; then
      # The transcript does NOT exist until the first prompt lands, so a brief
      # absence right after launch is normal. A LASTING absence is not, and there
      # is nothing else to read: say so instead of waiting out 30 minutes.
      #
      # EVERY candidate is named, not just the one we would have reported. This
      # message used to name a single derived path and assert the prompt never
      # arrived — and it said that, live, about a callee whose finished answer was
      # sitting in the OTHER spelling of that same path.
      LAST_STATUS=""
      $HAS_GATE && { herdr_agent_status "$AGENT"; LAST_STATUS="$HERDR_AGENT_STATUS"; }
      {
        echo "No transcript after ${H_ELAPSED}s at any derived path ($ALL_CANDIDATES) — a herdr callee's transcript appears as soon as its first prompt lands, so this means the prompt never reached the agent (or the session id is wrong)."
        echo "herdr reports agent ${AGENT:-<none recorded>} as '${LAST_STATUS:-unreadable}'. Check \`herdr agent get $AGENT\`, or attach to it; do NOT blindly re-dial."
        echo "Nothing was sent by this script and no terminal state was recorded, so re-running it on the same call_dir simply looks again."
      } >&2
      exit 1
    fi

    # --- The gate. ----------------------------------------------------------
    # No agent name recorded: the transcript read above got its chance (which is the
    # whole reason this check is here and not up front — a completed work order on
    # disk is worth more than a tidy early exit), and now there is nothing to wait
    # ON. That is a launcher bug, so it fails loudly rather than degrading into a
    # bare file poll that would sit here for the full budget.
    if ! $HAS_GATE; then
      {
        echo "Cannot gate a herdr wait: $CALL_DIR has no herdr_agent.txt, so there is no agent to wait on (launcher bug)."
        echo "The transcript was read first and carries no terminal STATUS for call_id=$CALL_ID yet ($ALL_CANDIDATES) — read it directly, or \`herdr agent list\` to find the callee and record its name."
      } >&2
      exit 1
    fi

    # An agent whose name no longer resolves has EXITED (herdr clears the name with
    # it). Checked after the transcript read, so a callee that answered and then
    # quit is reported as an answer, not as a death.
    herdr_agent_status "$AGENT"; LAST_STATUS="$HERDR_AGENT_STATUS"
    if [[ -z "$LAST_STATUS" ]]; then
      {
        echo "herdr agent $AGENT is gone (${HERDR_CLI_ERR:-no live agent answers to that name}) and its transcript carries no terminal STATUS for call_id=$CALL_ID — the callee exited before answering."
        echo "The transcript is still on disk at $TRANSCRIPT_PATH; read it before re-dialing."
      } > "$CALL_DIR/error.txt"
      touch "$CALL_DIR/done"
      cat "$CALL_DIR/error.txt" >&2
      exit 1
    fi

    # Block until the lifecycle settles, bounded by the slice. Its outcome is not
    # branched on: `agent wait` timing out means "still working", which is exactly
    # what the next transcript read will confirm or refute. This is a gate, not a
    # verdict — herdr's states are too coarse to be one (see the block header).
    GATE_START=$(date +%s)
    herdr_cli agent wait "$AGENT" "${HERDR_SETTLED_ARGS[@]}" \
      --timeout "$GATE_SLICE_MS" >/dev/null 2>&1 || true
    GATE_SECONDS=$(( $(date +%s) - GATE_START ))
    [[ $GATE_SECONDS -lt 0 ]] && GATE_SECONDS=0

    sleep "$POLL_SLEEP"
    # The gate's real wall time is charged to the budget alongside the tick, or a
    # 30s block would cost 2s of a 1800s budget and this loop would run for hours.
    H_ELAPSED=$((H_ELAPSED + POLL_INTERVAL + GATE_SECONDS))
  done

  {
    if $SUBMIT_UNCONFIRMED; then
      echo "Timed out after ${TIMEOUT}s waiting on herdr agent $AGENT with NO submit confirmation — nothing in the transcript ever carried call_id=$CALL_ID ($ALL_CANDIDATES)."
      echo "Last state herdr reported: '${LAST_STATUS:-unreadable}'. Either the prompt never landed or the callee has been busy the whole time; herdr cannot tell these apart from outside (its states do not name what is being worked on)."
    else
      echo "Timed out waiting for the herdr callee to finish (${TIMEOUT}s) — $TRANSCRIPT_PATH, agent $AGENT, last state '${LAST_STATUS:-unreadable}'."
      echo "The callee may simply be slower than the budget."
    fi
    echo "Re-run this script on the same call_dir to resume with a fresh ${TIMEOUT}s budget; it re-reads the transcript and sends nothing. The agent is still live — \`herdr agent attach $AGENT\` to look."
  } > "$CALL_DIR/error.txt"
  record_waiter_timeout "mode=herdr"
  touch "$CALL_DIR/done"
  cat "$CALL_DIR/error.txt" >&2
  exit 1
fi

if $CMUX_MODE; then
  # Resolve the read-screen target: a surface (side-by-side/window placement)
  # or a workspace (detached placement).
  if $SURFACE_MODE; then
    REF=$(cat "$CALL_DIR/surface_ref.txt")
    READ_TARGET=(--surface "$REF")
  else
    REF=$(cat "$CALL_DIR/workspace_ref.txt")
    READ_TARGET=(--workspace "$REF")
  fi
  WS_REF="$REF"
  KEEP=$(cat "$CALL_DIR/keep_workspace.txt" 2>/dev/null || echo false)
  LAUNCH_SCRIPT=$(cat "$CALL_DIR/launch_script.txt" 2>/dev/null || true)
  SESSION_ID=""
  [[ -f "$CALL_DIR/session_id.txt"        ]] && SESSION_ID=$(cat "$CALL_DIR/session_id.txt")
  [[ -z "$SESSION_ID" && -f "$CALL_DIR/session_id_preset.txt" ]] && \
    SESSION_ID=$(cat "$CALL_DIR/session_id_preset.txt")
  ESC=$(printf '\x1b')

  # Per-call nonce match. When call_id.txt is present (new launcher), we
  # require every STATUS line we accept to carry `call_id=<nonce>`. This
  # makes replayed scrollback from `claude --resume` (which restores the
  # prior transcript including its STATUS markers) impossible to mistake
  # for completion of THIS call. Without the nonce, the bare regex would
  # match the replayed STATUS and return stale response text — see
  # claude-plugins-gkj for the failure mode.
  CALL_ID=""
  [[ -f "$CALL_DIR/call_id.txt" ]] && CALL_ID=$(cat "$CALL_DIR/call_id.txt")
  if [[ -n "$CALL_ID" ]]; then
    STATUS_TAIL=" call_id=${CALL_ID}[[:space:]]*\$"
    STATUS_TAIL_AWK=" call_id=${CALL_ID}[[:space:]]*$"
  else
    STATUS_TAIL="[[:space:]]*\$"
    STATUS_TAIL_AWK="[[:space:]]*$"
  fi

  # AWAITING_REVIEW leaves the surface alone: a follow-up is expected, so closing
  # it would destroy the very session the caller is about to reply into. This is
  # the one path that overrides keep_workspace.txt=false. (claude-plugins-n4vy)
  cleanup_script_only() {
    rm -f "$LAUNCH_SCRIPT" 2>/dev/null || true
  }

  cleanup_workspace_and_script() {
    rm -f "$LAUNCH_SCRIPT" 2>/dev/null || true
    if [[ "$KEEP" != "true" ]]; then
      # Suppress BOTH stdout and stderr — close-{surface,workspace}'s "OK …"
      # message would otherwise pollute the JSON we emit on stdout, breaking
      # jq parsing in callers. Surface placements default to KEEP=true (the
      # surface lives in the caller's own window and is meant to stay visible),
      # so this close path is normally only taken in detached/workspace mode.
      if $SURFACE_MODE; then
        cmux close-surface --surface "$WS_REF" >/dev/null 2>&1 || true
      else
        cmux close-workspace --workspace "$WS_REF" >/dev/null 2>&1 || true
      fi
    fi
  }

  # The one exit-3 site. Reached either at the end of the grace window or when the
  # overall budget runs out with the window still open — a budget expiring mid-grace
  # is still a preemption, and the generic timeout message would bury the one fact
  # the caller needs. PREEMPT_TEXT holds the latest preempting prompt the extractor
  # reported. (claude-plugins-mrpi)
  preempt_exit() {
    local surf
    surf=$(cat "$CALL_DIR/surface_ref.txt" 2>/dev/null || echo '?')
    {
      echo "Callee reassigned mid-call — a new prompt arrived in its session after ours, and no STATUS for call_id=$CALL_ID arrived within the ${PREEMPT_GRACE}s grace window after the preempting prompt."
      echo "Preempting prompt: $PREEMPT_TEXT"
      echo "Surface: $surf · transcript: $TRANSCRIPT_PATH"
      echo "Our work order may well have completed anyway — the surface and session are left OPEN so you can check: read the transcript or look at the surface before re-dialing."
    } > "$CALL_DIR/error.txt"
    touch "$CALL_DIR/done"
    # Keeps the surface, like exit 4 does and for the same reason: this verdict is
    # inferred from a human's typing, the message tells the caller to go look at the
    # surface, and closing it would delete the evidence — plus a wrong exit 3 stays
    # cheap to recover from. (claude-plugins-mrpi)
    cleanup_script_only
    cat "$CALL_DIR/error.txt" >&2
    exit 3
  }

  ELAPSED=0
  # If the launcher already wrote done+error.txt, surface that immediately.
  if [[ -f "$CALL_DIR/done" && -f "$CALL_DIR/error.txt" ]]; then
    cat "$CALL_DIR/error.txt" >&2
    exit 1
  fi

  # === PRIMARY PATH: read the callee's structured JSONL transcript ===========
  # Rendering-independent submit-confirmation + response-capture. The transcript
  # is the source of truth (Claude Code flushes one JSON event per line in real
  # time); we correlate on the nonce in DATA, not on scraped pixels, so REPL
  # chrome changes can't break it. Falls through to the screen-scrape loop below
  # only when the path can't be derived or the file never appears — old
  # call_dirs, missing cwd.txt/session, or a mis-derived path. (claude-plugins-0pwc)
  TRANSCRIPT_PATH=""
  if [[ -n "$SESSION_ID" && -n "$CALL_ID" && -f "$CALL_DIR/cwd.txt" && -x "$TRANSCRIPT_PATH_SH" ]]; then
    RECV_CWD=$(cat "$CALL_DIR/cwd.txt")
    TRANSCRIPT_PATH=$(bash "$TRANSCRIPT_PATH_SH" --cwd "$RECV_CWD" --session "$SESSION_ID" 2>/dev/null || true)
  fi

  # Is the nonce sitting unsubmitted in the callee's input box? That is the only
  # thing that actually distinguishes "never submitted" from "submitted, queued
  # behind the callee's current turn" — the submit deadline cannot (mo8m).
  #
  # Measured: a user event lands 0.35-1.0s after Enter on an idle REPL, and
  # 3.1-4.2s when the REPL has anything in flight, because a follow-up sent
  # mid-turn is QUEUED and its event only lands when that turn ends. A callee
  # working a long task therefore has no upper bound worth hard-coding.
  #
  # We only ever ask this when the transcript shows NO submit evidence at all,
  # which is what makes the check sound: a submitted message renders into the
  # transcript, so if the nonce is on screen with nothing behind it, it is still
  # in the prompt box. Note a QUEUED message is also drawn on screen while it
  # waits — that used to read here as "unsubmitted", and the enqueue record now
  # rules it out before we ever look. (claude-plugins-1jpz)
  # A COLLAPSED PASTE HIDES THE NONCE. CC renders any paste over ~800 chars or 3
  # lines as `[Pasted text #N +M lines]`, so a parked work order — which is most of
  # them — puts nothing on screen that carries the call_id. Looking for the nonce
  # alone therefore answers "not visible" for the exact payload shape most likely to
  # be parked, and the waiter then sits out its full 1800s budget on a message that
  # was never going to submit. So the live input box HOLDING a placeholder counts as
  # the same evidence: the box is where an unsubmitted payload sits, and after the
  # submit deadline with nothing in the transcript, that placeholder is ours.
  #
  # BOX-SCOPED, BOTH SHAPES. `[Pasted text` in the scrollback is a submitted turn's
  # echo and would incriminate a healthy delivery — and the nonce is no different.
  # A whole-screen nonce match looks safe — a per-call nonce cannot be a leftover —
  # and is beside the point: a SUBMITTED payload echoes its own nonce back into the
  # transcript above the box, so finding it anywhere on screen proves arrival, never
  # non-submission. Read through a scrolled viewport that echo is often the ONLY
  # thing on screen, and a hard exit 1 then asserts the message is sitting
  # unsubmitted while the callee is mid-turn on it (claude-plugins-r465.6). The box
  # is where "arrived but never submitted" lives, and a short payload renders its
  # nonce there verbatim, so nothing legitimate is lost.
  #
  # The read is also scroll-immune (cmux_read_live) and tailed to the live screen
  # rows, so the box this looks at is the current one.
  #
  # This function looks and reports. It never presses Enter: an extra Enter on a
  # payload that did submit is a double submit, and the waiter cannot tell the two
  # apart (references/error-recovery.md § Delivery). Recovery is the caller's call.
  #
  # BOX_EVIDENCE names which shape fired, so the diagnostic can say what was actually
  # seen rather than asserting a nonce is on screen when a placeholder is.
  # Returns 0 = visibly unsubmitted, 1 = not visible, 2 = could not look.
  BOX_EVIDENCE=""
  nonce_visible_in_input_box() {
    [[ -z "$CALL_ID" ]] && return 2
    [[ ${#READ_TARGET[@]} -eq 0 ]] && return 2
    local raw scr box rows
    raw=$(cmux_read_live "response wait" "${READ_TARGET[0]}" "${READ_TARGET[1]}") || return 2
    [[ -z "$raw" ]] && return 2
    # The window is the pane's measured height where that can be read, and the
    # 60-row constant where it cannot (repl-state.sh; the measurement is one bare
    # read, memoized per handle). This looks at the INPUT BOX, which is the bottom
    # row of the live screen, so a window that overshoots onto history can only find
    # a `❯` echo from a turn that already ended — and reading that as "the payload is
    # sitting unsubmitted" is a hard exit 1 on a delivery that landed.
    rows=$(cmux_screen_rows "response wait" "${READ_TARGET[0]}" "${READ_TARGET[1]}" || true)
    scr=$(repl_screen_tail "$raw" "$(repl_screen_tail_lines "$rows")")
    box=$(input_box_content "$scr")
    if [[ -n "$box" ]] && printf '%s' "$box" | grep -qF "$CALL_ID"; then
      BOX_EVIDENCE="call_id=$CALL_ID is sitting in the callee's input box"
      return 0
    fi
    if [[ -n "$box" ]] && printf '%s' "$box" | grep -qF '[Pasted text'; then
      BOX_EVIDENCE="the callee's input box is holding a collapsed paste placeholder ($box), which hides the nonce"
      return 0
    fi
    return 1
  }

  if [[ -n "$TRANSCRIPT_PATH" ]]; then
    T_ELAPSED=0
    T_SUBMITTED=false
    FELL_BACK=false
    # Set once the submit deadline passes with no confirmation, so the final
    # timeout message can say submit was never confirmed without asserting why.
    SUBMIT_UNCONFIRMED=false
    FILE_GRACE=10   # transcript appears ~instantly for a live session; else fall back
    # Grace-window state. -1 = no preempting prompt seen yet; otherwise the tick at
    # which one first appeared, so the window is measured from it in the same
    # accounting as TIMEOUT. (claude-plugins-mrpi)
    PREEMPT_SEEN_AT=-1
    PREEMPT_TEXT=""
    while [[ $T_ELAPSED -lt $TIMEOUT ]]; do
      if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
        # No transcript file yet — brief grace, then fall back to scraping
        # rather than hard-fail (guards against a mis-derived path).
        [[ $T_ELAPSED -ge $FILE_GRACE ]] && { FELL_BACK=true; break; }
        sleep "$POLL_SLEEP"; T_ELAPSED=$((T_ELAPSED + POLL_INTERVAL)); continue
      fi

      set +e
      T_OUT=$(bash "$TRANSCRIPT_EXTRACT" "$TRANSCRIPT_PATH" "$CALL_ID" 2>/dev/null)
      T_RC=$?
      set -e
      case $T_RC in
        0)  # turn complete — T_OUT is {"session_id":..,"response":..}
          printf '%s' "$T_OUT" > "$CALL_DIR/response.json"
          touch "$CALL_DIR/done"
          cleanup_workspace_and_script
          emit_response_json
          exit 0
          ;;
        13)  # checkpoint reached — reply ready, work order unfinished, session live.
          # Same delivery as exit 0 (response.json + done + stdout JSON, and T_OUT
          # already carries awaiting_review:true from the extractor) minus the
          # close: the caller replies into this same surface next.
          printf '%s' "$T_OUT" > "$CALL_DIR/response.json"
          touch "$CALL_DIR/done"
          cleanup_script_only
          emit_response_json
          exit 4
          ;;
        10)                       # submitted, model working — be patient
          T_SUBMITTED=true
          # The extractor sees post-preempt evidence we are still the live order
          # (its STATUS names our nonce after the interjection), so any grace window
          # we had opened is void, not merely paused. (claude-plugins-mrpi)
          PREEMPT_SEEN_AT=-1
          PREEMPT_TEXT=""
          ;;
        12)                       # …but only while the receiver is still OURS.
          # A new human prompt arrived after our turn with nothing since naming our
          # call_id. That is EITHER a reassignment (our STATUS is never coming) or a
          # mid-course correction of our own order the callee has not answered yet —
          # and at this instant the two are indistinguishable, which is exactly what
          # made instant-bail wrong: the redirected callee reported WORK_COMPLETE to
          # nobody. So start a bounded window and keep polling; the callee resolves
          # it by naming our nonce again (→ RC 0/10/13), or the window closes and we
          # exit 3 with the prompt we saw. (claude-plugins-mrpi, claude-plugins-dvjo)
          PREEMPT_TEXT="$T_OUT"
          if [[ $PREEMPT_SEEN_AT -lt 0 ]]; then
            PREEMPT_SEEN_AT=$T_ELAPSED
            echo "hotline: a new prompt arrived in the callee's session after ours — it may be a redirect of this same work order, so waiting ${PREEMPT_GRACE}s for a STATUS naming call_id=$CALL_ID before giving up." >&2
          fi
          if [[ $((T_ELAPSED - PREEMPT_SEEN_AT)) -ge $PREEMPT_GRACE ]]; then
            preempt_exit
          fi
          ;;
        11)                       # nothing in the transcript carries the nonce yet
          if ! $T_SUBMITTED && [[ $T_ELAPSED -ge $SUBMIT_DEADLINE ]]; then
            # The deadline alone proves nothing (mo8m). Ask the input box, which
            # is the only thing that can actually tell the two cases apart.
            set +e
            nonce_visible_in_input_box
            BOX_RC=$?
            set -e
            if [[ $BOX_RC -eq 0 ]]; then
              # EVIDENCE: our payload is on the callee's screen — either the nonce
              # itself, or the collapsed placeholder holding it in the live input box
              # — and the transcript holds no record of it arriving: not a user
              # record, not a queued-command injection, not even an enqueue. So it is
              # sitting in the prompt box unsubmitted.
              {
                echo "Message is still sitting UNSUBMITTED in the callee's input box after ${SUBMIT_DEADLINE}s — ${BOX_EVIDENCE}, but nothing in the transcript carries call_id=$CALL_ID: no user record, no queued-command injection, no enqueue ($TRANSCRIPT_PATH)."
                echo "This is a transport failure, not a problem with your message content — escaping/quoting is almost never the cause."
                echo "Send Enter to the surface (cmux send-key --surface $WS_REF Enter) rather than re-sending the text, which would append to what is already in the box. Or re-dial via a fresh surface."
              } >&2
              touch "$CALL_DIR/done" 2>/dev/null || true
              cleanup_workspace_and_script
              exit 1
            fi
            # Not visible, or we could not look: a follow-up sent while the callee
            # was mid-turn is QUEUED, and if the enqueue record has not landed yet
            # this is indistinguishable from a slow submit. Do not assert a cause
            # and do not give up — stay patient until --timeout.
            if ! $SUBMIT_UNCONFIRMED; then
              SUBMIT_UNCONFIRMED=true
              if [[ $BOX_RC -eq 2 ]]; then
                echo "hotline: no submit confirmation within ${SUBMIT_DEADLINE}s and the callee's screen could not be read, so slow-vs-never-submitted is undecidable — still waiting (up to ${TIMEOUT}s)." >&2
              else
                echo "hotline: no submit confirmation within ${SUBMIT_DEADLINE}s, but the text is not in the callee's input box either — it may be queued behind the callee's current turn. Still waiting (up to ${TIMEOUT}s)." >&2
              fi
            fi
          fi
          ;;
        *)  FELL_BACK=true; break ;;   # extractor usage/read error → fall back
      esac
      sleep "$POLL_SLEEP"
      T_ELAPSED=$((T_ELAPSED + POLL_INTERVAL))
    done
    if ! $FELL_BACK; then
      # Budget gone with the grace window still open: the last thing we knew was a
      # preemption, so report THAT rather than a timeout the caller cannot act on.
      # (claude-plugins-mrpi)
      if [[ $PREEMPT_SEEN_AT -ge 0 ]]; then
        preempt_exit
      fi
      # Ran the full TIMEOUT in transcript mode while merely working → a genuine
      # timeout, not a reason to re-scrape. Report it and stop.
      if $SUBMIT_UNCONFIRMED; then
        # Never got submit confirmation, and the box check did not incriminate the
        # transport either. Report both live possibilities and how to settle it,
        # rather than picking one the script cannot observe (mo8m).
        {
          echo "Timed out after ${TIMEOUT}s in transcript mode with NO submit confirmation — nothing in the transcript ever carried call_id=$CALL_ID: no user record, no queued-command injection, no enqueue ($TRANSCRIPT_PATH)."
          echo "Could not confirm whether the message submitted: it may still be queued behind a long turn, or it may never have submitted. The script cannot tell these apart from timing alone."
          echo "To check: cmux read-screen --surface $WS_REF --scrollback --lines 80 (the --scrollback form is scroll-immune; the bare form returns whatever the pane is scrolled to) — if your text is sitting in the input box it never submitted; if the callee is mid-turn it was queued. Do NOT blindly re-dial; that risks double-queueing the same work."
          echo "To keep waiting instead, re-run this script on the same call_dir — that resumes with a fresh ${TIMEOUT}s budget and sends nothing."
        } > "$CALL_DIR/error.txt"
      else
        {
          echo "Timed out waiting for the callee to finish (transcript mode, ${TIMEOUT}s) — $TRANSCRIPT_PATH"
          echo "The callee may simply be slower than the budget. Re-run this script on the same call_dir to resume with a fresh ${TIMEOUT}s budget; it re-reads the transcript and sends nothing."
        } > "$CALL_DIR/error.txt"
      fi
      record_waiter_timeout "mode=transcript"
      touch "$CALL_DIR/done"
      cleanup_workspace_and_script
      cat "$CALL_DIR/error.txt" >&2
      exit 1
    fi
    # else: fall through to the screen-scrape backstop below.
  fi

  # === FALLBACK PATH: scrape the rendered cmux screen ========================
  while [[ $ELAPSED -lt $TIMEOUT ]]; do
    sleep "$POLL_SLEEP"
    ELAPSED=$((ELAPSED + POLL_INTERVAL))

    # Scroll-immune (repl-state.sh): a plain read-screen would hand back the user's
    # scrolled viewport, and this loop would never see the STATUS line that is
    # already sitting at the live tail.
    SCREEN=$(cmux_read_live "response wait" "${READ_TARGET[0]}" "${READ_TARGET[1]}" 9999 || true)
    [[ -z "$SCREEN" ]] && continue

    # Strip ANSI escape sequences and carriage returns. cmux returns
    # colorized terminal output, including colored STATUS lines, and raw
    # matching would miss those completion signals.
    CLEAN=$(echo "$SCREEN" | sed "s/${ESC}\[[0-9;]*[mGKHFJKsu]//g; s/${ESC}(B//g; s/\r//g")

    # Find the LATEST STATUS line anywhere in the screen. Robust against
    # trailing terminal chrome (shell prompts, the claude REPL's `│ > │` box
    # bottom, etc.). Receivers put their real STATUS at message tail — if a
    # response body quotes STATUS strings earlier, the real one still wins
    # because we always take the last occurrence.
    # Match any line that ENDS with `STATUS: <signal>` (allowing trailing
    # whitespace). The "latest such line wins" rule combined with the
    # end-of-line anchor handles every claude REPL rendering variant —
    # column-0, 2-space indent, `⏺ ` assistant marker, future UI tweaks —
    # without needing per-variant regex updates. Quoted STATUS strings
    # inside response prose almost never appear at end-of-line in
    # practice; if they do, "latest wins" still picks the receiver's real
    # terminal STATUS that comes after them.
    #
    # Trim everything before the matched STATUS for the comparison value.
    STATUS_RE="STATUS: [A-Z_]+${STATUS_TAIL_AWK}"
    LATEST_STATUS=$(echo "$CLEAN" | awk -v re="$STATUS_RE" '
      match($0, re) {
        s=substr($0, RSTART)
        sub(/[[:space:]]+$/, "", s)
      }
      END {print s}
    ')

    [[ -z "$LATEST_STATUS" ]] && continue
    [[ "$LATEST_STATUS" =~ ^STATUS:\ WORK_IN_PROGRESS ]] && continue

    if [[ "$LATEST_STATUS" =~ ^STATUS:\ (WORK_COMPLETE|OUT_OF_SCOPE|DONE|AWAITING_REVIEW) ]]; then
      # Strip terminal chrome before extracting the response. Aggressive
      # prefix match strips lines starting with claude's box-drawing
      # characters (the REPL renders its idle prompt as a multi-line box
      # where the middle line `│ > │` carries text; a stricter "pure chrome
      # only" regex leaves that line in the response).
      #
      # Lines we strip:
      #   - the `bash /tmp/hotline-launch-*` command echoed at the prompt
      #   - lines starting with claude's banner / box-drawing characters
      #   - claude's "ℹ ..." info lines (update available / tip banners)
      #   - the bare REPL prompt `> ` on its own line (markdown blockquotes
      #     starting with `> text` survive)
      #
      # Walk lines, reset buffer on every WORK_IN_PROGRESS, save buffer on
      # every terminal STATUS, emit the LAST saved buffer — matches the
      # LATEST_STATUS we chose for detection.
      WIP_RE="STATUS: WORK_IN_PROGRESS${STATUS_TAIL_AWK}"
      TERM_RE="STATUS: (WORK_COMPLETE|OUT_OF_SCOPE|DONE|AWAITING_REVIEW)${STATUS_TAIL_AWK}"
      RESPONSE=$(echo "$CLEAN" \
        | grep -v "^bash /tmp/hotline-launch" \
        | grep -vE "^[╭│╰─└┌┘┐ℹ]" \
        | grep -vE "^>[[:space:]]*$" \
        | awk -v wip="$WIP_RE" -v term="$TERM_RE" '
            $0 ~ wip  {buf=""; next}
            $0 ~ term {result=buf; buf=""; next}
            {buf = buf $0 ORS}
            END {printf "%s", result}
          ')

      # Scrape path mirrors the transcript path's AWAITING_REVIEW contract, or a
      # callee that checkpoints would hang here exactly as it used to: the status
      # matched neither the WIP `continue` nor the terminal branch, so the loop ran
      # to timeout with the report on screen. (claude-plugins-n4vy)
      if [[ "$LATEST_STATUS" =~ ^STATUS:\ AWAITING_REVIEW ]]; then
        jq -n --arg sid "$SESSION_ID" --arg resp "$RESPONSE" \
          '{session_id: $sid, response: $resp, awaiting_review: true}' > "$CALL_DIR/response.json"
        touch "$CALL_DIR/done"
        cleanup_script_only
        emit_response_json
        exit 4
      fi

      jq -n --arg sid "$SESSION_ID" --arg resp "$RESPONSE" \
        '{session_id: $sid, response: $resp}' > "$CALL_DIR/response.json"
      touch "$CALL_DIR/done"
      cleanup_workspace_and_script

      emit_response_json
      exit 0
    fi
  done

  # Timeout: write error.txt and done so a caller who does not want to wait again
  # sees the failure without re-polling — plus the marker that lets one who does
  # re-run this script for a fresh budget instead (claude-plugins-tyaj).
  {
    echo "Timed out waiting for STATUS in cmux ${WS_REF} (${TIMEOUT}s)"
    echo "Re-run this script on the same call_dir to resume with a fresh ${TIMEOUT}s budget; it re-reads the screen and sends nothing."
  } > "$CALL_DIR/error.txt"
  record_waiter_timeout "mode=scrape"
  touch "$CALL_DIR/done"
  cleanup_workspace_and_script
  cat "$CALL_DIR/error.txt" >&2
  exit 1
fi

# Headless mode — original file-watch behavior. This path needs no
# WAITER_TIMEOUT_MARKER: it writes neither done nor error.txt when it gives up, so
# a re-invocation already gets a fresh budget. Only `done` written by
# headless-call-async.sh's own poller — a real remote outcome — is terminal here.
ELAPSED=0
while [[ ! -f "$CALL_DIR/done" ]]; do
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "Timed out waiting for response (${TIMEOUT}s) — re-run on the same call_dir to keep waiting with a fresh budget." >&2
    exit 1
  fi
  sleep "$POLL_SLEEP"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ -f "$CALL_DIR/error.txt" ]]; then
  cat "$CALL_DIR/error.txt" >&2
  exit 1
fi

if [[ ! -f "$CALL_DIR/response.json" ]]; then
  echo "Done but no response.json found" >&2
  exit 1
fi

emit_response_json
