#!/usr/bin/env bash
# send-to-surface — deliver a prompt into ONE exact cmux surface, right now.
#
# Contract (V1): resolve the exact surface UUID from a SINGLE `cmux tree`
# snapshot; if it is gone, or any cmux call fails, print a status word and STOP
# — never create a surface, fork, resume elsewhere, or fall back. The Enter is a
# SEPARATE key event: a newline bundled into `cmux send` lands as a literal line
# break inside a TUI/Ink REPL and does not submit (`cmux send --help` says
# "\n and \r send Enter" — true for a shell, false for a bracketed-paste REPL).
#
# stdout: one status word — sent | surface_gone | send_failed | enter_failed | error
#         (on success: "sent delivery_observed=true|false").
# exit:   0 sent · 2 usage/error · 3 surface_gone · 4 send_failed · 5 enter_failed
#
# Prefer --prompt-file: it keeps the payload off argv, which is ps-visible to any
# local user. --prompt is a convenience for quick, non-sensitive sends.
set -u

# die <stderr-msg> <stdout-status> <exit-code>
die() { echo "send-to-surface: $1" >&2; echo "$2"; exit "$3"; }

SURFACE="" PROMPT="" PROMPT_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --surface)     SURFACE="${2:-}"; shift 2 ;;
    --prompt)      PROMPT="${2:-}"; shift 2 ;;
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
    -h|--help)     echo "Usage: send-to-surface.sh --surface <uuid> (--prompt-file <path> | --prompt <text>)"; exit 0 ;;
    *)             die "unknown argument: $1" "error" 2 ;;
  esac
done

command -v cmux >/dev/null 2>&1 || die "cmux not on PATH" "error" 2
command -v jq   >/dev/null 2>&1 || die "jq not on PATH (brew install jq)" "error" 2
[ -n "$SURFACE" ] || die "--surface <uuid> is required" "error" 2
[ -n "$PROMPT" ] && [ -n "$PROMPT_FILE" ] && die "pass only one of --prompt / --prompt-file" "error" 2
if [ -n "$PROMPT_FILE" ]; then
  [ -f "$PROMPT_FILE" ] || die "prompt file not found: $PROMPT_FILE" "error" 2
  PROMPT="$(cat "$PROMPT_FILE")"
fi
[ -n "$PROMPT" ] || die "a prompt is required (--prompt-file or --prompt); refusing to send empty" "error" 2

# One snapshot; resolve the exact surface UUID -> its workspace UUID, which is
# needed only as targeting context. Comparison is case-insensitive (cmux prints
# UUIDs uppercase; a caller may paste any case). A failed snapshot and an absent
# UUID both mean "can't safely target it" -> surface_gone, no fallback.
snap="$(cmux tree --all --json --id-format both 2>/dev/null)" \
  || die "cmux tree snapshot failed" "surface_gone" 3
WS="$(printf '%s' "$snap" | jq -r --arg s "$SURFACE" '
  ($s | ascii_downcase) as $t
  | [ .windows[].workspaces[] as $w
      | $w.panes[].surfaces[]
      | select(((.id // "") | ascii_downcase) == $t)
      | $w.id ] | first // empty' 2>/dev/null)"
[ -n "$WS" ] || die "surface $SURFACE absent from cmux tree — stopping, no fallback" "surface_gone" 3

# Send the text, settle, then submit with a real Enter key (never bundled).
# Suppress cmux's own stdout ("OK surface:N workspace:N") so this script's
# stdout is ONLY the status word — a caller parsing it must not see cmux chatter.
cmux send --workspace "$WS" --surface "$SURFACE" -- "$PROMPT" >/dev/null 2>&1 \
  || die "cmux send failed — stopping, Enter not sent" "send_failed" 4
sleep 0.4
cmux send-key --workspace "$WS" --surface "$SURFACE" Enter >/dev/null 2>&1 \
  || die "send-key Enter failed — text may sit unsubmitted; not re-sending" "enter_failed" 5

# Basic, INFORMATIONAL read-screen check. A busy REPL enqueues silently and a
# scrolled viewport shows stale content, so "false" is never proof of failure.
probe="$(printf '%s' "$PROMPT" | head -n1 | cut -c1-48)"
if cmux read-screen --workspace "$WS" --surface "$SURFACE" 2>/dev/null | grep -Fq -- "$probe"; then
  echo "sent delivery_observed=true"
else
  echo "sent delivery_observed=false"
fi
exit 0
