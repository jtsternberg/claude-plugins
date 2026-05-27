#!/usr/bin/env bash
# Draft a Gmail message from a local markdown file.
# Converts markdown to HTML, saves as a Gmail draft (never sends), and prints
# the Gmail drafts URL so the user can review/send from the Gmail UI.
#
# Usage:
#   draft.sh <markdown-file> <recipient> [--subject "Subject"] [--cc EMAIL] [--bcc EMAIL] [--from EMAIL]
#
# <recipient> may be a literal email address (contains "@") or a name to look
# up via Gmail search (most recent correspondent matching the name wins).
#
# Subject resolution order:
#   1. --subject flag
#   2. A leading "Subject: ..." line at the top of the markdown
#   3. Error — caller must supply a subject
#
# Output: a Gmail drafts URL on stdout. Errors on stderr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve active gws account config dir (mirrors md-to-google-doc pattern).
if [[ -z "${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-}" ]]; then
  _COMMON="$SCRIPT_DIR/../../../scripts/account-common.sh"
  if [[ -f "$_COMMON" ]]; then
    # shellcheck disable=SC1090
    source "$_COMMON"
    export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$(resolve_active_config)"
  fi
fi

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <markdown-file> <recipient> [--subject "Subject"] [--cc EMAIL] [--bcc EMAIL] [--from EMAIL]

<recipient> may be an email address or a name to look up via Gmail search.
EOF
  exit 1
}

[[ $# -lt 2 ]] && usage

FILE="$1"
RECIPIENT_ARG="$2"
shift 2

SUBJECT=""
CC=""
BCC=""
FROM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="$2"; shift 2 ;;
    --cc) CC="$2"; shift 2 ;;
    --bcc) BCC="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -f "$FILE" ]] || { echo "ERROR: File not found: $FILE" >&2; exit 1; }

if ! gws auth status >/dev/null 2>&1; then
  echo "ERROR: gws not authenticated. Run: gws auth login" >&2
  exit 1
fi

# --- Resolve recipient ---------------------------------------------------
if [[ "$RECIPIENT_ARG" == *"@"* ]]; then
  TO="$RECIPIENT_ARG"
else
  echo "Looking up '$RECIPIENT_ARG' via Gmail search..." >&2
  LIST_JSON=$(gws gmail users messages list \
    --params "$(python3 -c "import json,sys; print(json.dumps({'userId':'me','q':sys.argv[1],'maxResults':3}))" "$RECIPIENT_ARG")")
  MSG_ID=$(printf '%s' "$LIST_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
msgs = d.get('messages') or []
print(msgs[0]['id'] if msgs else '')
")
  if [[ -z "$MSG_ID" ]]; then
    echo "ERROR: No Gmail messages found matching '$RECIPIENT_ARG'. Pass an email address instead." >&2
    exit 1
  fi
  HEADERS_JSON=$(gws gmail +read --id "$MSG_ID" --headers)
  TO=$(printf '%s' "$HEADERS_JSON" | python3 -c "
import json, re, sys
d = json.load(sys.stdin)
headers = d.get('payload', {}).get('headers', []) or d.get('headers', [])
frm = next((h['value'] for h in headers if h.get('name','').lower()=='from'), '')
m = re.search(r'<([^>]+)>', frm) or re.search(r'([\w.+-]+@[\w.-]+)', frm)
print(m.group(1) if m else '')
")
  if [[ -z "$TO" ]]; then
    echo "ERROR: Could not extract email from headers of message $MSG_ID." >&2
    exit 1
  fi
  echo "Resolved '$RECIPIENT_ARG' → $TO" >&2
fi

# --- Resolve subject -----------------------------------------------------
if [[ -z "$SUBJECT" ]]; then
  SUBJECT=$(awk '
    BEGIN {skip=0}
    NR==1 && /^---$/ {skip=1; next}
    skip==1 && /^---$/ {skip=0; next}
    skip==1 {next}
    /^Subject:[[:space:]]/ {sub(/^Subject:[[:space:]]*/, ""); print; exit}
    /^[[:space:]]*$/ {next}
    {exit}
  ' "$FILE")
fi
if [[ -z "$SUBJECT" ]]; then
  echo "ERROR: No subject. Pass --subject \"...\" or add a 'Subject: ...' line at the top of the markdown." >&2
  exit 1
fi

# --- Clean + convert markdown -------------------------------------------
TMP_MD="$(mktemp -t gmail-draft.XXXXXX).md"
TMP_HTML="$(mktemp -t gmail-draft.XXXXXX).html"
trap 'rm -f "$TMP_MD" "$TMP_HTML"' EXIT

bash "$SCRIPT_DIR/clean.sh" "$FILE" "$TMP_MD"

# Pick a markdown→HTML converter. `marked` (https://github.com/markedjs/marked-cli)
# is the preferred tool; fall back to pandoc.
if command -v marked >/dev/null 2>&1; then
  marked "$TMP_MD" > "$TMP_HTML"
elif command -v pandoc >/dev/null 2>&1; then
  pandoc -f markdown -t html "$TMP_MD" > "$TMP_HTML"
else
  echo "ERROR: No markdown→HTML converter found. Install 'marked' (npm i -g marked) or pandoc." >&2
  exit 1
fi

[[ -s "$TMP_HTML" ]] || { echo "ERROR: Converter produced empty HTML." >&2; exit 1; }

# --- Create draft --------------------------------------------------------
BODY=$(cat "$TMP_HTML")

ARGS=(gmail +send --to "$TO" --subject "$SUBJECT" --body "$BODY" --html --draft)
[[ -n "$CC" ]]   && ARGS+=(--cc "$CC")
[[ -n "$BCC" ]]  && ARGS+=(--bcc "$BCC")
[[ -n "$FROM" ]] && ARGS+=(--from "$FROM")

RESPONSE=$(gws "${ARGS[@]}")

MSG_ID=$(printf '%s' "$RESPONSE" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
mid = d.get('message', {}).get('id') or d.get('id', '')
print(mid)
")

if [[ -z "$MSG_ID" ]]; then
  echo "ERROR: Could not parse draft message id from gws response." >&2
  echo "API response: $RESPONSE" >&2
  exit 1
fi

echo "https://mail.google.com/mail/u/0/#drafts/$MSG_ID"
