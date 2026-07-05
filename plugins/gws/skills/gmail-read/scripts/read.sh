#!/usr/bin/env bash
# Search and read Gmail messages via the gws CLI.
#
# Usage:
#   read.sh "<query>" [--limit N] [--body] [--account EMAIL] [--pretty]
#   read.sh --id <messageId> [--account EMAIL] [--pretty]
#
# Emits NDJSON by default (one message per line). With --pretty, emits a
# human-readable block instead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve active gws account config dir (mirrors md-to-google-doc pattern).
if [[ -z "${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-}" ]]; then
  _COMMON="$SCRIPT_DIR/../../../scripts/account-common.sh"
  if [[ -f "$_COMMON" ]]; then
    # shellcheck disable=SC1090
    source "$_COMMON"
    GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$(resolve_active_config)"
    export GOOGLE_WORKSPACE_CLI_CONFIG_DIR
  fi
fi

QUERY=""
MESSAGE_ID=""
LIMIT=10
FETCH_BODY=0
ACCOUNT=""
PRETTY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)          MESSAGE_ID="$2"; shift 2 ;;
    --limit)       LIMIT="$2"; shift 2 ;;
    --body)        FETCH_BODY=1; shift ;;
    --account)     ACCOUNT="$2"; shift 2 ;;
    --pretty)      PRETTY=1; shift ;;
    -h|--help)
      sed -n '2,9p' "$0"; exit 0 ;;
    --*)
      echo "Unknown flag: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$QUERY" ]]; then QUERY="$1"; else QUERY="$QUERY $1"; fi
      shift ;;
  esac
done

if [[ -z "$QUERY" && -z "$MESSAGE_ID" ]]; then
  echo "Provide a search query or --id <messageId>." >&2
  exit 2
fi

if ! [[ "$LIMIT" =~ ^[0-9]+$ ]]; then
  echo "--limit must be a positive integer, got: $LIMIT" >&2
  exit 2
fi

# Optional per-call account override (label or email). Fails hard if the
# account can't be resolved — silently reading the wrong inbox is worse.
if [[ -n "$ACCOUNT" ]]; then
  _COMMON="$SCRIPT_DIR/../../../scripts/account-common.sh"
  if [[ ! -f "$_COMMON" ]]; then
    echo "ERROR: account-common.sh not found; cannot honor --account." >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$_COMMON"
  GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$(resolve_config_for_account "$ACCOUNT")" || exit 1
  export GOOGLE_WORKSPACE_CLI_CONFIG_DIR
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build a JSON object from key=value pairs without shell interpolation into
# JSON — queries legitimately contain double quotes (subject:"exact phrase").
json_params() {
  python3 -c '
import json, sys
obj = {}
for pair in sys.argv[1:]:
    k, _, v = pair.partition("=")
    obj[k] = int(v) if v.isdigit() and k == "maxResults" else v
print(json.dumps(obj))
' "$@"
}

# Run a gws command, surfacing stderr on failure instead of swallowing it.
run_gws() {
  local out="$1"; shift
  if ! gws "$@" > "$out" 2>"$TMP/err"; then
    echo "ERROR: gws $1 $2 failed:" >&2
    cat "$TMP/err" >&2
    exit 1
  fi
}

# Fetch a single message by id and emit a structured record.
# Args: <id> <fetch_body: 0|1>
fetch_and_emit() {
  local id="$1"
  local want_body="$2"
  local raw="$TMP/msg-$id.json"
  run_gws "$raw" gmail users messages get \
    --params "$(json_params "userId=me" "id=$id" "format=full")"

  python3 - "$raw" "$want_body" "$PRETTY" <<'PY'
import base64, json, re, sys

raw_path, want_body, pretty = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"
d = json.load(open(raw_path))
headers = {h["name"].lower(): h["value"] for h in d.get("payload", {}).get("headers", [])}

def walk(part):
    if part.get("body", {}).get("data"):
        yield base64.urlsafe_b64decode(part["body"]["data"]).decode("utf-8", "ignore"), part.get("mimeType", "")
    for c in part.get("parts", []) or []:
        yield from walk(c)

body = ""
if want_body:
    plain = html = ""
    for text, mime in walk(d.get("payload", {})):
        if not text.strip():
            continue
        if "text/plain" in mime and not plain:
            plain = text
        elif "text/html" in mime and not html:
            html = text
    if plain:
        body = plain
    elif html:
        stripped = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", html, flags=re.DOTALL | re.IGNORECASE)
        stripped = re.sub(r"<[^>]+>", " ", stripped)
        stripped = re.sub(r"\s+", " ", stripped).strip()
        body = stripped

rec = {
    "id": d.get("id", ""),
    "threadId": d.get("threadId", ""),
    "subject": headers.get("subject", ""),
    "from": headers.get("from", ""),
    "to": headers.get("to", ""),
    "date": headers.get("date", ""),
    "snippet": d.get("snippet", ""),
}
if want_body:
    rec["body"] = body

if pretty:
    print(f"— {rec['subject']}")
    print(f"  id:   {rec['id']}")
    print(f"  from: {rec['from']}")
    if rec["to"]:
        print(f"  to:   {rec['to']}")
    print(f"  date: {rec['date']}")
    if rec["snippet"]:
        print(f"  snip: {rec['snippet']}")
    if want_body and body:
        print()
        print(body)
    print()
else:
    print(json.dumps(rec, ensure_ascii=False))
PY
}

if [[ -n "$MESSAGE_ID" ]]; then
  fetch_and_emit "$MESSAGE_ID" 1
  exit 0
fi

# Search mode.
LIST_RAW="$TMP/list.json"
run_gws "$LIST_RAW" gmail users messages list \
  --params "$(json_params "userId=me" "q=$QUERY" "maxResults=$LIMIT")"

IDS=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except json.JSONDecodeError:
    sys.stderr.write(open(sys.argv[1]).read())
    sys.exit(1)
for m in d.get('messages', []):
    print(m['id'])
" "$LIST_RAW")

if [[ -z "$IDS" ]]; then
  if [[ $PRETTY -eq 1 ]]; then
    echo "No messages matched: $QUERY"
  fi
  exit 0
fi

while IFS= read -r id; do
  [[ -z "$id" ]] && continue
  fetch_and_emit "$id" "$FETCH_BODY"
done <<< "$IDS"
