#!/usr/bin/env bash
# =============================================================================
# CMUX Reuse Surface: send a follow-up INTO the surface a session already lives
# in, instead of opening a new one.
#
# On first contact a cmux call lands the callee's claude session in a visible
# side-by-side (or windowed) surface and leaves it open. That surface holds a
# LIVE, idle claude REPL for that exact session. So a follow-up doesn't need to
# `claude --resume` in a fresh surface (which stacks N surfaces over N turns) —
# it pastes the next message into the REPL that's already sitting there.
#
# This script:
#   1. Verifies the stored surface still exists (the user may have closed it).
#   2. Pastes the raw message (led by a fresh [CALL_ID:] nonce line) into it.
#   3. Returns a call_dir wired exactly like cmux-call-async.sh's surface mode,
#      so wait-for-response.sh polls THIS surface and — thanks to the fresh
#      nonce — ignores the prior exchange's stale STATUS lines in scrollback.
#
# If the surface is gone, emits {"fallback":"fresh"} so the caller opens a new
# surface via cmux-call-async.sh --resume instead.
#
# No --resume / no relaunch: the live REPL IS the session. Re-launching claude
# inside it would nest a second REPL.
#
# Usage:
#   cmux-reuse-surface.sh --surface <uuid-or-ref> --session <id>
#                         (--prompt <text> | --prompt-file <path>)
#                         [--cwd <path>] [--keep-workspace]
#   # → {"call_dir": "/tmp/hotline-call-XXXXX"}   (reused, delivery confirmed)
#   # → {"fallback": "fresh", "reason": "..."}     (refused BEFORE anything was sent)
#   # → {"undelivered": true, "reason": "...", "call_dir": …, "prompt_file": …}
#         the paste went out and could not be confirmed. NOT a fallback: the
#         payload may have landed, so re-delivering would run it twice.
#
# --cwd is the CALLEE session's working directory. It lets wait-for-response.sh
# derive the callee's JSONL transcript path and read the response from structured
# data instead of scraping the screen (its preferred path). Omitting it still
# works — wait-for-response falls back to screen-scraping.
#
# ONE DELIVERY MODE, whatever the payload's size or shape: the whole message is
# pasted into the REPL in a single `terminal.paste` over cmux's control socket
# (cmux-paste.sh), which then proves the nonce reached the callee.
#
# Size- or shape-dependent delivery is off the table, and so is `cmux send` as the
# carrier: it interprets \n/\r/\t with no escape hatch and drops contiguous bytes
# mid-payload with no error — a verified 3,045-byte payload lost 2,538 of them. The
# socket paste has neither failure mode, so the payload itself rides the wire and
# lands in the callee's transcript, where a human reading the session (and the
# switchboard) can see what was actually asked. No sidecar file for the callee to go
# read, no preview to mistake for the request, no size threshold to tune
# (claude-plugins-i8fb).
#
# The one hazard still handled below (claude-plugins-06ws): the input-box clear is
# a raw Ctrl-C byte, which is a real interrupt. It is sent only when the box
# demonstrably holds unsent text AND the REPL shows no sign of an active turn.
#
# "Demonstrably" excludes a PLACEHOLDER. Claude Code draws its ghost suggested
# prompt, its queued-messages hint and `Message @agent…` from a placeholder prop
# while the input's value is empty, and a plain-text screen read cannot tell any of
# them from typed text. Such a box is treated as empty — no Ctrl-C, no verify, paste
# straight in — because that is what it is (claude-plugins-ff6g). The judgement comes
# from repl-state.sh's input_box_is_placeholder, which reads the styled render grid
# and fails closed: anything it cannot prove is a placeholder is handled as real
# unsent text.
#
# New call caches pass a stable surface UUID. Positional surface:N refs can
# silently retarget after a tab move or sibling close; they remain accepted only
# for backward compatibility with caches written by older plugin versions.
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  sed -n '2,/^# =\{10,\}$/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^=\{10,\}$'
  exit 0
fi

SURFACE_REF=""
SESSION_ID=""
PROMPT=""
PROMPT_FILE=""
CWD=""
KEEP_WORKSPACE=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --surface)        SURFACE_REF="$2";   shift 2 ;;
    --session)        SESSION_ID="$2";    shift 2 ;;
    --prompt)         PROMPT="$2";        shift 2 ;;
    --prompt-file)    PROMPT_FILE="$2";   shift 2 ;;
    --cwd)            CWD="$2";           shift 2 ;;
    --keep-workspace) KEEP_WORKSPACE=true; shift  ;;
    *)                shift ;;
  esac
done

# --prompt-file is preferred: it keeps the payload out of argv entirely, so
# quoting and shell metacharacters are never in play on the way in either.
if [[ -n "$PROMPT_FILE" ]]; then
  if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "{\"error\": \"--prompt-file does not exist: $PROMPT_FILE\"}"
    exit 1
  fi
  PROMPT=$(cat "$PROMPT_FILE")
fi

fallback_fresh() {
  jq -n --arg reason "$1" '{fallback: "fresh", reason: $reason}'
  exit 0
}

# --- Reading the REPL's state off its rendered screen -------------------------
# input_box_content / repl_looks_busy / repl_is_interrupted live at the plugin
# root because superseded-surface cleanup needs the identical judgements before it
# closes anything, and two copies would drift.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/repl-state.sh
source "$SCRIPT_DIR/../../../scripts/repl-state.sh"

[[ -z "$SURFACE_REF" ]] && fallback_fresh "no surface_ref provided"
[[ -z "$PROMPT"      ]] && { echo '{"error": "No --prompt or --prompt-file provided"}'; exit 1; }

# Existence check: read-screen fails (non-zero) when the surface is gone. A live
# surface returns its current screen (non-empty for an idle claude REPL). Treat
# both a hard failure and an empty screen as "surface not usable" → fall back.
if ! SCREEN=$(cmux read-screen --surface "$SURFACE_REF" 2>/dev/null) || [[ -z "$SCREEN" ]]; then
  fallback_fresh "surface $SURFACE_REF no longer exists or is not readable"
fi

# --- Is there still a claude REPL in there? ----------------------------------
# A readable surface is not a live REPL. If the callee ran /exit, or claude
# crashed, or the user reused the pane for something else, the surface is alive
# and its cached handle still resolves — but what is drawn is a SHELL PROMPT. None
# of the gates below notice: repl_is_interrupted looks for interrupt wording,
# input_box_content would report the prompt line as parked text at most, and
# repl_looks_busy looks for a spinner.
#
# The consequence is not a lost message. `terminal.paste` with submit_key:"return"
# would type the whole work order at that shell and press Enter, and the shell
# would run it — every line, as a command. So box presence is a hard gate, checked
# before anything else touches this surface.
if ! repl_box_present "$SCREEN"; then
  fallback_fresh "surface $SURFACE_REF is readable but shows no claude input box (a ❯ padded with U+00A0) — its REPL has exited or the pane has been repurposed; pasting a payload there would hand it to a shell"
fi

# --- Decide, BEFORE typing anything, whether this REPL will accept a follow-up
# and whether its input box needs clearing first (claude-plugins-06ws).
#
# The old unconditional Ctrl-C was harmful three ways, all verified: mid-tool-call
# it destroys the callee's in-flight tool call; during the pre-tool thinking phase
# it writes no interrupt record but restores the just-submitted prompt into the
# box, so the follow-up welds onto its tail and resubmits as one corrupted turn
# (2/2); and it sometimes silently fails to fire at all. Meanwhile text+Enter into
# a busy REPL is SAFE — the message is enqueued and delivered at the next tool
# boundary or flushed after the turn ends. So the interrupt is what we withhold,
# not the message.
#
# The clear is not simply deleted: leftover text in the box would prepend to our
# message, and falling back to a fresh surface every time the box is dirty would
# make that surface permanently unreusable (the leftover never goes away) —
# exactly the surface-stacking this script exists to prevent.
if repl_is_interrupted "$SCREEN"; then
  fallback_fresh "surface $SURFACE_REF is in the post-interrupt 'what should Claude do instead?' state; a follow-up typed here would answer that prompt instead of starting a turn"
fi

# --- Is that "parked text" actually Claude Code's PLACEHOLDER? ----------------
# input_box_content reads a plain-text screen, where a placeholder and unsent input
# are byte-identical, so ANY non-empty box line arrives here as parked text. The
# suggested-prompt ghost (`push it`), the queued-messages hint and `Message @agent…`
# are all placeholders: the input's VALUE is empty, and the box is drawn from a
# placeholder prop. A Ctrl-C therefore clears nothing, the verify below re-reads the
# same ghost, and every follow-up to an idle callee showing a suggestion bounces to a
# fresh surface — surfaces stack, and each bounce fires a real Ctrl-C at an idle REPL
# (two of those in a row exits the REPL entirely). That is claude-plugins-ff6g.
#
# input_box_is_placeholder (repl-state.sh) answers it from the styled render grid
# rather than the text, and FAILS CLOSED — anything it cannot prove reads as real
# text, i.e. exactly the behavior below without it.
#
# The address is resolved once and only when the box is non-empty, because on the
# common path (empty box) the RPC is not needed at all.
GHOST_ADDR_TRIED=false
GHOST_WS=""
GHOST_SURF=""
box_is_ghost_placeholder() {
  local addr
  if ! $GHOST_ADDR_TRIED; then
    GHOST_ADDR_TRIED=true
    if addr=$(cmux_surface_address "$SURFACE_REF"); then
      GHOST_WS="${addr%% *}"
      GHOST_SURF="${addr##* }"
    fi
  fi
  [[ -n "$GHOST_WS" && -n "$GHOST_SURF" ]] || return 1
  input_box_is_placeholder "$GHOST_WS" "$GHOST_SURF"
}

PARKED=$(input_box_content "$SCREEN")
# A placeholder is an EMPTY box wearing text. Treated as empty here, which skips the
# Ctrl-C, the idle-stability wait and the post-clear verify — the same path an empty
# box takes, because it is the same state.
if [[ -n "$PARKED" ]] && box_is_ghost_placeholder; then
  PARKED=""
fi
NEEDS_CLEAR=false
if [[ -n "$PARKED" ]]; then
  # Something is parked in the box. Clearing it costs a real interrupt, so only
  # do it against a REPL that is provably quiet: no in-flight markers, AND a
  # screen that hasn't changed over a short window (a live spinner or streaming
  # output moves even when the marker wording is one we don't know).
  if repl_looks_busy "$SCREEN"; then
    fallback_fresh "surface $SURFACE_REF has unsent text in its input box while a turn is in flight; clearing it would interrupt that turn and sending would weld onto the leftover"
  fi
  sleep 0.6
  if ! SCREEN2=$(cmux read-screen --surface "$SURFACE_REF" 2>/dev/null) || [[ -z "$SCREEN2" ]]; then
    fallback_fresh "surface $SURFACE_REF became unreadable while checking whether its REPL was idle"
  fi
  if [[ "$SCREEN2" != "$SCREEN" ]]; then
    fallback_fresh "surface $SURFACE_REF has unsent text in its input box and its screen is still changing (REPL busy); refusing to interrupt"
  fi
  NEEDS_CLEAR=true
fi

# HOTLINE_CALL_HOME overrides the base dir (default /tmp) so test suites can own
# and wipe every call dir instead of littering /tmp (claude-plugins-cjgn).
CALL_DIR=$(mktemp -d "${HOTLINE_CALL_HOME:-/tmp}/hotline-call-XXXXX")
echo "$SURFACE_REF" > "$CALL_DIR/surface_ref.txt"
echo "$KEEP_WORKSPACE" > "$CALL_DIR/keep_workspace.txt"
[[ -n "$SESSION_ID" ]] && {
  echo "$SESSION_ID" > "$CALL_DIR/session_id.txt"
  echo "$SESSION_ID" > "$CALL_DIR/session_id_preset.txt"
}
# Persist the callee's cwd so wait-for-response.sh can derive the transcript path
# (~/.claude/projects/<encoded-cwd>/<session-id>.jsonl) and read the response
# from structured JSONL rather than the rendered screen.
[[ -n "$CWD" ]] && echo "$CWD" > "$CALL_DIR/cwd.txt"

# Fresh per-call nonce so wait-for-response.sh distinguishes THIS turn's STATUS
# from the prior exchange's markers still in the surface's scrollback. Minting and
# placement are shared with both launchers (repl-state.sh) — a follow-up is never a
# slash command, so in practice the nonce lands on its own leading line here.
CALL_ID=$(hotline_mint_call_id)
echo "$CALL_ID" > "$CALL_DIR/call_id.txt"

# 0600, inside a 0700 mktemp dir: work orders go through here, and a
# default-umask 0644 payload would hand every follow-up to any local user. Named
# pending_paste.md like every other path's undelivered prompt, so one recovery
# instruction covers all of them. Removed the moment delivery is confirmed — the
# callee's transcript is the record, and this file is only the vehicle.
PAYLOAD_FILE="$CALL_DIR/pending_paste.md"
( umask 077; hotline_inject_call_id "$CALL_ID" "$PROMPT" > "$PAYLOAD_FILE" )
chmod 600 "$PAYLOAD_FILE" 2>/dev/null || true

# Clear the parked text out of the input box, then PROVE it went — the Ctrl-C is
# known to silently no-op sometimes (observed while the callee's stop hooks ran).
# If the box is still dirty we must not type: our message would prepend to the
# leftover and the whole line would run as garbage. `send-key ctrl+c` does NOT
# reach an in-pane claude REPL (verified against Claude Code v2.1.216); the raw
# Ctrl-C byte via the TEXT path does, regardless of cursor position.
#
# The re-read asks the same question the gate did, so it gets the same placeholder
# check: a Ctrl-C that empties the box lets Claude Code draw a placeholder into it,
# and reading that as "still dirty" would refuse a clear that in fact worked.
if $NEEDS_CLEAR; then
  cmux send --surface "$SURFACE_REF" $'\003' >/dev/null 2>&1 || true
  sleep 0.4
  if ! SCREEN3=$(cmux read-screen --surface "$SURFACE_REF" 2>/dev/null) \
     || { [[ -n "$(input_box_content "$SCREEN3")" ]] && ! box_is_ghost_placeholder; }; then
    rm -rf "$CALL_DIR"
    fallback_fresh "could not clear unsent text out of surface $SURFACE_REF's input box; refusing to type on top of it"
  fi
fi

# One paste, then proof it landed. cmux-paste.sh owns both halves — the same
# script first contact uses — so there is exactly one delivery path to reason
# about and one place a new landing signal has to be taught.
#
# No --wait-box: the box-presence gate above already proved a claude REPL is drawn
# on this surface. The boot wait belongs to first contact, where the REPL is
# seconds old and may not exist yet.
#
# --baseline hands over the screen those gates read. Three of the four screen-side
# landing markers are generic chrome that a PREVIOUS exchange leaves in the
# viewport of a reused surface — and reuse is the only path where that can happen —
# so confirmation must know which of them were already there. The LAST screen read
# is the one to pass: the clear (if any) has happened by then.
#
# An array, not `${CWD:+--cwd "$CWD"}`: that form word-splits, so a callee cwd
# containing a space would arrive as two arguments and the transcript path would
# be derived from half of it.
BASELINE_FILE="$CALL_DIR/screen_baseline.txt"
printf '%s' "${SCREEN3:-${SCREEN2:-$SCREEN}}" > "$BASELINE_FILE"
PASTE_ARGS=(--surface "$SURFACE_REF" --payload-file "$PAYLOAD_FILE" --call-id "$CALL_ID"
            --baseline "$BASELINE_FILE")
[[ -n "$CWD"        ]] && PASTE_ARGS+=(--cwd "$CWD")
[[ -n "$SESSION_ID" ]] && PASTE_ARGS+=(--session "$SESSION_ID")
DELIVERY_RESULT=$(bash "$SCRIPT_DIR/cmux-paste.sh" "${PASTE_ARGS[@]}" 2>/dev/null)

if [[ "$(jq -r '.delivered // false' <<<"$DELIVERY_RESULT" 2>/dev/null)" != "true" ]]; then
  DELIVERY_REASON=$(jq -r '.reason // "delivery failed with no reason"' <<<"$DELIVERY_RESULT" 2>/dev/null)
  if [[ "$(jq -r '.sent // false' <<<"$DELIVERY_RESULT" 2>/dev/null)" == "true" ]]; then
    # THE SOCKET ACCEPTED THE PASTE and we could not prove where it went. This must
    # NOT become fallback:fresh: the caller answers that by opening a new surface
    # and re-delivering the SAME prompt into a --resume of the SAME session, so a
    # payload that actually landed gets executed twice. Every other path treats
    # this exact state as a hard stop; so does this one now.
    #
    # The call dir and pending_paste.md stay put — the prompt is what the human or
    # the caller needs in order to decide, and it is the only copy left.
    jq -nc --arg reason "$DELIVERY_REASON" --arg dir "$CALL_DIR" --arg pf "$PAYLOAD_FILE" \
      '{undelivered: true, reason: $reason, call_dir: $dir, prompt_file: $pf}'
    exit 0
  fi
  # Nothing left this machine (no input box, unresolvable surface, an RPC the
  # socket refused), so a fresh surface is safe. The call dir must go:
  # wait-for-response.sh would otherwise poll a surface for a nonce that was never
  # submitted, and the caller would sit on a corpse.
  rm -rf "$CALL_DIR"
  fallback_fresh "$DELIVERY_REASON"
fi

# Delivered and confirmed: the vehicle has served its purpose and the callee's
# transcript now holds the payload. The baseline snapshot goes with it.
rm -f "$PAYLOAD_FILE" "$BASELINE_FILE"

# `retried_enter` travels with `confirmed` because the two together are the delivery's
# confidence, and a caller reading only "delivered" cannot see that this one needed a
# corrective Enter to submit at all. A run of them says the submit_key race is back
# (claude-plugins-fkgv / -y4rl), which is invisible if the field stops here.
DELIVERY_RETRIED=$(jq -r 'if .retried_enter == true then "true" else "false" end' \
  <<<"$DELIVERY_RESULT" 2>/dev/null) || DELIVERY_RETRIED=false
jq -n --arg dir "$CALL_DIR" \
  --arg confirmed "$(jq -r '.confirmed // empty' <<<"$DELIVERY_RESULT" 2>/dev/null)" \
  --argjson retried "${DELIVERY_RETRIED:-false}" \
  '{call_dir: $dir, delivery: "paste", confirmed: $confirmed, retried_enter: $retried}'
