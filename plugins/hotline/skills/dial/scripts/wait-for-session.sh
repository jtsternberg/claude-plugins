#!/usr/bin/env bash
# =============================================================================
# Wait for Session: Poll until the remote session ID is available.
#
# Three modes. The launcher names its backend in call_dir/transport.txt ('cmux',
# 'herdr' or 'headless') and that is read first; an absent transport.txt names
# nothing, so the backend is inferred from the call dir's host handles. Either way the cmux
# SUB-mode (surface vs workspace) is still the host-handle file distinction. See
# the dispatch block below for the full contract.
#
#   Headless mode (transport.txt=headless, or no host handle at all): poll
#   call_dir/session_id.txt at 1s intervals; cmux-call.sh and
#   headless-call-async.sh write it themselves.
#
#   herdr mode (transport.txt=herdr): the same file watch, because herdr's launcher
#   is SYNCHRONOUS — `herdr agent start` blocks until the agent is
#   interactive-ready, so herdr-call-async.sh has already written session_id.txt
#   and there is no boot to detect or preset to promote. This wait confirms the id,
#   surfaces the launcher's error.txt if it failed, and registers the call.
#
#   CMUX mode (workspace_ref.txt present): cmux-call-async.sh wrote
#   session_id_preset.txt but does NOT confirm claude actually booted —
#   under cmux access_mode=cmuxOnly, the script's own background poller
#   can't talk to cmux. This script (running as a child of the caller's
#   cmux-spawned bash) confirms REPL liveness via ANY of three signals:
#     A) `cmux read-screen` matches the Claude Code REPL banner.
#     B) The claude transcript file
#        ~/.claude/projects/<encoded-cwd>/<preset-session-id>.jsonl is non-empty
#        AND has grown since this script started (created, or appended to, the
#        moment claude opens the session). The growth requirement is not
#        pedantry: on a plain resume that file already exists, so a bare
#        existence check fired on the first poll and reported a boot that had not
#        happened yet.
#     C) The REPL has drawn its input box on screen.
#   Any signal promotes session_id_preset.txt → session_id.txt. Signal B
#   exists because banner regex is fragile (scrollback eviction, ANSI weirdness,
#   --resume banner variance can defeat it even when claude DID boot fine).
#
#   Signal C exists because first contact now launches a BARE REPL and delivers
#   its prompt by paste afterwards: a REPL with no prompt yet may write nothing
#   to its transcript until the first turn arrives, so signal B can stay silent
#   for a session that is perfectly up. The input box is the signal that actually
#   matters to the step that follows — a paste into a shell that has not exec'd
#   claude is lost silently — and it is strictly stronger than "the banner is
#   somewhere in scrollback", which stays true long after a REPL has died.
#
# Prints the session ID to stdout on success.
#
# Exit codes:
#   0 — session ID found (printed to stdout)
#   1 — error (timeout, missing call_dir, or early failure)
#
# Usage:
#   wait-for-session.sh <call_dir> [--timeout <seconds>]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/repl-state.sh
source "$SCRIPT_DIR/../../../scripts/repl-state.sh"
# shellcheck source=../../../scripts/transport.sh
source "$SCRIPT_DIR/../../../scripts/transport.sh"

CALL_DIR="${1:-}"
TIMEOUT=""

if [[ -z "$CALL_DIR" || ! -d "$CALL_DIR" ]]; then
  echo '{"error":"Call directory not provided or does not exist"}' >&2
  exit 1
fi

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# --- Backend dispatch --------------------------------------------------------
# transport.txt, written by the launcher when it creates the call dir, names the
# backend outright: 'cmux', 'herdr' or 'headless'. It is read FIRST and it is a
# COARSE selector — it says which backend owns this call dir, NOT which cmux sub-mode.
# The sub-mode is still the host-handle distinction it always was:
#   surface mode    — surface_ref.txt present (side-by-side / --window placement).
#                     Poll the cmux SURFACE.
#   workspace mode  — workspace_ref.txt present (--detached placement).
#                     Poll the cmux WORKSPACE.
#
# An ABSENT transport.txt is a legacy call dir — one created before this signal
# existed, or staged by hand. Infer the backend from the handle files exactly as
# before: a handle means cmux, no handle means headless.
#
# A transport.txt naming a backend OUTSIDE the contract's set is refused outright
# rather than inferred — see scripts/transport.sh for why guessing is the worse
# failure. Inside the set, every value has its own branch below: transport.sh
# accepts a name and the dispatch here honours it, so the two never disagree
# about what 'herdr' means (claude-plugins-r6jj).
#
# WHY cmux STILL REQUIRES ITS HANDLE. The cmux branch below polls a surface or a
# workspace by ref, so a cmux call dir with no handle has nothing to poll — and
# that state is real, not hypothetical: transport.txt is written with the dir,
# well before a host is placed, and a launcher whose placement fails writes
# done+error.txt and hands that handle-less dir straight to this script. It takes
# the file-watch path below, whose check_early_fail reports the launcher's own
# error.txt. Forcing it down the cmux branch would replace that diagnosis with a
# bare `cat: no such file` from the ref read.
#
# cmux mode gets a longer default timeout (60s) because we're waiting for the
# receiver claude REPL to actually boot, not just a file to appear. Headless mode
# keeps its existing 30s default.
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
    # herdr's launcher is SYNCHRONOUS — `herdr agent start` blocks until the agent
    # is interactive-ready — so herdr-call-async.sh has already written
    # session_id.txt itself. There is nothing to poll a host for and no promotion
    # to perform: this wait confirms the id is on disk (or reports the launcher's
    # error.txt), then registers the call like every other transport. It takes the
    # file-watch path below for exactly that reason.
    #
    # Liveness is deliberately NOT re-probed here. The response wait gates on
    # `herdr agent wait`, which reports a dead agent with a diagnostic; adding a
    # second `agent get` here would only add a way for a transient herdr hiccup to
    # fail a dial whose callee is perfectly up.
    HERDR_MODE=true
    ;;
  *)
    # 'cmux', or absent (legacy inference). Both resolve through the host handle —
    # see the note above. Every backend the contract names has its own branch
    # above, so nothing but those two reaches here: a value outside the known set
    # was already refused by call_dir_transport, and adding a fourth backend to
    # HOTLINE_TRANSPORTS without a branch of its own would land it here and
    # file-watch it to --timeout (claude-plugins-r6jj).
    if $HAS_SURFACE || $HAS_WORKSPACE; then CMUX_MODE=true; fi
    ;;
esac
if $CMUX_MODE && $HAS_SURFACE; then SURFACE_MODE=true; fi
# The defaults live in repl-state.sh, not here. dial.sh derives the paste's
# input-box wait from the same numbers — they are waiting for the same event — and
# with two definitions the documented 60 was true of this wait and not of that one.
# herdr shares the cmux budget: both are waiting for a callee REPL to exist, and
# the caller who raised --boot-timeout for a slow machine meant that event. (herdr
# normally finds it already satisfied — its launcher blocked on the same thing.)
if [[ -z "$TIMEOUT" ]]; then
  if $CMUX_MODE || $HERDR_MODE; then
    TIMEOUT="$HOTLINE_BOOT_TIMEOUT_CMUX"
  else
    TIMEOUT="$HOTLINE_BOOT_TIMEOUT_HEADLESS"
  fi
fi

# Common early-fail check: if the launcher already wrote done+error.txt, bail.
check_early_fail() {
  if [[ -f "$CALL_DIR/done" && -f "$CALL_DIR/error.txt" ]]; then
    cat "$CALL_DIR/error.txt" >&2
    exit 1
  fi
}

if $CMUX_MODE; then
  # Resolve the read target: a surface (side-by-side/window) or a workspace
  # (detached).
  #
  # NO focus-pane, even though a pane_ref is on hand. The launcher has already SENT
  # to this target and the send is what attaches the PTY, so by the time this script
  # runs there is nothing left to attach — focusing here only moves the user's cursor
  # into a booting callee, which is how their keystrokes end up in its shell
  # (claude-plugins-r465.4).
  if $SURFACE_MODE; then
    REF=$(cat "$CALL_DIR/surface_ref.txt")
    READ_FLAG="--surface"
  else
    REF=$(cat "$CALL_DIR/workspace_ref.txt")
    READ_FLAG="--workspace"
  fi
  READ_TARGET=("$READ_FLAG" "$REF")
  if ! cmux_handle_ok "boot wait" "$REF"; then
    echo "CMUX call_dir recorded an empty ${READ_FLAG#--} handle — launcher bug" >&2
    exit 1
  fi
  WS_REF="$REF"
  if [[ ! -f "$CALL_DIR/session_id_preset.txt" ]]; then
    echo "CMUX call_dir missing session_id_preset.txt — launcher bug" >&2
    exit 1
  fi
  PRESET=$(cat "$CALL_DIR/session_id_preset.txt")
  ESC=$(printf '\x1b')

  # Signal B (transcript-file): claude writes
  # ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl the instant it opens
  # the session, so its existence is a strong REPL-liveness signal that
  # doesn't depend on terminal rendering (banner can scroll out of the read
  # window between polls, ANSI/--resume variance can defeat the regex).
  #
  # This depends on the preset being the id the callee ACTUALLY writes to. The
  # launcher guarantees that: fresh UUID on first contact, fresh UUID handed to
  # `--session-id` on a fork, resume target only on a plain resume. (When forks
  # presetted the resume target instead, this signal matched the ORIGINAL
  # session's long-existing transcript and fired instantly — a false
  # REPL-booted, and the wrong id to hand wait-for-response.sh.)
  # Encoding: Claude Code replaces EVERY non-alphanumeric char (path
  # separators, dots, AND spaces) with '-' when deriving the project-dir
  # name (verified against ~/.claude/projects/; e.g. '/Users/JT/.dotfiles' →
  # '-Users-JT--dotfiles', '/Users/JT/Documents/Southport UDO' →
  # '-Users-JT-Documents-Southport-UDO'). An earlier version only replaced
  # '/' and '.', so cwds containing spaces produced a path that never
  # existed. stat from a cmux-spawned bash child does NOT hit the cmux
  # socket, so the access_mode=cmuxOnly Broken-pipe constraint does not
  # apply here.
  TRANSCRIPT_PATH=""
  if [[ -f "$CALL_DIR/cwd.txt" ]]; then
    RECV_CWD=$(cat "$CALL_DIR/cwd.txt")
    ENCODED_CWD=$(printf '%s' "$RECV_CWD" | sed 's|[^a-zA-Z0-9]|-|g')
    TRANSCRIPT_PATH="${HOME}/.claude/projects/${ENCODED_CWD}/${PRESET}.jsonl"
  fi

  # FRESHNESS BASELINE for signal B. "The transcript file exists and is non-empty"
  # is only evidence of a boot when the file did not exist a moment ago — which is
  # true for a first contact under a brand-new session id, and FALSE for every
  # plain resume, where the file has been sitting there since the session was
  # created. Without this, a resume reported "REPL booted" on the first poll, in
  # the same millisecond the launch command was sent, and everything downstream
  # (including the paste) proceeded against a shell that had not exec'd claude yet.
  #
  # Recording the size rather than the mtime: growth is unambiguous, whereas a
  # comparison against "now" has to reason about clock skew and about a claude that
  # rewrites the file in place.
  TRANSCRIPT_BASE_SIZE=-1
  if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
    TRANSCRIPT_BASE_SIZE=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
    [[ "$TRANSCRIPT_BASE_SIZE" =~ ^[0-9]+$ ]] || TRANSCRIPT_BASE_SIZE=-1
  fi

  # (c) FAST-FAIL ON A MANGLED LAUNCH LINE. Before this existed, a launch command
  # that the shell refused ("zsh: command not found: rkebash", after three of the
  # user's keystrokes arrived ahead of it) produced no banner, no box and no
  # transcript — so the wait ran its full 60s and then blamed --allowedTools. The
  # screen said exactly what happened the whole time.
  #
  # ONE retry, not a loop: clear the input line and re-send the same launch command.
  # A mangle is a one-off collision with the user's typing, so a clean resend
  # usually boots; a second occurrence is a real problem and gets reported with the
  # actual screen text. Retrying without the clear would append to the broken line.
  LAUNCH_SCRIPT=$(cat "$CALL_DIR/launch_script.txt" 2>/dev/null || true)
  RELAUNCHED=false
  # How many launch-error lines were on screen when the retry fired, and the most
  # recent one seen at any point (quoted by the timeout diagnostic below).
  ERR_BASELINE=0
  LAST_LAUNCH_ERR=""

  SAW_BANNER=false
  SAW_TRANSCRIPT=false
  SAW_BOX=false
  ELAPSED=0
  while [[ ! -f "$CALL_DIR/session_id.txt" ]]; do
    check_early_fail
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
      DIAG=""
      if [[ -n "$TRANSCRIPT_PATH" ]]; then
        if $SAW_TRANSCRIPT; then
          DIAG=" (transcript file appeared at ${TRANSCRIPT_PATH} but logic still failed — investigate)"
        else
          DIAG=" (no banner and no input box matched on screen AND no transcript file at ${TRANSCRIPT_PATH})"
        fi
      else
        DIAG=" (no banner and no input box matched on screen; transcript-file check skipped — cwd.txt absent)"
      fi
      # A refusal we retried on and never saw superseded by a boot is the most useful
      # thing this message can carry — without it, the one case the fast-fail was
      # built for reads as a generic timeout again.
      if [[ -n "$LAST_LAUNCH_ERR" ]]; then
        DIAG+=" The surface showed a refused launch line and a re-send did not visibly boot: ${LAST_LAUNCH_ERR}."
      fi
      echo "Timed out waiting for Claude REPL to boot in cmux ${REF} (${TIMEOUT}s).${DIAG} The screen reads are scroll-immune (--scrollback --lines), so a scrolled pane is not the cause, and a shell error on the launch line would have been reported above. Common causes: the launch-script claude invocation is malformed (e.g. --allowedTools split into two argv words instead of --allowedTools=<list>), or the surface/workspace lost its tty." >&2
      exit 1
    fi

    # Signal A: banner on screen. Signal C: the input box is drawn.
    #
    # Scroll-immune read (repl-state.sh): a plain read-screen returns the user's
    # scrolled viewport, and a frozen capture reads as "nothing has happened yet"
    # for the whole budget.
    SCREEN=$(cmux_read_live "boot wait" "$READ_FLAG" "$REF" 9999 || true)
    if [[ -n "$SCREEN" ]]; then
      CLEAN=$(echo "$SCREEN" | sed "s/${ESC}\[[0-9;]*[mGKHFJKsu]//g; s/${ESC}(B//g; s/\r//g")
      if echo "$CLEAN" | grep -qE 'Claude Code v|Welcome back'; then
        SAW_BANNER=true
        echo "$PRESET" > "$CALL_DIR/session_id.txt"
        break
      fi
      # Only the TAIL: the box is drawn at the bottom of the live screen, while
      # this read is a 9999-line scrollback that may still hold `❯`-prefixed
      # echoes from a previous session in the same surface. Matching those would
      # report a REPL booted before it exists, and the paste that follows would
      # go into a bare shell.
      if repl_box_present "$(repl_screen_tail "$CLEAN" "$HOTLINE_BOX_TAIL_LINES")"; then
        SAW_BOX=true
        echo "$PRESET" > "$CALL_DIR/session_id.txt"
        break
      fi
      # The launch line never ran. Checked only while no boot signal has fired, and
      # scoped to errors naming OUR command (repl_launch_error_lines), so a tool
      # result or an rc-file complaint cannot fail a healthy boot.
      #
      # SCOPED TO THE LIVE SCREEN, not to the 9999-line scrollback this read is: an
      # error line stays in history forever, so a scan over the whole capture keeps
      # finding the one we have already recovered from.
      #
      # AND THE RETRY NEEDS A NEW ERROR, not the same one again. Ctrl-U clears the
      # input line, not the screen, so ~1s after the re-send the old diagnostic is
      # still sitting there — while claude's banner needs 1-3s. Counting the matches
      # and requiring the count to GROW is what distinguishes "the re-send was
      # refused too" from "the re-send is booting and the corpse of the first attempt
      # is still on screen"; the second reading exited 1 a second after the resend,
      # abandoning a surface where claude was in fact coming up. Counting rather than
      # comparing text so an identical second mangle still registers.
      ERR_LINES=$(repl_launch_error_lines \
        "$(repl_screen_tail "$CLEAN" "$HOTLINE_BOX_TAIL_LINES")" "$LAUNCH_SCRIPT")
      ERR_COUNT=0
      [[ -n "$ERR_LINES" ]] && ERR_COUNT=$(printf '%s\n' "$ERR_LINES" | grep -c . || true)
      LAUNCH_ERR=$(printf '%s\n' "$ERR_LINES" | grep . | tail -1 || true)
      if [[ -n "$LAUNCH_ERR" ]]; then
        LAST_LAUNCH_ERR="$LAUNCH_ERR"
        if ! $RELAUNCHED && [[ -n "$LAUNCH_SCRIPT" && -f "$LAUNCH_SCRIPT" ]]; then
          RELAUNCHED=true
          ERR_BASELINE=$ERR_COUNT
          echo "hotline: the callee's shell refused the launch line — ${LAUNCH_ERR}. Clearing the input line and re-sending it once." >&2
          cmux_clear_input_line "launch resend" "$READ_FLAG" "$REF"
          cmux_send_live "launch resend" "$READ_FLAG" "$REF" "bash $LAUNCH_SCRIPT\n" \
            >/dev/null 2>&1 || true
        elif $RELAUNCHED && [[ "$ERR_COUNT" -le "$ERR_BASELINE" ]]; then
          # The same refusal we already retried on. Keep waiting for the boot the
          # re-send should produce; if it never comes, the timeout below reports this
          # text rather than guessing.
          :
        else
          {
            echo "The callee's shell refused the launch line and a clean re-send did not help. What the surface actually shows:"
            echo "  $LAUNCH_ERR"
            echo "This is a launch-line transport failure in cmux ${REF}, not a problem with --allowedTools or the prompt content: the command was mangled before the shell saw it (typically the user's own keystrokes arriving on the same input line)."
            echo "Recover by hand: cmux read-screen ${READ_FLAG} ${REF} --scrollback --lines 80, then re-send \`bash ${LAUNCH_SCRIPT:-<launch script>}\` after a Ctrl-U."
          } >&2
          exit 1
        fi
      fi
    fi

    # Signal B: the transcript file is non-empty AND has grown since we started
    # (or did not exist then). See the baseline above for why growth is required.
    if [[ -n "$TRANSCRIPT_PATH" && -s "$TRANSCRIPT_PATH" ]]; then
      TR_NOW=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
      if [[ "$TR_NOW" =~ ^[0-9]+$ && "$TR_NOW" -gt "$TRANSCRIPT_BASE_SIZE" ]]; then
        SAW_TRANSCRIPT=true
        echo "$PRESET" > "$CALL_DIR/session_id.txt"
        break
      fi
    fi

    sleep 1
    ELAPSED=$((ELAPSED + 1))
  done

  # Register the call in the sessions registry the moment the session ID is
  # known — script-level, so registration no longer depends on the dialing
  # agent remembering the SKILL.md cache step (routinely skipped on visible
  # side-by-side work orders). Silent no-op if launch metadata is absent.
  bash "$(dirname "${BASH_SOURCE[0]}")/register-call.sh" "$CALL_DIR"

  # ---- The launch script leaves /tmp's top level here ------------------------
  # It only had to live at a path the CALLEE's shell could exec; once the REPL is
  # up, nothing launches again (delivery is a paste over the socket). So it moves
  # into the call dir, which is where this call's other scratch already lives and
  # whose lifecycle wait-for-response.sh already owns — the `rm -f` it does on
  # STATUS reads the same launch_script.txt, so the moved copy is cleaned up by
  # the path that was always meant to clean this up. Before this, every dial left
  # a /tmp/hotline-launch-* behind forever: ~270 had accumulated
  # (claude-plugins-qq9f).
  #
  # MOVED, not deleted, because the launch line is the first thing anyone
  # debugging a bad boot wants to read, and on the success path nothing else
  # records it.
  #
  # THIS IS THE FIRST SAFE POINT. The one-shot resend above re-sends
  # `bash $LAUNCH_SCRIPT`, so anything earlier could move the file out from under
  # the retry. And ONLY on the success path: every failure exit above deliberately
  # leaves the file exactly where it is, because the timeout diagnostic tells the
  # user to re-send `bash <launch script>` by hand and a surface stuck on a
  # refused launch line is a forensics target. Those are what the age sweep in
  # cmux-call-async.sh reaps.
  #
  # An `if`, not a `[[ … ]] && mv` one-liner: under `set -e` an AND-list whose
  # test fails exits the script, so an empty launch_script.txt would abort the
  # boot wait one line before it prints the session id.
  if [[ -n "$LAUNCH_SCRIPT" && -f "$LAUNCH_SCRIPT" ]]; then
    if mv -f "$LAUNCH_SCRIPT" "$CALL_DIR/launch_script.sh" 2>/dev/null; then
      echo "$CALL_DIR/launch_script.sh" > "$CALL_DIR/launch_script.txt"
    else
      # The move is the nice-to-have; getting it out of /tmp is the point.
      rm -f "$LAUNCH_SCRIPT" 2>/dev/null || true
    fi
  fi

  cat "$CALL_DIR/session_id.txt"
  exit 0
fi

# A herdr call dir must carry its host handle. The agent NAME is the only way to
# address the callee for delivery and for the response gate, so a herdr dir without
# one is a launcher bug — the same class of check as the cmux preset above, and
# worth failing loudly here rather than letting the delivery step report a missing
# --agent it could not have supplied.
if $HERDR_MODE && [[ ! -s "$CALL_DIR/herdr_agent.txt" ]]; then
  echo "herdr call_dir missing herdr_agent.txt — launcher bug (nothing can address the callee without the agent name)" >&2
  exit 1
fi

# File-watch mode — headless (original behavior) and herdr (see the dispatch note).
ELAPSED=0
while [[ ! -f "$CALL_DIR/session_id.txt" ]]; do
  check_early_fail
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    if $HERDR_MODE; then
      echo "Timed out waiting for the herdr callee's session id (${TIMEOUT}s). herdr-call-async.sh writes session_id.txt itself once \`herdr agent start\` returns, so an empty call dir here means the launcher neither succeeded nor wrote error.txt — check \`herdr agent list\` and the pane named in $CALL_DIR/herdr_pane.txt." >&2
    else
      echo "Timed out waiting for session ID (${TIMEOUT}s)" >&2
    fi
    exit 1
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

# Script-level registration — see the cmux-mode comment above.
bash "$(dirname "${BASH_SOURCE[0]}")/register-call.sh" "$CALL_DIR"

cat "$CALL_DIR/session_id.txt"
