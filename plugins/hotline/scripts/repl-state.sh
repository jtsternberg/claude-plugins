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
# The screen-reading PREDICATES take a captured screen as $1 and read nothing
# themselves. The CAPTURE, though, is not the caller's choice: a plain
# `cmux read-screen` follows the user's scroll, so all of it goes through
# cmux_read_live below. cmux_surface_address and input_box_is_placeholder are the
# other two functions here that talk to cmux — the latter because the question it
# answers (placeholder or unsent input?) is not present in a plain-text screen at
# all.
# =============================================================================

# --- Addressing a cmux surface: never let cmux choose one for us ---------------
# cmux resolves a MISSING or unparseable target to the FOCUSED surface instead of
# refusing the call. Three incidents on 2026-08-26 came out of that one rule:
# `cmux send --surface ""` typed probe text into a bystander's live REPL (twice),
# and a `terminal.replay` whose params used camelCase keys returned ok:true
# carrying the FOCUSED surface's grid (claude-plugins-r465.9). So an empty handle
# never means "no target" here — it means "whatever the user is looking at".
#
# cmux_handle_ok <what> <handle> — 0 when the handle is safe to address.
cmux_handle_ok() {
  [[ -n "${2:-}" ]] && return 0
  printf 'hotline: refusing a cmux call for %s — its target handle is empty, and cmux resolves a missing target to the FOCUSED surface rather than failing (claude-plugins-r465.9).\n' \
    "${1:-<unnamed call>}" >&2
  return 1
}

# --- Scroll-immune screen reads ----------------------------------------------
# A plain `cmux read-screen` returns what the surface is CURRENTLY SHOWING, so a
# user who has scrolled the pane up hands us a frozen capture — and "the screen
# did not change" then reads as "the REPL is idle", which is how a destructive
# cleanup could close a surface mid-turn. `--scrollback --lines N` returns the
# live tail regardless of scroll position (verified on cmux 0.64.22 against a
# pane scrolled to ~line 225, where the plain form returned the stale viewport),
# so every read in the dial transport takes that form.
#
# Do NOT reach for the render grid's `scrolled_rows` to detect scroll instead: it
# is forced to 0 whenever the reply is `full:true`, and every reply is
# (MobileTerminalRenderGrid.swift:212). It is structurally always 0.
#
# TWO WIDTHS, because two different questions get asked of a capture. IDENTITY
# questions (is our nonce in here?) want history. STATE questions (is the input
# box drawn? is a turn in flight?) want the LIVE SCREEN only — a 400-line
# scrollback still holds `(12s ·` elapsed parentheticals and `❯` echoes from
# turns that ended long ago, and matching those reports a busy REPL that is
# actually idle, which bounces every follow-up to a fresh surface.
HOTLINE_READ_LINES="${HOTLINE_READ_LINES:-400}"
#
# THE TAIL IS THE PANE'S OWN HEIGHT WHERE IT CAN BE MEASURED (cmux_screen_rows
# below), and 60 rows where it cannot. 60 is a stand-in for "about one pane
# height" — live panes measured on this machine ranged 13 to 83 occupied rows, so
# it is simultaneously too wide on a short pane and too narrow on a tall one.
# Wider is the unsafe direction — a previous claude session in the same surface
# leaves NBSP-padded box renders in the history, and repl_box_present matching one
# reports a live REPL where a shell is now running, which is how a work order gets
# pasted at a shell and RUN line by line. Narrower only drops rows that are
# genuinely on screen, which costs screen-side confirmation sensitivity and fails
# safe (undelivered/sent:true, never a false success).
#
# Set the env var and the measurement is skipped entirely: an explicit width is an
# operator's decision, and silently overriding it would make the knob a lie.
HOTLINE_SCREEN_TAIL_EXPLICIT="${HOTLINE_SCREEN_TAIL_LINES:+1}"
HOTLINE_SCREEN_TAIL_LINES="${HOTLINE_SCREEN_TAIL_LINES:-60}"
#
# AND ONE TIGHTER WINDOW FOR THE BOX GATES, because "about one pane height" is not
# tight enough for the one predicate whose false positive is destructive.
# repl_box_present matches ANYWHERE in the window it is handed, and panes are not
# all one size (measured on this machine: 13, 62, 71, 82, 83 occupied rows), so on
# any pane shorter than the tail the rest of that window is HISTORY. A previous claude
# session in the same surface leaves its NBSP-padded box render there, and matching
# that reports a live REPL where a shell is now running — `terminal.paste` with
# submit_key:"return" then types the whole work order at that shell and the shell
# RUNS it.
#
# 12 rows is what the box actually needs: claude draws its box at the bottom, with
# only a rule and one or two hint lines under it (a live capture of an idle REPL put
# the box 4 rows from the end). The boot wait has used this width since the fast-fail
# went in; the reuse and delivery box gates take the same one so the three places
# that ask "is a REPL drawn here?" cannot disagree about how far back to believe it.
# close-superseded-surface.sh deliberately keeps the WIDE window: there, seeing a box
# that is no longer live makes it REFUSE to close, which is the safe direction.
#
# THIS ONE KNOB SPANS SITES WHOSE FAILURE DIRECTIONS ARE OPPOSITE, so it is a floor
# at some of them and a ceiling at others, and repl_box_tail_lines below is the only
# place allowed to narrow it:
#   boot wait (wait-for-session.sh), cmux-paste.sh's --wait-box loop — the REPL is
#     still COMING UP and the screen is growing under us. Too small there is a HARD
#     TIMEOUT on a boot that was fine, so these keep the constant and never measure.
#   the two delivery box gates on an EXISTING REPL (cmux-reuse-surface.sh, and
#     cmux-paste.sh's final gate) — the measurement is contemporaneous, and too
#     small only costs a fresh surface. These narrow to the pane's real height.
HOTLINE_BOX_TAIL_LINES="${HOTLINE_BOX_TAIL_LINES:-12}"

# cmux_read_live <what> <flag> <handle> [lines] — the live tail, on stdout.
#   0 — read succeeded    1 — cmux could not read it    2 — refused (empty handle)
cmux_read_live() {
  local what="$1" flag="$2" handle="$3" lines="${4:-$HOTLINE_READ_LINES}"
  cmux_handle_ok "$what" "$handle" || return 2
  cmux read-screen "$flag" "$handle" --scrollback --lines "$lines" 2>/dev/null || return 1
}

# --- How tall is the pane, exactly? ------------------------------------------
# cmux_screen_rows <what> <flag> <handle> — the number of rows the surface is
# showing right now, on stdout; nothing (and non-zero) when it cannot be measured.
#
# THE ONE BARE `cmux read-screen` IN THE TRANSPORT, and it is not the bug the rest
# of this file exists to prevent. A bare read returns what the surface is CURRENTLY
# SHOWING, so its CONTENT follows the user's scroll — which is why every read that
# is judged goes through cmux_read_live instead. Only its LINE COUNT is used here,
# and a scrolled viewport has exactly as many rows as an unscrolled one, so scroll
# immunity is untouched.
#
# Verified live on cmux 0.64.22, four panes of different heights: a bare read
# returns the showing rows with trailing blanks stripped, and `tail -n <that count>`
# of a `--scrollback --lines 9999` read of the same surface is byte-identical to it
# (62/239, 13/13, 83/310, 71/1522 rows). That equality is the whole contract: this
# number is the right width for tailing a TEXT capture.
#
# DO NOT SUBSTITUTE THE RENDER GRID'S `rows`. `terminal.replay --anchor screen`
# reports the pane height INCLUDING trailing blank rows (84 for all three of the
# panes above), while a text capture has those stripped — so tailing that many
# lines reaches 20+ rows into history, i.e. the exact failure this measurement is
# meant to end.
#
# `grep -c ''` rather than `wc -l` because tail counts a final line with no
# trailing newline as a line and wc does not; the counter has to agree with the
# consumer.
#
# MEMOIZED PER HANDLE for the life of the process: the callers poll (cmux-paste's
# box loop reads every 0.4s), and one extra cmux call per invocation is the budget
# this was designed to fit. A pane does not change height mid-call, and where the
# SCREEN is still growing the constant is used instead — see HOTLINE_BOX_TAIL_LINES.
_HOTLINE_ROWS_KEY=""
_HOTLINE_ROWS_VAL=""
cmux_screen_rows() {
  local what="$1" flag="$2" handle="$3" key rows
  [[ -n "${HOTLINE_SCREEN_TAIL_EXPLICIT:-}" ]] && return 1
  cmux_handle_ok "$what" "$handle" || return 2
  key="$flag $handle"
  if [[ "$key" != "$_HOTLINE_ROWS_KEY" ]]; then
    _HOTLINE_ROWS_KEY="$key"
    _HOTLINE_ROWS_VAL=""
    rows=$(cmux read-screen "$flag" "$handle" 2>/dev/null | grep -c '' || true)
    [[ "$rows" =~ ^[0-9]+$ ]] && [[ "$rows" -gt 0 ]] && _HOTLINE_ROWS_VAL="$rows"
  fi
  [[ -z "$_HOTLINE_ROWS_VAL" ]] && return 1
  printf '%s' "$_HOTLINE_ROWS_VAL"
}

# cmux_screen_rows_forget — drop the memo, so the next call measures again.
#
# For the one thing that genuinely changes a pane's row count mid-call: CONTENT
# ARRIVING. A screen that is not yet full GROWS as output is appended, so a height
# measured before a paste is a lower bound on the screen after it — and a window
# sized to the smaller number would drop the newest rows, which is exactly where a
# just-submitted turn's echo lives. Re-measuring after delivery keeps every window
# reaching zero rows into history, which is what makes "this marker was not on the
# pre-paste screen" mean fresh rather than merely out-of-window.
cmux_screen_rows_forget() {
  _HOTLINE_ROWS_KEY=""
  _HOTLINE_ROWS_VAL=""
}

# repl_screen_tail_lines [rows] — how many rows of a capture are "the live screen".
# The measurement when there is one, the constant when there is not, so an
# unmeasurable pane keeps exactly today's behavior instead of a guess.
repl_screen_tail_lines() {
  local rows="${1:-}"
  if [[ "$rows" =~ ^[0-9]+$ ]] && [[ "$rows" -gt 0 ]]; then
    printf '%s' "$rows"
  else
    printf '%s' "$HOTLINE_SCREEN_TAIL_LINES"
  fi
}

# repl_box_tail_lines [rows] — the bottom-of-screen window a box gate may believe.
# NEVER WIDER than HOTLINE_BOX_TAIL_LINES (that is the point of the tight window)
# and never wider than the live screen either: on a pane showing fewer rows than
# that constant, the rest of the window is HISTORY, where a dead REPL's last frame
# still holds its NBSP-padded box render with the shell prompt that replaced it
# underneath — and believing that hands a work order to the shell. So: the smaller
# of the two. Only the gates judging an EXISTING REPL pass rows; see the constant.
repl_box_tail_lines() {
  local rows="${1:-}" box="$HOTLINE_BOX_TAIL_LINES"
  if [[ "$rows" =~ ^[0-9]+$ ]] && [[ "$rows" -gt 0 ]] && [[ "$rows" -lt "$box" ]]; then
    printf '%s' "$rows"
  else
    printf '%s' "$box"
  fi
}

# repl_screen_tail <capture> [lines] — the live screen rows out of a scroll-immune
# read. Pass a tighter count where a wider window would be actively wrong (the boot
# wait does: on a surface a previous REPL has been through, an old NBSP-padded box
# render 20 rows up would report a REPL that exited).
repl_screen_tail() {
  printf '%s\n' "$1" | tail -n "${2:-$HOTLINE_SCREEN_TAIL_LINES}"
}

# --- Sending: line hygiene and a refusal on an empty handle -------------------
# cmux_send_live <what> <flag> <handle> <text...>
cmux_send_live() {
  local what="$1" flag="$2" handle="$3"
  shift 3
  cmux_handle_ok "$what" "$handle" || return 2
  cmux send "$flag" "$handle" "$@"
}

# A cmux surface's input line is not ours alone — the user's keystrokes land
# there too. On 2026-08-26 three stray characters arrived ahead of a launch
# command and the surface ran `rkebash /tmp/…`, so the callee never booted and
# the caller burned its whole 60s budget on a diagnostic that blamed
# --allowedTools. Ctrl-U (0x15) kills the line in every shell line editor, so the
# command we send is the whole command.
#
# Raw byte through the TEXT path, exactly like the Ctrl-C clear in
# cmux-reuse-surface.sh: `send-key ctrl+u` does not reach the program, the same
# way `send-key ctrl+c` does not.
cmux_clear_input_line() {
  local what="$1" flag="$2" handle="$3"
  cmux_handle_ok "$what" "$handle" || return 2
  cmux send "$flag" "$handle" $'\025' >/dev/null 2>&1 || true
  return 0
}

# repl_launch_error_line <screen> [launch-script-path] — echoes the shell
# diagnostic that says our launch line was MANGLED, so the boot wait can fail
# fast with the real text instead of timing out and guessing.
#
# Scoped to errors that name OUR line, not any error the surface's rc files print
# on startup: the mangle PREPENDS the user's keystrokes to the command, so the
# offending token still contains `bash` (or the script's own name) —
# "zsh: command not found: rkebash". A broken `.zshrc` complaining about `pyenv`
# is not our problem and must not fail the boot.
#
# THE MATCH IS ON THE OFFENDING TOKEN, not on the line. "Somewhere on this line
# there is a not-found phrase, and somewhere on this line there is the word bash"
# also describes a claude tool result that shells out — `bash: /tmp/x: No such file
# or directory` echoed inside a Bash(...) block, in a REPL that is up and healthy —
# and treating that as a refused launch line fails a boot that already happened. So
# the token carrying `bash` (or the script's basename) has to sit immediately beside
# the phrase, in either order, which is how the two shells word it:
#   zsh   → "zsh: command not found: rkebash"        (phrase, then token)
#   bash  → "bash: rkebash: command not found"       (token, then phrase)
#   either→ "bash: /tmp/…/hotline-launch-abc: No such file or directory"
# `bash: pyenv: command not found` has `bash` only as the SHELL'S OWN NAME, in front
# of a token that is not ours, and no longer matches.
#
# The `|| true` is required, not defensive: a caller running under `set -o pipefail`
# would take a no-match grep (the normal case — most screens hold no error) as a
# failed command and die there.
#
# repl_launch_error_lines echoes EVERY such diagnostic. The boot wait counts them,
# because its one-shot retry has to tell a NEW refusal from the one it already
# retried on: after Ctrl-U + re-send, the old error line is still on screen and
# still matches, and reading it a second time abandoned a surface where claude was
# in fact booting (claude-plugins-r465.7 review).
repl_launch_error_lines() {
  local screen="$1" script="${2:-}" base="" tok="bash" phrase
  [[ -n "$script" ]] && base="$(basename "$script")"
  [[ -n "$base" ]] && tok="bash|$base"
  phrase='command not found|no such file or directory'
  printf '%s\n' "$screen" \
    | grep -aiE "($phrase)[[:space:]]*:[[:space:]]*[^[:space:]]*($tok)|:[[:space:]]*[^[:space:]]*($tok)[^[:space:]]*[[:space:]]*:[[:space:]]*($phrase)" \
    || true
}

# The most recent one, which is the text a diagnostic quotes.
repl_launch_error_line() {
  repl_launch_error_lines "$@" | tail -1 || true
}

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

# --- Placeholder or unsent input? --------------------------------------------
# input_box_is_placeholder <workspace-uuid> <surface-uuid>
#
# True when the text visible in the box is Claude Code's PLACEHOLDER rather than
# something a human (or a previous paste) left unsent (claude-plugins-ff6g).
#
# input_box_content cannot answer this and never will: `cmux read-screen` is plain
# text, and placeholder and input are byte-identical there. Claude Code renders the
# placeholder DIM (SGR 2) and real input at normal intensity, so the discriminator
# is the attribute the text read throws away. The cmux RPC `terminal.replay`
# (capability `terminal.render_grid.v1`) keeps it: row_spans carry a style_id into a
# styles table with `faint`, `inverse` and `bold`, plus the cursor's row/column.
#
# A VISIBLE PLACEHOLDER PROVES THE INPUT VALUE IS EMPTY — the TUI draws it only
# when `value.length === 0` — which is why this is worth an RPC. There are at least
# three placeholder strings (`Try "<example>"` on a virgin session, `Press up to
# edit queued messages`, `Message @<agent>…`) and a suggested-prompt ghost is
# arbitrary text, so no shape match can cover them; the dim attribute covers all of
# them at once.
#
# THE FENCE IS ASYMMETRIC, so this predicate FAILS CLOSED. A false negative costs
# one fresh surface. A false positive pastes a work order on top of a human's
# half-typed words. So: an RPC error, a cmux without `terminal.render_grid.v1`,
# unparseable JSON, no box row on the grid, or one scrap of non-dim content all
# return false — "treat it as real text", which is the behavior a caller has
# without this predicate at all. Ambiguity is always real text.
#
# The one tolerated exception to "every span is faint" is a SINGLE non-faint
# `inverse` cell at the cursor column: a focused terminal renders the placeholder's
# first character as the block cursor instead of dim. Real input never renders dim,
# so the tolerance cannot turn typed text into a placeholder.
input_box_is_placeholder() {
  local ws="$1" surf="$2" here rpc grid
  [[ -z "$ws" || -z "$surf" ]] && return 1
  command -v python3 >/dev/null 2>&1 || return 1
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  rpc="$here/cmux-rpc.py"
  [[ -f "$rpc" ]] || return 1
  # A cmux that cannot render a styled grid cannot answer the question. Checked
  # against the capability list rather than inferred from an empty reply, so an
  # older cmux degrades to today's behavior instead of to a guess.
  cmux capabilities 2>/dev/null | grep -qF 'terminal.render_grid.v1' || return 1
  # anchor:"screen" so a scrolled pane does not answer with a frozen viewport.
  # `terminal.replay`'s default anchor is "viewport", which FOLLOWS the user's
  # scroll — the box row would then be a scrolled-up echo, or absent. anchor
  # "screen" is scroll-immune by contract (MobileTerminalRenderGridAnchorRegistry
  # .swift:11-14, "primary-screen scrolling never round-trips") and confirmed live
  # on cmux 0.64.22. Requested only when cmux advertises it, so an older cmux
  # keeps today's behavior instead of getting an unknown param.
  # `|| true` because a cmux WITHOUT the capability makes this list return 1, and a
  # caller running under `set -e` outside a conditional would die on it.
  local anchor=()
  cmux capabilities 2>/dev/null \
    | grep -qF 'terminal.render_grid.screen_anchor.v1' && anchor=(--anchor screen) || true
  # cmux-rpc.py sends snake_case params only and exits 4 when the reply's
  # surface_id is not the surface we asked for; both matter here, because a
  # camelCase key or a dropped target returns the FOCUSED surface's grid with
  # ok:true and we would judge a bystander's input box (claude-plugins-r465.9).
  grid=$(python3 "$rpc" --method terminal.replay --workspace "$ws" --surface "$surf" \
    ${anchor[@]+"${anchor[@]}"} 2>/dev/null) || return 1
  [[ -z "$grid" ]] && return 1
  # Exit 0 only for "every non-blank span after the box glyph is dim".
  printf '%s' "$grid" | python3 -c '
import json, sys

# Escapes, not literals: the NO-BREAK SPACE below is one keystroke away from an
# ordinary space and nothing downstream would notice the swap.
GLYPH = "\u276f"   # the box glyph
NBSP = "\u00a0"    # the padding the box draws after it
PREFIX = GLYPH + NBSP

def nope():
    sys.exit(1)

try:
    doc = json.load(sys.stdin)
except Exception:
    nope()
if not isinstance(doc, dict) or doc.get("ok") is not True:
    nope()
grid = (doc.get("result") or {}).get("render_grid")
if not isinstance(grid, dict):
    nope()
spans = grid.get("row_spans")
styles = grid.get("styles")
if not isinstance(spans, list):
    nope()
# A list of {"id": N, ...} live; a mapping is accepted so a shape change degrades
# to a lookup miss (which fails closed) rather than to a crash.
table = {}
if isinstance(styles, list):
    for st in styles:
        if isinstance(st, dict) and "id" in st:
            table[st["id"]] = st
elif isinstance(styles, dict):
    for key, st in styles.items():
        if isinstance(st, dict):
            table[st.get("id", key)] = st
else:
    nope()

# The LIVE box row, by the same two tells input_box_content uses: the glyph padded
# with U+00A0 (a transcript echo of a past turn pads with an ordinary space), and
# failing a tie, the LAST such row — the box is drawn at the bottom. No box row on
# the grid is an answer this predicate must not give, so it fails closed.
box = None
for span in spans:
    if not isinstance(span, dict):
        continue
    row, text = span.get("row"), span.get("text")
    if span.get("column") == 0 and isinstance(text, str) and text.startswith(PREFIX):
        if isinstance(row, int) and (box is None or row > box):
            box = row
if box is None:
    nope()

cursor = grid.get("cursor")
cursor_col = None
if isinstance(cursor, dict) and cursor.get("row") == box:
    cursor_col = cursor.get("column")

# Every non-blank piece of the box row after the glyph, with the style it carries.
# The glyph span is not always the glyph alone: cmux merges same-style runs, so a
# box holding typed text renders the glyph, its U+00A0 padding and the first word as
# ONE span, while a dim placeholder must split off from the non-dim glyph. Stripping the prefix and
# judging the remainder by ITS OWN style therefore handles both without a special
# case for either.
pieces = []
for span in spans:
    if not isinstance(span, dict) or span.get("row") != box:
        continue
    text = span.get("text")
    col = span.get("column")
    style = table.get(span.get("style_id"))
    if not isinstance(text, str) or style is None:
        nope()
    if col == 0 and text.startswith(PREFIX):
        text = text[len(PREFIX):].lstrip()
        col = len(PREFIX)
    if not text.strip():
        continue
    pieces.append((col, text, style))

# An empty box has nothing to reclassify; the caller already treats it as empty.
if not pieces:
    nope()

tolerated = 0
for col, text, style in pieces:
    if style.get("faint") is True:
        continue
    if (style.get("inverse") is True and len(text) == 1 and tolerated == 0
            and cursor_col is not None and col == cursor_col):
        tolerated = 1
        continue
    nope()
sys.exit(0)
' || return 1
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

# True when the screen is Claude Code's STARTUP TRUST DIALOG rather than a REPL
# waiting for work.
#
# WHY A SCREEN READ AND NOT A LIFECYCLE STATE. This dialog is the one startup gate
# neither transport's readiness signal catches. Verified live on CC 2.1.251 / herdr
# 0.8.0 in a fresh `git init` directory: `agent start` returned
# `interactive_ready:true, agent_status:"idle"` with the dialog on screen — true, in
# its own terms (the dialog does take keystrokes) and useless as permission to
# deliver. The dialog's DEFAULT option is `No, exit`, so a submitted payload answers
# it that way and the callee exits: no user turn, no transcript, the whole work order
# gone (claude-plugins-59ry).
#
# THE CAPTURE IS WHITESPACE-NORMALIZED BEFORE MATCHING, and that is not tidiness —
# without it this predicate does not work at all on a narrow pane. The dialog is one
# reflowed paragraph plus two reflowed option lines, so the terminal decides where the
# line breaks fall. Live-caught on a ~16-column herdr pane (five panes in one
# workspace): `Yes, I trust this\n   folder` and a header broken after
# `Quick safety\n check`, where every raw substring test below missed and the gate
# waved the payload through into the dialog. Collapsing every run of whitespace —
# newlines included — to one space puts the phrases back the way they are read.
#
# THE MATCH IS AN OR OVER WORDINGS, DELIBERATELY, and it leans towards firing. CC has
# already reworded this dialog once (`Do you trust the files in this folder?` →
# `Quick safety check: …` / `Yes, I trust this folder`), and the two directions are
# not symmetric: a false positive costs a refusal with sent:false, which the caller
# recovers from by trusting the directory and re-dialing, while a false negative kills
# the callee. So any one of these phrasings is enough, and a future wording should be
# ADDED here rather than replacing what is already known.
#
# Not scroll-immune — herdr has no equivalent of cmux's scrollback read, so a pane a
# human has scrolled could hand back a stale capture. Only the first-contact gate uses
# this, against an agent seconds old that nobody has touched, and a stale read fails
# back to the pre-existing behavior rather than to something worse.
repl_trust_dialog_present() {
  local flat
  flat=$(tr -s '[:space:]' ' ' <<<"$1")
  [[ "$flat" == *"Quick safety check"*        ]] && return 0
  [[ "$flat" == *"I trust this folder"*       ]] && return 0
  [[ "$flat" == *"trust the files in this"*   ]] && return 0
  return 1
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

# --- The callee's session id -------------------------------------------------
# A fresh claude session UUID, for a launcher that must PRESET the callee's
# session id rather than read it back. Presetting is not a convenience: the whole
# filesystem response channel is ~/.claude/projects/<encoded-cwd>/<session>.jsonl,
# so the id has to be known BEFORE the callee boots.
#
# uuidgen (macOS/Linux), /proc/sys/kernel/random/uuid and /dev/urandom are tried in
# order so this degrades gracefully on minimal systems. Prints nothing when all
# three are unavailable; callers must handle an empty result.
#
# cmux-call-async.sh carries this same derivation inline and is deliberately NOT
# refactored onto this helper here: the phase that added herdr had "the cmux path
# stays bit-identical" as its hard constraint, and a pure extraction is still a
# diff in the file that constraint is about. Adopt this there the next time that
# launcher is touched for its own reasons, and delete the inline copy.
hotline_mint_session_uuid() {
  local b
  uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' \
    || cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || {
         b=$(od -A n -N 16 -t x1 /dev/urandom | tr -d ' \n')
         printf '%s-%s-4%s-%x%s-%s\n' \
           "${b:0:8}" "${b:8:4}" "${b:13:3}" \
           "$(( (16#${b:16:1} & 0x3) | 0x8 ))" "${b:17:3}" "${b:20:12}"
       } \
    || true
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

# hotline_payload_needs_split_delivery <payload-file> — 0 when this payload must be
# delivered as TWO writes into the callee's input box rather than one.
#
# The composite BOTH transports turn on, and both halves of it matter: a slash-command
# first line, and a body beneath it. With no slash there is no invocation for a
# `[Pasted text +N lines]` placeholder to swallow; with no body the payload is one
# short line that arrives verbatim anyway, so splitting would buy nothing and add a
# round trip.
#
# TWO MECHANISMS, ONE QUESTION. cmux-paste.sh splits one `terminal.paste` into two;
# herdr-prompt.sh splits a `pane send-text` from an `agent prompt`. What they must
# never disagree about is WHEN — and they already did: the split landed on the cmux
# path (37a216d) and the herdr backend (f87501e) never adopted it, so every herdr
# first contact carrying a multi-line work order delivered `/hotline:hotline-ringing`
# as plain text and the ringing protocol never engaged (claude-plugins-fvhx).
hotline_payload_needs_split_delivery() {
  local payload_file="$1"
  [[ -r "$payload_file" ]] || return 1
  hotline_is_slash_command_first_line "$(sed -n '1p' "$payload_file")" || return 1
  [[ $(sed -n '2,$p' "$payload_file" | wc -c) -gt 0 ]]
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
