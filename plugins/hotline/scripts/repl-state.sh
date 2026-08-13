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

# --- Boot-wait budget --------------------------------------------------------
# ONE definition of how long we wait for a callee's REPL to become usable.
#
# wait-for-session.sh waits for the REPL to exist; cmux-paste.sh waits for its
# input box to be drawn. Same event, so the same budget — and it lived in two
# places with two different values, so the documented 60s default and the actual
# 20s box wait disagreed.
HOTLINE_BOOT_TIMEOUT_CMUX="${HOTLINE_BOOT_TIMEOUT_CMUX:-60}"
HOTLINE_BOOT_TIMEOUT_HEADLESS="${HOTLINE_BOOT_TIMEOUT_HEADLESS:-30}"

# --- The per-call nonce ------------------------------------------------------
# Every hotline delivery carries a [CALL_ID: <nonce>] the receiver echoes back in
# its STATUS lines. wait-for-response.sh correlates on it, delivery confirmation
# proves itself with it, and superseded-surface cleanup uses it as identity proof.
#
# Both halves live here because all three delivery paths need them identically and
# the copies had already drifted: two of them split the prompt on the first space
# ANYWHERE in it, so a multi-line follow-up beginning with "/" got the nonce
# spliced into the middle of its second line.
hotline_mint_call_id() {
  openssl rand -hex 8 2>/dev/null \
    || od -A n -N 8 -t x1 /dev/urandom 2>/dev/null | tr -d ' \n' \
    || date +%s%N | sha256sum 2>/dev/null | cut -c1-16
}

# hotline_inject_call_id <nonce> <prompt> → the prompt with the nonce in it.
#
# Two placements, and which one applies is not a style choice:
#
#   Slash-command prompt → INLINE, immediately after the command token. claude
#     parses a slash command only when the input STARTS with it, and only while it
#     is still literal `/…` text: a header line above `/hotline:hotline-ringing`,
#     or a paste large enough that CC collapses the whole buffer to a
#     `[Pasted text +N lines]` placeholder, both leave the input not starting with
#     `/` and turn the invocation into plain text. Keeping the nonce inline is only
#     half of what protects the slash; the other half is delivery — cmux-paste.sh
#     sends first contact as two pastes so the invocation line renders verbatim
#     while the body's placeholder expands inside the command args (claude-plugins-pmgb).
#
#   Anything else → its OWN leading line. wait-for-response.sh matches the nonce
#     on screen, and at the start of a line it can never be broken across a
#     rendered line wrap the way a mid-line match could be. Safe because the paste
#     arrives as one atomic bracketed paste (verified live: 76-line payload, one
#     user turn, nonce line intact).
#
# "Slash command" is judged on the FIRST TOKEN OF THE FIRST LINE, and only when
# that token looks like a command name. `/Users/JT/Code/x` starts with a slash and
# is not one — the character class excludes `/` after the first character, so a
# path falls through to the header-line form instead of having the nonce spliced
# after its first directory component.
#
# ONE predicate owns that judgement because two callers must agree on it forever:
# hotline_inject_call_id places the nonce INLINE only for a slash command, and
# cmux-paste.sh splits delivery into two pastes only for a slash command. The
# inline-nonce placement and the split-paste delivery are the same design invariant
# seen from two ends — a regex that drifted between them would break it silently.
# ("Extract the helper the moment a second caller appears.")
hotline_is_slash_command_first_line() {
  local first_line="$1" token
  token="${first_line%%[[:space:]]*}"
  [[ "$token" =~ ^/[A-Za-z0-9][A-Za-z0-9:._-]*$ ]]
}

hotline_inject_call_id() {
  local nonce="$1" prompt="$2" first_line rest_lines token remainder
  first_line="${prompt%%$'\n'*}"
  token="${first_line%%[[:space:]]*}"
  if hotline_is_slash_command_first_line "$first_line"; then
    # Everything after the command token, first line only; the rest is untouched.
    remainder="${first_line#"$token"}"
    if [[ "$prompt" == *$'\n'* ]]; then
      rest_lines="${prompt#*$'\n'}"
      printf '%s [CALL_ID: %s]%s\n%s' "$token" "$nonce" "$remainder" "$rest_lines"
    else
      printf '%s [CALL_ID: %s]%s' "$token" "$nonce" "$remainder"
    fi
  else
    printf '[CALL_ID: %s]\n%s' "$nonce" "$prompt"
  fi
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
