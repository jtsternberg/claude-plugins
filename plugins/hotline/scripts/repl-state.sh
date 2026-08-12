#!/usr/bin/env bash
# =============================================================================
# REPL state: reading a live claude REPL's condition, and resolving the cmux
# address of the surface it lives in.
#
# SOURCE this, don't execute it. Several scripts need the same judgements and
# must never disagree about them:
#
#   skills/dial/scripts/cmux-paste.sh               — is this REPL ready for a
#                                                     payload, and where is it?
#   skills/dial/scripts/cmux-reuse-surface.sh       — may I speak to this REPL?
#   skills/dial/scripts/close-superseded-surface.sh — is this REPL safe to kill?
#
# The last question is strictly more dangerous than the others, and all of them
# turn on the same signals. Duplicating them is how one copy learns about a new
# spinner wording and the other doesn't — this repo has lost time to exactly that
# in the transcript parser, twice.
#
# The screen-reading functions take a captured screen as $1 and read nothing
# themselves, so the caller decides whether it wants the visible viewport or
# scrollback. cmux_surface_address is the one function here that talks to cmux.
# =============================================================================

# --- Reading the REPL's state off its rendered screen -------------------------
# The claude REPL draws its input box as a `❯`-prefixed line between two
# horizontal rules at the bottom of the screen. The transcript above it echoes
# prior user turns with the SAME glyph, so more than one candidate line is
# usually on screen. Two things disambiguate, in order of reliability:
#   1. The live box pads its glyph with a NO-BREAK SPACE (U+00A0); the transcript
#      echoes use a plain space. Verified on claude 2.1.221.
#   2. Failing that, the box is the LAST such line — it's drawn at the bottom.
# Byte escapes rather than \u so this still works under bash 3.2 (macOS system).
REPL_BOX_GLYPH=$'\xe2\x9d\xaf'   # ❯
REPL_BOX_NBSP=$'\xc2\xa0'        # the box's padding after the glyph

# Echoes whatever text is sitting in the REPL's input box ("" when it's empty).
input_box_content() {
  local screen="$1" line
  line=$(printf '%s\n' "$screen" | grep "^${REPL_BOX_GLYPH}${REPL_BOX_NBSP}" | tail -1) || true
  if [[ -z "$line" ]]; then
    line=$(printf '%s\n' "$screen" | grep "^${REPL_BOX_GLYPH}" | tail -1) || true
  fi
  [[ -z "$line" ]] && return 0
  line="${line#"$REPL_BOX_GLYPH"}"
  # Strip the padding (NBSP and/or ordinary blanks) between glyph and content.
  while :; do
    case "$line" in
      "$REPL_BOX_NBSP"*) line="${line#"$REPL_BOX_NBSP"}" ;;
      " "*)              line="${line# }" ;;
      $'\t'*)            line="${line#$'\t'}" ;;
      *)                 break ;;
    esac
  done
  # An untouched REPL renders a greyed placeholder hint INSIDE an empty box.
  # read-screen strips the colour that would distinguish it, so match its shape.
  case "$line" in
    'Try "'*) return 0 ;;
  esac
  printf '%s' "$line" | sed 's/[[:space:]]*$//'
}

# True when the screen shows a turn in flight. Two independent markers, because
# neither is dependable alone: "esc to interrupt" is absent in some versions
# (including 2.1.221), and the spinner's wording changes between releases — but
# a RUNNING spinner always carries a live elapsed-time parenthetical, e.g.
# "✶ Dilly-dallying… (5s · ↓ 124 tokens · …)", whereas the finished one does not
# ("✻ Baked for 12s"). Callers add a screen-stability check on top.
repl_looks_busy() {
  local screen="$1"
  grep -qi 'esc to interrupt' <<<"$screen" && return 0
  grep -qE '\([0-9]+s[ )·]' <<<"$screen" && return 0
  return 1
}

# The post-interrupt "what now?" state. It is not busy, but it is not accepting
# a follow-up on our terms either — anything we type becomes an answer to that
# question rather than a new turn (claude-plugins-06ws acceptance criteria).
repl_is_interrupted() {
  grep -qiE 'What should Claude do instead|Request interrupted by user' <<<"$1"
}

# True when the REPL has drawn its input box at all — i.e. the TUI is up and
# accepting keystrokes, not merely "the process started".
#
# input_box_content cannot answer this: it returns "" for an EMPTY box and ""
# for no box at all, and an empty box is the normal state of a just-booted REPL.
# Callers need the distinction because a payload delivered to a surface that has
# NOT exec'd claude does not vanish — it goes to the shell.
#
# THE NO-BREAK SPACE IS LOAD-BEARING HERE, not a nicety. This match requires the
# glyph to be followed by U+00A0, the padding claude's box draws and a shell
# prompt does not. `❯` is the default prompt character of starship, pure and
# several oh-my-zsh themes, all of which pad with an ordinary space — so a bare
# `^❯` match says "a shell prompt is on screen" just as readily as "the REPL is
# up". That is not a missed-delivery bug: `terminal.paste` with
# submit_key:"return" would type the whole work order at a shell and press
# Enter, and the shell would run it.
#
# input_box_content's fallback to a bare `^❯` (above) is safe for the opposite
# reason: there, matching a shell prompt makes it report parked text, and every
# caller treats parked text as a reason to refuse. Presence has no such
# asymmetry, so it gets the strict form only.
#
# The cost of strictness is a claude release that stops padding with NBSP: box
# presence would stop firing, and delivery would refuse with a diagnostic
# instead of proceeding. That is the correct direction to fail in.
repl_box_present() {
  grep -q "^${REPL_BOX_GLYPH}${REPL_BOX_NBSP}" <<<"$1"
}

# --- Where does a surface live? ----------------------------------------------
# Echoes "<workspace-uuid> <surface-uuid>" for a cmux surface handle.
#
# Needed by two callers with different reasons and one shared hazard. `terminal.paste`
# addresses a surface by UUID *and* wants its workspace UUID; `cmux close-surface`
# fails "Surface not found: <uuid>" without --workspace even for a surface
# read-screen reads happily in the same breath. Neither is stored anywhere, and a
# cache written by an older plugin version may hold a positional `surface:N` ref
# rather than a UUID — so both resolve through the tree, here, once.
#
# Exit codes are distinct because the callers report them differently: an
# unreadable tree is a cmux problem, an absent handle means the surface is gone.
#   0 — resolved; "workspace-uuid surface-uuid" on stdout
#   3 — the cmux tree could not be read
#   4 — the handle is not in the tree
cmux_surface_address() {
  local handle="$1" tree addr
  tree=$(cmux tree --all --json --id-format both 2>/dev/null) || return 3
  [[ -z "$tree" ]] && return 3
  # --id-format both reports each surface's stable `id` alongside its positional
  # `ref`, so one lookup serves both handle shapes. Case-insensitive on the UUID:
  # cmux emits uppercase, but a handle that has been through another tool may not
  # have survived that way.
  addr=$(jq -r --arg h "$handle" '
    .windows[]?.workspaces[]? as $ws
    | $ws.panes[]?.surfaces[]?
    | select((.id // "") == $h
             or (.ref // "") == $h
             or ((.id // "") | ascii_downcase) == ($h | ascii_downcase))
    | "\($ws.id) \(.id)"' <<<"$tree" 2>/dev/null | head -1)
  [[ -z "$addr" || "$addr" == *null* ]] && return 4
  printf '%s' "$addr"
}

# Echoes "<workspace-uuid> <surface-uuid>" for a WORKSPACE handle — the surface a
# payload should go to when the call was placed by workspace rather than by
# surface (the detached placement, which names a workspace tab and never records a
# surface).
#
# Same tree, same output shape, same exit codes as cmux_surface_address, so a
# caller can use either and pass the result on unchanged. Both live here because
# this file is where tree reading is centralised: dial.sh grew its own inline copy
# of this walk, and a second reader of the same JSON is precisely the drift this
# repo has already paid for twice in the transcript parser.
#
# selected_surface_id is preferred (it is the tab the user is looking at) with the
# pane's first surface as the fallback, because a tree that reports surfaces
# without a selection still has exactly one place a fresh launch can be.
#   0 — resolved; "workspace-uuid surface-uuid" on stdout
#   3 — the cmux tree could not be read
#   4 — the workspace is not in the tree, or holds no surface
cmux_workspace_current_surface() {
  local handle="$1" tree addr
  tree=$(cmux tree --all --json --id-format both 2>/dev/null) || return 3
  [[ -z "$tree" ]] && return 3
  addr=$(jq -r --arg w "$handle" '
    .windows[]?.workspaces[]?
    | select((.ref // "") == $w
             or (.id // "") == $w
             or ((.id // "") | ascii_downcase) == ($w | ascii_downcase))
    | . as $ws
    | $ws.panes[]?
    | (.selected_surface_id // .surfaces[0].id // empty) as $s
    | "\($ws.id) \($s)"' <<<"$tree" 2>/dev/null | head -1)
  [[ -z "$addr" || "$addr" == *null* ]] && return 4
  printf '%s' "$addr"
}
