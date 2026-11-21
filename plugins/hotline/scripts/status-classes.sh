#!/usr/bin/env bash
# =============================================================================
# Status classes: which kind of ending a callee's STATUS word is.
#
# A STATUS word is any UPPER_SNAKE token. What the caller does with it is its
# class, and every parser of a STATUS line (transcript-extract.sh, the screen
# scrape and headless classifier, notify-caller.sh) asks this file:
#   done             the call resolved, body delivered        (exit 0)
#   out_of_scope     resolved, the work belongs elsewhere      (exit 0)
#   awaiting_review  this step's reply is ready, more to come  (exit 4)
#   blocked          the callee needs an answer to go on        (exit 7)
# The built-ins below carry those classes. A caller declares more at dial time
# (dial.sh --status-class WORD=class, or HOTLINE_STATUS_CLASSES), and dial
# writes them to <call_dir>/status_classes.txt, one WORD=class per line, so
# every reader of that call sees one map. A word in neither is class unknown:
# the waiter keeps polling past it, and notify-caller still notifies it.
# WORK_IN_PROGRESS is the body-start marker, not an ending, and takes no class.
#
# Sourced, never run. No associative arrays: macOS ships bash 3.2. Every function
# returns 0 on its normal paths, because its callers run under set -euo pipefail.
# =============================================================================

HOTLINE_STATUS_FILE_NAME="status_classes.txt"

hotline_status_builtins() {
  printf '%s\n' DONE=done WORK_COMPLETE=done OUT_OF_SCOPE=out_of_scope \
    AWAITING_REVIEW=awaiting_review BLOCKED=blocked
}

# Parse a declaration list ("A=blocked,B=done", commas and/or whitespace) into
# normalized WORD=class lines, later entries winning. Bad entry → message on
# stderr, return 1, nothing on stdout.
hotline_status_classes_parse() {
  local spec word class out="" specs=()
  read -r -a specs <<<"$(printf '%s' "$*" | tr ',\n' '  ')"
  for spec in ${specs[@]+"${specs[@]}"}; do
    word=${spec%%=*}; class=${spec#*=}
    if [[ "$spec" != *=* || ! "$word" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      echo "status class '$spec' must be WORD=class with an UPPER_SNAKE word" >&2; return 1
    fi
    if [[ "$word" == WORK_IN_PROGRESS ]]; then
      echo "WORK_IN_PROGRESS is the body-start marker and cannot take a class" >&2; return 1
    fi
    case "$class" in
      done|out_of_scope|awaiting_review|blocked) ;;
      *) echo "status class '$spec': class must be done, out_of_scope, awaiting_review or blocked" >&2; return 1 ;;
    esac
    out+="$word=$class"$'\n'
  done
  [[ -n "$out" ]] || return 0
  printf '%s' "$out" | awk -F= '{m[$1]=$2; if (!($1 in seen)) {seen[$1]=1; o[++n]=$1}} END {for (i=1;i<=n;i++) print o[i] "=" m[o[i]]}'
}

# The effective map for a call: built-ins, then the call's declarations.
# $1 = status_classes.txt (may be empty or missing). Lines that do not parse are
# skipped, so a damaged file degrades to the built-ins rather than failing a wait.
hotline_status_map() {
  { hotline_status_builtins
    if [[ -n "${1:-}" && -f "$1" ]]; then
      grep -E '^[A-Z][A-Z0-9_]*=(done|out_of_scope|awaiting_review|blocked)$' "$1" || true
    fi
  } | awk -F= '{m[$1]=$2; if (!($1 in seen)) {seen[$1]=1; o[++n]=$1}} END {for (i=1;i<=n;i++) print o[i] "=" m[o[i]]}'
}

# $1 = word, $2 = status_classes.txt → its class, or "unknown".
hotline_status_class() {
  local c
  c=$(hotline_status_map "${2:-}" | awk -F= -v w="$1" '$1 == w {print $2}')
  printf '%s\n' "${c:-unknown}"
}

# $1 = file, $2.. = classes → the words in those classes as an ERE alternation
# ("DONE|WORK_COMPLETE"). Words are UPPER_SNAKE, so they need no escaping.
hotline_status_words() {
  local file="${1:-}"; shift
  hotline_status_map "$file" | awk -F= -v cls=" $* " 'index(cls, " " $2 " ") {printf "%s%s", (n++ ? "|" : ""), $1}'
}

# $1 = a STATUS line → the free text between its word and its call_id suffix.
hotline_status_detail() {
  printf '%s' "$1" | sed -E 's/[[:space:]]+$//; s/^STATUS: [A-Z][A-Z0-9_]* ?//; s/ ?call_id=[^[:space:]]+$//'
}

# $1 = resolving word, $2 = its detail → the JSON keys every response payload adds:
# "status" for a non-built-in word, "detail" for free text. {} for a bare built-in,
# which is what keeps those payloads byte-identical.
hotline_status_payload_extra() {
  local st=""
  [[ -z "${1:-}" ]] || hotline_status_is_builtin "$1" || st=$1
  jq -nc --arg st "$st" --arg det "${2:-}" \
    '(if $st == "" then {} else {status: $st} end) + (if $det == "" then {} else {detail: $det} end)'
}

# $1 = word → 0 when it is a built-in status (its payload stays unmarked).
hotline_status_is_builtin() {
  hotline_status_builtins | grep -qx "$1=.*"
}
