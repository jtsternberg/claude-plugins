#!/usr/bin/env bash
# =============================================================================
# Close a superseded hotline surface.
#
# When a follow-up cannot reuse the surface its session was living in, it opens a
# new one and resumes the session there. `claude --resume` takes the session over,
# so the OLD surface is left holding a REPL that will never be spoken to again —
# and nothing used to close it, so a long exchange accumulated one dead tab per
# turn.
#
# Closing a surface KILLS its foreground process (verified: a `sleep 400` in the
# closed surface was reaped). So this refuses unless all of these hold:
#
#   1. The handle is a stable UUID, not a positional `surface:N` ref.
#   2. The surface is still readable.
#   3. Its scrollback carries --expect-call-id, the nonce of the exchange it
#      hosted. This is the identity proof: it distinguishes "the pane hotline was
#      using" from "a pane the user has since repurposed". Without it a recycled
#      handle could point anywhere.
#   4. A claude REPL is still drawn there at all. If claude has exited, the
#      foreground process this would kill is a SHELL — and the pane still carries
#      our nonce in its scrollback, so every other check happily agrees.
#   5. Its REPL is not mid-turn — no in-flight markers, and a screen that has not
#      changed across a short window.
#   6. It is not sitting in the post-interrupt "what should Claude do instead?"
#      state, where a human is mid-decision.
#   7. Its input box holds no unsent text. Reuse refuses to type over parked
#      text; closing would delete it, which is worse. A box holding Claude Code's
#      PLACEHOLDER — the ghost suggested prompt, the queued-messages hint,
#      `Message @agent…` — is an empty box wearing text and does not count; that
#      judgement comes from the styled render grid and fails closed.
#
# Every refusal is a reason string, never an error: cleanup failing to run must
# not fail the dial that triggered it.
#
# Usage:
#   close-superseded-surface.sh --surface <handle> --expect-call-id <nonce>
#                               [--settle <seconds>]
#   # → {"closed": true,  "surface": "...", "workspace": "..."}
#   # → {"closed": false, "reason": "..."}
#
# HOTLINE_CLOSE_SUPERSEDED=0 disables cleanup entirely (reason: disabled).
#
# NEVER target a surface by tty: cmux recycles tty numbers, so a stale tty can
# name a completely different pane by the time this runs. Handles only.
#
# `cmux close-surface` needs BOTH --workspace and --surface even when given a
# surface UUID: with --surface alone it fails "Surface not found: <uuid>" for a
# surface that read-screen reads happily in the same breath (verified live, cmux
# 0.64.20 — the error means "not resolvable in the current workspace context").
# The workspace is resolved from the tree rather than stored, so this works for a
# cache written before the workspace was ever recorded.
# =============================================================================
set -uo pipefail

if [[ "${1:-}" == "--help" ]]; then
  sed -n '2,/^# =\{10,\}$/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^=\{10,\}$'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/repl-state.sh
source "$SCRIPT_DIR/../../../scripts/repl-state.sh"

SURFACE_REF=""
EXPECT_CALL_ID=""
SETTLE="${HOTLINE_CLEANUP_SETTLE:-0.6}"
SCROLLBACK_LINES="${HOTLINE_CLEANUP_SCROLLBACK_LINES:-2000}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --surface)         SURFACE_REF="$2";    shift 2 ;;
    --expect-call-id)  EXPECT_CALL_ID="$2"; shift 2 ;;
    --settle)          SETTLE="$2";         shift 2 ;;
    *)                 shift ;;
  esac
done

refuse() { jq -nc --arg reason "$1" '{closed: false, reason: $reason}'; exit 0; }

[[ "${HOTLINE_CLOSE_SUPERSEDED:-1}" == "0" ]] && refuse "disabled"
[[ -z "$SURFACE_REF" ]]    && refuse "no surface given"
# Refusing here rather than closing on a weaker signal is the whole safety
# argument: with no nonce there is nothing tying this handle to our exchange.
[[ -z "$EXPECT_CALL_ID" ]] && refuse "no prior call_id recorded for this surface, so its identity cannot be proven"

# UUID handles only. The nonce-in-scrollback proof below is decisive for a UUID,
# which names one surface for that surface's whole life — but a positional
# `surface:N` ref names whatever currently sits in slot N, and slots renumber
# when tabs move or siblings close. That matters more here than anywhere else:
# the replacement surface resumed the SAME session, so its scrollback replays the
# SAME prior nonce. A repositioned positional ref could therefore pass the
# identity check while pointing at the very surface we just delivered into.
# Reuse still accepts positional refs from old caches; closing never will.
if [[ ! "$SURFACE_REF" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  refuse "positional-ref-unsafe: '$SURFACE_REF' is not a stable UUID, and a repositioned ref could name the replacement surface rather than the superseded one"
fi

# Identity and liveness ask two different questions of the same capture. Identity
# (is our nonce in here?) wants HISTORY — the nonce was typed in the previous
# exchange and has almost certainly scrolled out of the live screen. Liveness
# (busy? interrupted? box drawn?) wants the LIVE SCREEN ONLY, because those markers
# are drawn at the bottom and a full scrollback still holds `(12s ·` parentheticals
# from turns that ended long ago.
#
# BOTH READS ARE SCROLL-IMMUNE, and on this path that is the difference between a
# safe no-op and destroying someone's work. A plain `cmux read-screen` returns what
# the surface is CURRENTLY SHOWING, so a user scrolled up inside the pane froze the
# capture — and the "screen unchanged ⇒ idle" test below cannot fail against a
# frozen capture, because it never differs from itself. This script CLOSES the
# surface it judges, killing the foreground process, so that test passing spuriously
# meant closing a pane that was mid-turn (claude-plugins-r465.6). `--scrollback
# --lines N` returns the live tail regardless of scroll position (repl-state.sh).
read_live() {
  cmux_read_live "superseded-surface cleanup of $SURFACE_REF" --surface "$SURFACE_REF" \
    "$SCROLLBACK_LINES"
}

if ! HIST=$(read_live) || [[ -z "$HIST" ]]; then
  refuse "surface $SURFACE_REF is gone or unreadable — nothing to close"
fi

if ! printf '%s' "$HIST" | grep -qF "$EXPECT_CALL_ID"; then
  refuse "surface $SURFACE_REF does not carry call_id $EXPECT_CALL_ID in its scrollback; it is not provably the superseded exchange"
fi

if ! RAW=$(read_live) || [[ -z "$RAW" ]]; then
  refuse "surface $SURFACE_REF became unreadable while checking whether its REPL was idle"
fi
SCREEN=$(repl_screen_tail "$RAW")

# --- Is there still a REPL in there at all? ----------------------------------
# FIRST, before any other liveness judgement. Closing a surface KILLS its
# foreground process, and if the claude that used to live here has exited, that
# process is a SHELL — quite possibly one the human is now using, in a pane that
# still carries our nonce in its scrollback from when it was ours.
#
# Nothing below catches it: the nonce check passes (the scrollback is unchanged),
# repl_is_interrupted looks for interrupt wording, repl_looks_busy for a spinner,
# and an idle shell prompt reads as an empty box. Every gate says "safe to close".
#
# Checking it first also fixes a second, quieter failure: input_box_content falls
# back to a bare `^❯` line, so a themed shell prompt (starship, pure) gets reported
# as parked input and the surface is skipped forever with a misleading reason.
if ! repl_box_present "$SCREEN"; then
  refuse "no-repl-box: surface $SURFACE_REF shows no claude input box (a ❯ padded with U+00A0), so its REPL has exited — what would be killed is a shell, possibly one in use"
fi

repl_is_interrupted "$SCREEN" && \
  refuse "surface $SURFACE_REF is in the post-interrupt state; a human is mid-decision there"

repl_looks_busy "$SCREEN" && \
  refuse "surface $SURFACE_REF has a turn in flight; closing it would destroy that work"

# --- Resolving this surface's address, once ----------------------------------
# Two things want it: the placeholder check just below (its RPC addresses a surface
# by workspace + surface UUID) and the close call at the bottom (cmux needs
# --workspace even when handed a surface UUID — see the header). Only SURFACE_REF is
# in scope; the workspace has to come off the tree. One walk, memoised, so the two
# callers cannot become two reads — and so this stays the single tree reader the
# paste path shares via repl-state.sh.
#
# The memo carries the STATUS as well as the address, because the refusal wording
# below distinguishes "the tree could not be read" from "the surface is not in it".
#
# It publishes into $ADDR rather than echoing: a resolver called as $(...) runs in a
# subshell, so its memo — and its status — would die with that subshell and every
# caller would walk the tree again.
ADDR_TRIED=false
ADDR=""
ADDR_STATUS=0
resolve_surface_address() {
  if ! $ADDR_TRIED; then
    ADDR_TRIED=true
    ADDR=$(cmux_surface_address "$SURFACE_REF")
    ADDR_STATUS=$?
  fi
  return $ADDR_STATUS
}

# --- Is that "parked text" actually Claude Code's PLACEHOLDER? ---------------
# input_box_content reads plain text, where a placeholder and unsent input are
# byte-identical, so ANY non-empty box line arrives below as parked text. Claude Code
# draws its ghost suggested prompt, its queued-messages hint and `Message @agent…`
# from a placeholder prop while the input's VALUE is empty — nothing is at risk, and
# a superseded surface showing one was skipped every time, so its dead pane
# accumulated behind a long conversation (claude-plugins-8vuf).
#
# input_box_is_placeholder (repl-state.sh) answers from the styled render grid, where
# a placeholder is dim, and FAILS CLOSED: an RPC error, a cmux without
# terminal.render_grid.v1, an unresolvable address, no box row, one scrap of non-dim
# content — all read as real text.
#
# THAT DIRECTION IS LOAD-BEARING HERE IN A WAY IT IS NOT AT THE REUSE GATE, because
# this path is DESTRUCTIVE. Reuse pays for an unproven placeholder with one extra
# surface; here the cost of getting it wrong the other way is a human's half-typed
# thought deleted with the pane it was sitting in. Ambiguity means real text means
# KEEP THE SURFACE — the exact behavior this check had before it existed. Nothing
# below may be relaxed to make a close more likely.
box_is_ghost_placeholder() {
  local ws surf
  resolve_surface_address || return 1
  ws="${ADDR%% *}"; surf="${ADDR##* }"
  [[ -n "$ws" && -n "$surf" ]] || return 1
  input_box_is_placeholder "$ws" "$surf"
}

# Unsent text in the input box is almost always a human's half-typed thought.
# Reuse refuses to type on top of it; closing the surface would delete it
# outright, which is strictly worse — an idle REPL is not the same as an
# abandoned one.
PARKED=$(input_box_content "$SCREEN")
# A proven placeholder is an empty box, so it is no reason to keep the surface.
if [[ -n "$PARKED" ]] && box_is_ghost_placeholder; then
  PARKED=""
fi
[[ -n "$PARKED" ]] && \
  refuse "parked-input: surface $SURFACE_REF holds unsent text in its input box, which closing would discard"

# A spinner wording we don't recognise still moves the screen. Bias to "busy":
# a needless skip costs one stale tab, a wrong close destroys a running turn.
sleep "$SETTLE"
if ! RAW2=$(read_live) || [[ -z "$RAW2" ]]; then
  refuse "surface $SURFACE_REF became unreadable while confirming its REPL was idle"
fi
SCREEN2=$(repl_screen_tail "$RAW2")
if [[ "$SCREEN2" != "$SCREEN" ]]; then
  refuse "surface $SURFACE_REF's screen is still changing, so its REPL is not provably idle"
fi
repl_looks_busy "$SCREEN2" && \
  refuse "surface $SURFACE_REF started a turn while we were checking"

# Resolve the owning workspace. cmux needs it (see the header) and we never
# stored it. Shared with the paste path via repl-state.sh so one tree lookup
# serves both and neither can drift from the other's idea of a surface handle.
# Memoised above, so a case that already resolved it for the placeholder check
# re-reads nothing — and the refusals below still tell the two failures apart.
if ! resolve_surface_address; then
  case $ADDR_STATUS in
    3) refuse "could not read the cmux tree to resolve surface $SURFACE_REF's workspace" ;;
    *) refuse "surface $SURFACE_REF is not in the cmux tree, so its workspace is unknown" ;;
  esac
fi
WS="${ADDR%% *}"

# cmux itself refuses to close the last surface in a workspace
# ("invalid_state: Cannot close the last surface"), which bounds the worst case
# of a wrong decision here to a no-op rather than a destroyed workspace.
if ! CLOSE_OUT=$(cmux close-surface --workspace "$WS" --surface "$SURFACE_REF" 2>&1); then
  refuse "cmux close-surface refused: $(printf '%s' "$CLOSE_OUT" | tr '\n\r\t' '   ' | cut -c1-140)"
fi

jq -nc --arg s "$SURFACE_REF" --arg w "$WS" \
  '{closed: true, surface: $s, workspace: $w}'
