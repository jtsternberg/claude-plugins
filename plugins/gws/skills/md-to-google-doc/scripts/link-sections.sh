#!/usr/bin/env bash
# Auto-link §N / §NB section references to their headings across native tabs.
#
# Run AFTER publishing tabs: builds a section-number -> heading map from a
# "findings" tab and links every §N reference in the other tabs to the matching
# heading (Docs Link.heading is tab-aware). Idempotent.
#
# Usage:
#   link-sections.sh <doc-id-or-url> [--target-tab <title-or-id>]
#                                    [--from-tab <title-or-id>]
#
# --target-tab: the tab holding the numbered sections. Default: the tab with
#               the most numbered-section headings.
# --from-tab:   only link references in this tab. Default: all other tabs.
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
	echo "Usage: $(basename "$0") <doc-id-or-url> [--target-tab <title-or-id>] [--from-tab <title-or-id>]" >&2
	exit 1
}

[[ $# -lt 1 ]] && usage
DOC_ID_OR_URL="$1"; shift
TARGET_ARG=""; FROM_ARG=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--target-tab) TARGET_ARG="$2"; shift 2 ;;
		--from-tab) FROM_ARG="$2"; shift 2 ;;
		*) echo "Unknown option: $1" >&2; usage ;;
	esac
done

if [[ "$DOC_ID_OR_URL" == *"docs.google.com"* ]]; then
	DOC_ID=$(echo "$DOC_ID_OR_URL" | sed -E 's|.*/d/([^/]+).*|\1|')
else
	DOC_ID="$DOC_ID_OR_URL"
fi

source "$SCRIPT_DIR/tabs.sh"   # resolve_tab_id / list_tabs

ARGS=()
[[ -n "$TARGET_ARG" ]] && ARGS+=(--target "$(resolve_tab_id "$DOC_ID" "$TARGET_ARG")")
[[ -n "$FROM_ARG" ]] && ARGS+=(--from "$(resolve_tab_id "$DOC_ID" "$FROM_ARG")")

TMP="./__tmp-linksec-$$-$RANDOM.json"
REQ="./__tmp-linksec-$$-$RANDOM-reqs.json"
trap 'rm -f "$TMP" "$REQ"' EXIT

gws docs documents get \
	--params "{\"documentId\": \"$DOC_ID\", \"includeTabsContent\": true}" 2>/dev/null > "$TMP"

python3 "$SCRIPT_DIR/link_sections.py" "$TMP" ${ARGS[@]+"${ARGS[@]}"} > "$REQ"
COUNT=$(python3 -c "import sys,json; print(len(json.load(open(sys.argv[1]))['requests']))" "$REQ")

if [[ "$COUNT" -eq 0 ]]; then
	echo "No §-references linked (no matching sections found)." >&2
	exit 0
fi

gws docs documents batchUpdate \
	--params "{\"documentId\": \"$DOC_ID\"}" \
	--json "$(cat "$REQ")" >/dev/null 2>&1

echo "Linked $COUNT section reference(s)."
