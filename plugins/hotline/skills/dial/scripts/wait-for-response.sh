#!/usr/bin/env bash
# =============================================================================
# Wait for Response: poll until an async hotline call completes.
#
# Two modes. The launcher names its backend in call_dir/transport.txt ('cmux' or
# 'headless') and that is read first; a call_dir without it is inferred from its
# contents exactly as before the signal existed. The cmux SUB-mode (surface vs
# workspace) is still the host-handle file distinction either way — see the
# dispatch block below, and wait-for-session.sh for the full contract.
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
# Output (stdout, both modes):
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
# is read FIRST and names the backend ('cmux' | 'headless'); it is COARSE, so the
# cmux sub-mode is still surface_ref.txt vs workspace_ref.txt. An absent
# transport.txt is a legacy call dir and falls back to the old inference. cmux
# still resolves through its host handle, because that is what the branch below
# polls and because a launcher that failed before placing a host hands us a
# handle-less dir whose error.txt only the file-watch path reports.
TRANSPORT=""
if [[ -f "$CALL_DIR/transport.txt" ]]; then
  TRANSPORT=$(tr -d '[:space:]' < "$CALL_DIR/transport.txt" 2>/dev/null || true)
fi
HAS_SURFACE=false
HAS_WORKSPACE=false
[[ -f "$CALL_DIR/surface_ref.txt"   ]] && HAS_SURFACE=true
[[ -f "$CALL_DIR/workspace_ref.txt" ]] && HAS_WORKSPACE=true

CMUX_MODE=false
SURFACE_MODE=false
case "$TRANSPORT" in
  headless)
    # Stated headless: never poll a cmux host, whatever else the dir holds.
    ;;
  *)
    # 'cmux', absent (legacy inference), or a backend this tree has no verbs for.
    if $HAS_SURFACE || $HAS_WORKSPACE; then CMUX_MODE=true; fi
    ;;
esac
if $CMUX_MODE && $HAS_SURFACE; then SURFACE_MODE=true; fi
# CMUX mode gets a longer default (30 min) since work orders can run a while.
if [[ -z "$TIMEOUT" ]]; then
  $CMUX_MODE && TIMEOUT=1800 || TIMEOUT=300
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
