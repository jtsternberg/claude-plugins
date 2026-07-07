#!/usr/bin/env bash
# Draft a Gmail message from a local markdown file.
# Converts markdown to HTML, saves as a Gmail draft (never sends), and prints
# the Gmail drafts URL so the user can review/send from the Gmail UI.
#
# Usage:
#   draft.sh <markdown-file> <recipient> [--subject "Subject"] [--cc EMAIL] [--bcc EMAIL] [--from EMAIL] [--reply-to MESSAGE_ID] [--thread THREAD_ID]
#
# <recipient> may be a literal email address (contains "@") or a name to look
# up via Gmail search (most recent correspondent matching the name wins).
#
# Threading (optional):
#   --reply-to MESSAGE_ID  Attach the draft to the conversation the given
#                          message belongs to. The script looks up that
#                          message's Message-ID, References, and threadId, then
#                          sets message.threadId on the draft AND injects
#                          In-Reply-To / References RFC 5322 headers so Gmail
#                          threads the reply correctly. If no --subject is
#                          given, the parent's subject (prefixed "Re: ") is used.
#   --thread THREAD_ID     Attach the draft to a threadId directly (no header
#                          lookup). Prefer --reply-to for reliable threading.
# Without either flag, behavior is unchanged: a standalone draft.
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
Usage: $(basename "$0") <markdown-file> <recipient> [--subject "Subject"] [--cc EMAIL] [--bcc EMAIL] [--from EMAIL] [--reply-to MESSAGE_ID] [--thread THREAD_ID]

<recipient> may be an email address or a name to look up via Gmail search.

Threading:
  --reply-to MESSAGE_ID  Thread the draft onto that message's conversation
                         (sets threadId + In-Reply-To/References headers).
  --thread THREAD_ID     Attach to a threadId directly (no header lookup).
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
REPLY_TO=""
THREAD_ID=""
IN_REPLY_TO=""
REFERENCES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject) SUBJECT="$2"; shift 2 ;;
    --cc) CC="$2"; shift 2 ;;
    --bcc) BCC="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --reply-to) REPLY_TO="$2"; shift 2 ;;
    --thread) THREAD_ID="$2"; shift 2 ;;
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

# --- Resolve threading ---------------------------------------------------
# When --reply-to is given, look up the parent message's threadId and the
# RFC 5322 threading headers (Message-ID + References) so the draft attaches
# to the existing Gmail conversation. This both sets message.threadId on the
# draft resource AND injects In-Reply-To / References into the raw MIME —
# Gmail needs the headers to thread reliably, not just threadId.
PARENT_SUBJECT=""
if [[ -n "$REPLY_TO" ]]; then
  echo "Looking up parent message $REPLY_TO for threading..." >&2
  PARENT_JSON=$(gws gmail users messages get --params "$(python3 -c "import json,sys; print(json.dumps({'userId':'me','id':sys.argv[1],'format':'metadata','metadataHeaders':['Message-ID','References','Subject']}))" "$REPLY_TO")") || {
    echo "ERROR: Could not fetch parent message $REPLY_TO for --reply-to." >&2
    exit 1
  }
  # Parse threadId, parent Message-ID, References, Subject from the response.
  eval "$(printf '%s' "$PARENT_JSON" | python3 -c "
import json, shlex, sys
d = json.load(sys.stdin)
hs = {h.get('name','').lower(): h.get('value','') for h in d.get('payload', {}).get('headers', [])}
tid = d.get('threadId', '')
mid = hs.get('message-id', '')
refs = hs.get('references', '')
subj = hs.get('subject', '')
# References for the reply = existing References chain + parent Message-ID.
new_refs = (refs + ' ' + mid).strip() if refs else mid
print('THREAD_ID=' + shlex.quote(tid))
print('IN_REPLY_TO=' + shlex.quote(mid))
print('REFERENCES=' + shlex.quote(new_refs))
print('PARENT_SUBJECT=' + shlex.quote(subj))
")"
  if [[ -z "$THREAD_ID" ]]; then
    echo "ERROR: Parent message $REPLY_TO has no threadId; cannot thread." >&2
    exit 1
  fi
  echo "Threading onto conversation $THREAD_ID" >&2
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
# Fall back to the parent's subject when replying and none was supplied.
if [[ -z "$SUBJECT" && -n "$PARENT_SUBJECT" ]]; then
  SUBJECT="$PARENT_SUBJECT"
fi
if [[ -z "$SUBJECT" ]]; then
  echo "ERROR: No subject. Pass --subject \"...\" or add a 'Subject: ...' line at the top of the markdown." >&2
  exit 1
fi
# In reply mode, ensure a conventional "Re: " prefix — matching subjects help
# Gmail keep the draft inside the parent conversation.
if [[ -n "$REPLY_TO" ]] && ! printf '%s' "$SUBJECT" | grep -qiE '^re:[[:space:]]'; then
  SUBJECT="Re: $SUBJECT"
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
# Build a base64url-encoded MIME message and create the draft via the Gmail
# API drafts.create method, then verify with drafts.get before claiming
# success. The draft lands in the ACTIVE gws account (resolved above), which
# may not be the caller's default — so we surface the account email and put
# it in the URL as authuser= instead of assuming account index u/0.
PARAMS=$(TO="$TO" SUBJECT="$SUBJECT" CC="$CC" BCC="$BCC" FROM="$FROM" \
  THREAD_ID="$THREAD_ID" IN_REPLY_TO="$IN_REPLY_TO" REFERENCES="$REFERENCES" \
  HTML_FILE="$TMP_HTML" python3 - <<'PY'
import base64, json, os
from email.mime.text import MIMEText

with open(os.environ['HTML_FILE'], encoding='utf-8') as fh:
    msg = MIMEText(fh.read(), 'html', 'utf-8')
msg['To'] = os.environ['TO']
msg['Subject'] = os.environ['SUBJECT']
for header, env in (('Cc', 'CC'), ('Bcc', 'BCC'), ('From', 'FROM')):
    if os.environ.get(env):
        msg[header] = os.environ[env]

# RFC 5322 threading headers (only present when replying).
if os.environ.get('IN_REPLY_TO'):
    msg['In-Reply-To'] = os.environ['IN_REPLY_TO']
if os.environ.get('REFERENCES'):
    msg['References'] = os.environ['REFERENCES']

raw = base64.urlsafe_b64encode(msg.as_bytes()).decode().rstrip('=')
message = {'raw': raw}
# Attach to an existing conversation when a threadId is set (--reply-to/--thread).
if os.environ.get('THREAD_ID'):
    message['threadId'] = os.environ['THREAD_ID']
print(json.dumps({'message': message}))
PY
)

RESPONSE=$(gws gmail users drafts create --params '{"userId":"me"}' --json "$PARAMS")

read -r DRAFT_ID MSG_ID < <(printf '%s' "$RESPONSE" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
print(d.get('id', ''), d.get('message', {}).get('id', ''))
")

if [[ -z "${DRAFT_ID:-}" || -z "${MSG_ID:-}" ]]; then
  echo "ERROR: Could not parse draft id from gws drafts.create response." >&2
  echo "API response: $RESPONSE" >&2
  exit 1
fi

# Verify the draft actually persisted before claiming success.
if ! gws gmail users drafts get --params "{\"userId\":\"me\",\"id\":\"$DRAFT_ID\"}" >/dev/null 2>&1; then
  echo "ERROR: Draft $DRAFT_ID was not found after creation (drafts.get failed)." >&2
  exit 1
fi

# Which mailbox did this land in? Surface it so nobody hunts for the draft in
# the wrong account, and address the URL to that account explicitly.
ACCOUNT_EMAIL=$(gws gmail users getProfile --params '{"userId":"me"}' 2>/dev/null | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('emailAddress', ''))
except Exception:
    pass
")

if [[ -n "$ACCOUNT_EMAIL" ]]; then
  echo "Draft created in account: $ACCOUNT_EMAIL" >&2
  echo "https://mail.google.com/mail/?authuser=$ACCOUNT_EMAIL#drafts/$MSG_ID"
else
  echo "https://mail.google.com/mail/u/0/#drafts/$MSG_ID"
fi
