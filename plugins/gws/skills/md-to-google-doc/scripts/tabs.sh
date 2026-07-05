#!/usr/bin/env bash
# Manage native Google Docs tabs via the Docs API (batchUpdate).
#
# Usage:
#   tabs.sh list   <doc-id-or-url>
#   tabs.sh add    <doc-id-or-url> <title> [--emoji "⭐"] [--index N]
#   tabs.sh rename <doc-id-or-url> <tab-id-or-title> <new-title>
#   tabs.sh delete <doc-id-or-url> <tab-id> --yes
#
# `list` prints one tab per line: <tabId>\t<index>\t<title>
# `add` prints the new tabId on stdout.
# Errors on stderr, exit 1.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve active account config directory (same pattern as update.sh)
if [[ -z "${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-}" ]]; then
	_COMMON="$SCRIPT_DIR/../../../scripts/account-common.sh"
	if [[ -f "$_COMMON" ]]; then
		source "$_COMMON"
		export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$(resolve_active_config)"
	fi
fi

usage() {
	sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 1
}

extract_doc_id() {
	# Accept bare ID or docs.google.com URL
	local in="$1"
	if [[ "$in" == *"docs.google.com"* ]] || [[ "$in" == *"document/d/"* ]]; then
		printf '%s' "$in" | sed -E 's|.*/d/([^/]+).*|\1|'
	else
		printf '%s' "$in"
	fi
}

# Fetch doc tabs JSON (tabProperties + content) to stdout.
get_tabs_json() {
	local doc_id="$1"
	gws docs documents get \
		--params "{\"documentId\": \"$doc_id\", \"includeTabsContent\": true, \"fields\": \"tabs\"}" \
		2>/dev/null
}

# Print "<tabId>\t<index>\t<title>" per tab (recursing into childTabs).
list_tabs() {
	local doc_id="$1"
	get_tabs_json "$doc_id" | python3 -c '
import sys, json
def walk(tabs, depth=0):
	for t in tabs or []:
		p = t.get("tabProperties", {})
		print("%s\t%s\t%s%s" % (p.get("tabId",""), p.get("index",""), "  "*depth, p.get("title","")))
		walk(t.get("childTabs"), depth+1)
walk(json.load(sys.stdin).get("tabs"))
'
}

# Resolve a tab-id-or-title to a tabId. Exact title match; errors if 0 or 2+ matches.
resolve_tab_id() {
	local doc_id="$1" needle="$2"
	if [[ "$needle" == t.* ]]; then
		printf '%s' "$needle"
		return 0
	fi
	local matches
	matches=$(list_tabs "$doc_id" | python3 -c '
import sys
needle = sys.argv[1]
hits = [l.split("\t")[0] for l in sys.stdin.read().splitlines()
        if l.split("\t")[2].strip() == needle]
print("\n".join(hits))
' "$needle")
	local n
	n=$(printf '%s' "$matches" | grep -c . || true)
	if [[ "$n" -eq 0 ]]; then
		echo "ERROR: No tab titled '$needle'. Tabs:" >&2
		list_tabs "$doc_id" >&2
		return 1
	elif [[ "$n" -gt 1 ]]; then
		echo "ERROR: Multiple tabs titled '$needle' — use the tabId instead:" >&2
		printf '%s\n' "$matches" >&2
		return 1
	fi
	printf '%s' "$matches"
}

# Allow sourcing for resolve_tab_id / list_tabs without running a command.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

[[ $# -lt 2 ]] && usage
CMD="$1"; shift
DOC_ID=$(extract_doc_id "$1"); shift

case "$CMD" in
	list)
		list_tabs "$DOC_ID"
		;;
	add)
		[[ $# -lt 1 ]] && usage
		TITLE="$1"; shift
		EMOJI=""; INDEX=""
		while [[ $# -gt 0 ]]; do
			case "$1" in
				--emoji) EMOJI="$2"; shift 2 ;;
				--index) INDEX="$2"; shift 2 ;;
				*) echo "Unknown option: $1" >&2; usage ;;
			esac
		done
		PROPS=$(python3 -c '
import json, sys
p = {"title": sys.argv[1]}
if sys.argv[2]: p["iconEmoji"] = sys.argv[2]
if sys.argv[3]: p["index"] = int(sys.argv[3])
print(json.dumps({"requests": [{"addDocumentTab": {"tabProperties": p}}]}))
' "$TITLE" "$EMOJI" "$INDEX")
		gws docs documents batchUpdate \
			--params "{\"documentId\": \"$DOC_ID\"}" \
			--json "$PROPS" 2>/dev/null \
			| python3 -c "import sys,json; print(json.load(sys.stdin)['replies'][0]['addDocumentTab']['tabProperties']['tabId'])"
		;;
	rename)
		[[ $# -lt 2 ]] && usage
		TAB_ID=$(resolve_tab_id "$DOC_ID" "$1")
		NEW_TITLE=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$2")
		gws docs documents batchUpdate \
			--params "{\"documentId\": \"$DOC_ID\"}" \
			--json "{\"requests\": [{\"updateDocumentTabProperties\": {\"tabProperties\": {\"tabId\": \"$TAB_ID\", \"title\": $NEW_TITLE}, \"fields\": \"title\"}}]}" >/dev/null 2>&1
		echo "Renamed $TAB_ID"
		;;
	delete)
		[[ $# -lt 1 ]] && usage
		TAB_ID="$1"; shift
		if [[ "$TAB_ID" != t.* ]]; then
			echo "ERROR: delete requires an explicit tabId (t.xxxx), not a title. Run: tabs.sh list <doc>" >&2
			exit 1
		fi
		if [[ "${1:-}" != "--yes" ]]; then
			echo "ERROR: deleting a tab destroys its content. Re-run with --yes to confirm." >&2
			exit 1
		fi
		gws docs documents batchUpdate \
			--params "{\"documentId\": \"$DOC_ID\"}" \
			--json "{\"requests\": [{\"deleteTab\": {\"tabId\": \"$TAB_ID\"}}]}" >/dev/null 2>&1
		echo "Deleted $TAB_ID"
		;;
	*)
		usage
		;;
esac
