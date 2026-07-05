#!/usr/bin/env bash
# Publish a markdown file into ONE native tab of a Google Doc, preserving all
# other tabs. Uses a temp doc for Google's server-side md→Doc conversion, then
# replays its structure into the target tab via batchUpdate.
#
# Usage: tab-update.sh <markdown-file> <doc-id-or-url> --tab <tab-title-or-id>
# Output: Google Doc URL (with ?tab=) on stdout. Errors on stderr.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -z "${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-}" ]]; then
	_COMMON="$SCRIPT_DIR/../../../scripts/account-common.sh"
	if [[ -f "$_COMMON" ]]; then
		source "$_COMMON"
		export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$(resolve_active_config)"
	fi
fi

usage() {
	echo "Usage: $(basename "$0") <markdown-file> <doc-id-or-url> --tab <tab-title-or-id>" >&2
	exit 1
}

[[ $# -lt 4 ]] && usage
FILE="$1"; DOC_ID_OR_URL="$2"; shift 2
TAB_ARG=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--tab) TAB_ARG="$2"; shift 2 ;;
		*) echo "Unknown option: $1" >&2; usage ;;
	esac
done
[[ -z "$TAB_ARG" ]] && usage
[[ -f "$FILE" ]] || { echo "ERROR: File not found: $FILE" >&2; exit 1; }

if ! gws auth status >/dev/null 2>&1; then
	echo "ERROR: gws not authenticated. Run: gws auth login" >&2
	exit 1
fi

if [[ "$DOC_ID_OR_URL" == *"docs.google.com"* ]]; then
	DOC_ID=$(echo "$DOC_ID_OR_URL" | sed -E 's|.*/d/([^/]+).*|\1|')
else
	DOC_ID="$DOC_ID_OR_URL"
fi

# Resolve the target tab (sources list_tabs/resolve_tab_id from tabs.sh)
source "$SCRIPT_DIR/tabs.sh"
TAB_ID=$(resolve_tab_id "$DOC_ID" "$TAB_ARG")

# Temp files in cwd (gws --upload requires cwd-relative paths); unique names
# because macOS BSD mktemp can't randomize with a suffix.
STEM="./__tmp-tabpub-$$-$RANDOM"
CLEAN="$STEM.md"
trap 'rm -f "$STEM".*; [[ -n "${TMP_DOC_ID:-}" ]] && gws drive files update --params "{\"fileId\": \"$TMP_DOC_ID\"}" --json "{\"trashed\": true}" >/dev/null 2>&1 || true' EXIT

"$SCRIPT_DIR/clean.sh" "$FILE" "$CLEAN"

# 1. Server-side conversion: upload md as a throwaway Google Doc.
TMP_DOC_ID=$(gws drive files create \
	--json '{"name": "TMP tab-publish (auto-deleted)", "mimeType": "application/vnd.google-apps.document"}' \
	--upload "$CLEAN" --upload-content-type text/markdown 2>/dev/null \
	| python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
[[ -n "$TMP_DOC_ID" ]] || { echo "ERROR: temp-doc conversion failed" >&2; exit 1; }

# 2. Read the converted structure.
gws docs documents get --params "{\"documentId\": \"$TMP_DOC_ID\"}" 2>/dev/null > "$STEM-src.json"

# 3. Current end index of the target tab (for the clear request).
CLEAR_END=$(gws docs documents get \
	--params "{\"documentId\": \"$DOC_ID\", \"includeTabsContent\": true, \"fields\": \"tabs\"}" 2>/dev/null \
	| python3 -c '
import sys, json
tab_id = sys.argv[1]
def find(tabs):
	for t in tabs or []:
		if t.get("tabProperties", {}).get("tabId") == tab_id:
			return t
		hit = find(t.get("childTabs"))
		if hit:
			return hit
d = json.load(sys.stdin)
t = find(d.get("tabs"))
if not t:
	sys.exit("tab not found: " + tab_id)
print(t["documentTab"]["body"]["content"][-1]["endIndex"])
' "$TAB_ID")

# 4. Generate replay requests.
python3 "$SCRIPT_DIR/replay_tab.py" "$STEM-src.json" "$TAB_ID" --clear-end "$CLEAR_END" > "$STEM-reqs.json"

# 5. Apply in chunks of 400 requests (order-preserving; batches execute
#    sequentially so the index-mirror invariant holds across them).
python3 - "$STEM-reqs.json" "$STEM-chunk" <<'PYEOF'
import json, sys
reqs = json.load(open(sys.argv[1]))["requests"]
for n, i in enumerate(range(0, len(reqs), 400)):
	with open("%s-%03d.json" % (sys.argv[2], n), "w") as f:
		json.dump({"requests": reqs[i:i+400]}, f)
print(n + 1 if reqs else 0)
PYEOF
for CHUNK in "$STEM-chunk"-*.json; do
	[[ -e "$CHUNK" ]] || break
	gws docs documents batchUpdate \
		--params "{\"documentId\": \"$DOC_ID\"}" \
		--json "$(cat "$CHUNK")" >/dev/null 2>"$STEM-err.txt" || {
		echo "ERROR: batchUpdate failed on $CHUNK:" >&2
		cat "$STEM-err.txt" >&2
		echo "The target tab may be partially written. Re-run to overwrite it cleanly." >&2
		exit 1
	}
done

# 6. Verify: target tab plain text == temp doc plain text.
gws docs documents get \
	--params "{\"documentId\": \"$DOC_ID\", \"includeTabsContent\": true, \"fields\": \"tabs\"}" 2>/dev/null > "$STEM-verify.json"
python3 - "$STEM-verify.json" "$STEM-src.json" "$TAB_ID" <<'PYEOF'
import json, sys

def text_of(content):
	out = []
	for e in content:
		if "paragraph" in e:
			for el in e["paragraph"].get("elements", []):
				out.append(el.get("textRun", {}).get("content", ""))
		elif "table" in e:
			for row in e["table"].get("tableRows", []):
				for cell in row.get("tableCells", []):
					out.append(text_of(cell.get("content", [])))
	return "".join(out)

def find(tabs, tab_id):
	for t in tabs or []:
		if t.get("tabProperties", {}).get("tabId") == tab_id:
			return t
		hit = find(t.get("childTabs"), tab_id)
		if hit:
			return hit

target = find(json.load(open(sys.argv[1])).get("tabs"), sys.argv[3])
got = text_of(target["documentTab"]["body"]["content"])
want = text_of(json.load(open(sys.argv[2]))["body"]["content"])
if got != want:
	print("WARNING: tab text differs from converted markdown "
	      "(got %d chars, want %d). Formatting may have drifted."
	      % (len(got), len(want)), file=sys.stderr)
PYEOF

echo "https://docs.google.com/document/d/$DOC_ID/edit?tab=$TAB_ID"
