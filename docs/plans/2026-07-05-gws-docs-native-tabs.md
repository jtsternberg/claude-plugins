# gws Google Docs Native Tabs Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the gws plugin's Google Docs skills tab-aware: manage native Doc tabs (list/add/rename/delete), publish markdown into a *single* tab without destroying the others, and stop the existing publish path from silently wiping tabs.

**Architecture:** The Docs API (`docs.documents.batchUpdate`) fully supports tabs: `addDocumentTab`, `deleteTab`, `updateDocumentTabProperties`, and a `tabId` on every content request (`insertText`, `deleteContentRange`, `updateParagraphStyle`, …). The only hard limit — verified live on 2026-07-05 — is that the Drive media-upload path (`gws drive files update --upload x.md`), which the current `update.sh` uses, replaces the **whole document and deletes every tab except the first**. We keep Google's excellent server-side markdown→Doc conversion by using a **temp-doc replay** strategy: upload the markdown as a throwaway Google Doc (server converts it), read its structured JSON via `documents.get`, then replay that structure into the target tab via `batchUpdate` requests. Because the target tab is emptied first and elements are replayed in ascending order, target indices mirror source indices exactly — almost no index math.

**Tech Stack:** bash (skill scripts, matching existing `gws` plugin style: tabs for indentation, `set -euo pipefail`, account resolution via `account-common.sh`), Python 3 stdlib only (request generation + converters — no third-party deps, these run under system python3), `gws` CLI as the only API client.

**Repo:** `/Users/JT/Code/claude-plugins` (plugin: `plugins/gws/`). Remember the repo rule: **bump `plugins/gws/.claude-plugin/plugin.json` version (minor) in the final task.** Commit style from history: `gws: <summary> (vX.Y.Z)` for the version-bump commit; plain `gws: <summary>` for intermediate commits.

**Verified API facts you can rely on (tested live 2026-07-05 against a scratch doc):**
- `gws docs documents batchUpdate --json '{"requests":[{"addDocumentTab":{"tabProperties":{"title":"Next Steps","iconEmoji":"⭐","index":1}}}]}'` works and returns the new `tabId` (e.g. `t.15m7y3a5evn9`).
- `insertText`/`updateParagraphStyle` with `"tabId"` inside `location`/`range` write into that specific tab.
- `gws docs documents get --params '{"documentId":"...","includeTabsContent":true}'` returns a `tabs[]` array, each with `tabProperties` (`tabId`, `title`, `iconEmoji`, `index`, `parentTabId`) and `documentTab.body`.
- `gws drive files update --upload file.md --upload-content-type text/markdown` **destroys all tabs but the first** (confirmed: a doc with 2 tabs came back with only `t.0`).
- Tabs can nest: child tabs live in `childTabs[]` under a parent tab.

---

## File Structure

```
plugins/gws/
├── skills/
│   ├── md-to-google-doc/
│   │   ├── SKILL.md                      # Modify: document guardrail + tab publish
│   │   ├── scripts/
│   │   │   ├── update.sh                 # Modify: multi-tab guardrail (+ --force)
│   │   │   ├── tab-update.sh             # Create: publish md into ONE tab
│   │   │   ├── replay_tab.py             # Create: source-doc JSON → batchUpdate requests
│   │   │   └── tabs.sh                   # Create: list/add/rename/delete tabs
│   │   └── tests/
│   │       ├── test_replay_tab.py        # Create: pure-python unit tests
│   │       ├── fixtures/tab-fixture.md   # Create: md exercising all supported elements
│   │       └── smoke-tabs.sh             # Create: live end-to-end test (scratch doc)
│   └── google-doc-to-md/
│       ├── SKILL.md                      # Modify: document --list-tabs / --tab
│       ├── scripts/
│       │   ├── download.sh               # Modify: --list-tabs and --tab <id|title>
│       │   └── docjson_to_md.py          # Create: Docs tab JSON → markdown
│       └── tests/
│           └── test_docjson_to_md.py     # Create: pure-python unit tests
└── .claude-plugin/plugin.json            # Modify: version bump (minor)
```

Responsibilities:
- `tabs.sh` — thin CRUD over `batchUpdate` tab requests + tab listing/resolution. Sourceable helpers used by `tab-update.sh` and `download.sh` (via `resolve_tab_id`).
- `replay_tab.py` — pure function core: `(source_doc_json, tab_id, clear_end) → [requests]`. No I/O besides argv/stdin/stdout, fully unit-testable offline.
- `tab-update.sh` — orchestration: temp doc upload → get JSON → replay → chunked batchUpdate → verify → trash temp.
- `docjson_to_md.py` — pure function core: `(tab documentTab JSON, lists) → markdown string`.

**Environment note for all live tests:** every script resolves the active gws account the same way existing scripts do (source `account-common.sh`, export `GOOGLE_WORKSPACE_CLI_CONFIG_DIR`). Run live smoke tests from any cwd — but remember `gws --upload` requires the uploaded file to be **inside the cwd**, so smoke scripts must `cd` to a scratch dir first and create their files there.

---

### Task 1: `tabs.sh` — tab CRUD helper

**Files:**
- Create: `plugins/gws/skills/md-to-google-doc/scripts/tabs.sh`
- Test: `plugins/gws/skills/md-to-google-doc/tests/smoke-tabs.sh` (created here, extended in Task 4)

No unit-testable pure logic here (it's all API calls), so this task is smoke-tested live at the end.

- [ ] **Step 1: Write `tabs.sh`**

```bash
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
	sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2
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

# Fetch doc tabs JSON (tabProperties only — cheap) to stdout.
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
```

- [ ] **Step 2: Make it executable and syntax-check**

Run: `chmod +x plugins/gws/skills/md-to-google-doc/scripts/tabs.sh && bash -n plugins/gws/skills/md-to-google-doc/scripts/tabs.sh && echo SYNTAX-OK`
Expected: `SYNTAX-OK`

- [ ] **Step 3: Start the live smoke test script**

Create `plugins/gws/skills/md-to-google-doc/tests/smoke-tabs.sh` (Task 4 appends the publish section):

```bash
#!/usr/bin/env bash
# Live smoke test for tabs.sh (and later tab-update.sh).
# Creates a scratch Google Doc on the ACTIVE gws account, exercises the tab
# helpers, and trashes the doc at the end. Requires: gws auth login done.
# Usage: bash smoke-tabs.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../scripts"

if [[ -z "${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-}" ]]; then
	source "$SCRIPTS/../../../scripts/account-common.sh"
	export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$(resolve_active_config)"
fi

WORK="$(mktemp -d /tmp/gws-tabs-smoke.XXXXXX)"
cd "$WORK"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

echo "== creating scratch doc =="
DOC_ID=$(gws docs documents create --json '{"title": "TMP gws-tabs smoke (safe to delete)"}' 2>/dev/null \
	| python3 -c "import sys,json; print(json.load(sys.stdin)['documentId'])")
[[ -n "$DOC_ID" ]] || fail "could not create scratch doc"
trap 'gws drive files update --params "{\"fileId\": \"$DOC_ID\"}" --json "{\"trashed\": true}" >/dev/null 2>&1; rm -rf "$WORK"; echo "== scratch doc trashed =="' EXIT

echo "== tabs.sh add =="
TAB_ID=$(bash "$SCRIPTS/tabs.sh" add "$DOC_ID" "Next Steps" --emoji "⭐" --index 1)
[[ "$TAB_ID" == t.* ]] || fail "add did not return a tabId (got: $TAB_ID)"
pass "added tab $TAB_ID"

echo "== tabs.sh list =="
LIST=$(bash "$SCRIPTS/tabs.sh" list "$DOC_ID")
echo "$LIST" | grep -q "Next Steps" || fail "list missing new tab: $LIST"
[[ $(echo "$LIST" | wc -l) -eq 2 ]] || fail "expected 2 tabs, got: $LIST"
pass "list shows 2 tabs"

echo "== tabs.sh rename =="
bash "$SCRIPTS/tabs.sh" rename "$DOC_ID" "Next Steps" "Action Items" >/dev/null
bash "$SCRIPTS/tabs.sh" list "$DOC_ID" | grep -q "Action Items" || fail "rename did not apply"
pass "renamed to Action Items"

echo "== tabs.sh delete =="
bash "$SCRIPTS/tabs.sh" delete "$DOC_ID" "$TAB_ID" --yes >/dev/null
[[ $(bash "$SCRIPTS/tabs.sh" list "$DOC_ID" | wc -l) -eq 1 ]] || fail "delete did not remove tab"
pass "deleted tab"

echo "ALL TAB CRUD CHECKS PASSED"
```

- [ ] **Step 4: Run the smoke test**

Run: `bash plugins/gws/skills/md-to-google-doc/tests/smoke-tabs.sh`
Expected: `ALL TAB CRUD CHECKS PASSED` and `== scratch doc trashed ==`. If `resolve_tab_id`'s title matching misbehaves, fix and re-run — the script is idempotent and self-cleaning.

- [ ] **Step 5: Commit**

```bash
cd /Users/JT/Code/claude-plugins
git add plugins/gws/skills/md-to-google-doc/scripts/tabs.sh plugins/gws/skills/md-to-google-doc/tests/smoke-tabs.sh
git commit -m "gws: add tabs.sh — native Docs tab list/add/rename/delete"
```

---

### Task 2: Multi-tab guardrail in `update.sh`

The current publish (`gws drive files update --upload`) silently deletes every tab but the first. Verified live. This task makes that impossible to do by accident.

**Files:**
- Modify: `plugins/gws/skills/md-to-google-doc/scripts/update.sh`

- [ ] **Step 1: Add `--force` flag parsing**

In `update.sh`, replace the current two-positional argument handling:

```bash
[[ $# -lt 2 ]] && usage

FILE="$1"
DOC_ID_OR_URL="$2"
```

with:

```bash
[[ $# -lt 2 ]] && usage

FILE="$1"
DOC_ID_OR_URL="$2"
shift 2
FORCE=false
while [[ $# -gt 0 ]]; do
	case "$1" in
		--force) FORCE=true; shift ;;
		*) echo "Unknown option: $1" >&2; usage ;;
	esac
done
```

Also update the `usage()` text to `Usage: $(basename "$0") <markdown-file> <doc-id-or-url> [--force]`.

- [ ] **Step 2: Add the tab-count check**

Insert immediately **after** the doc-ID extraction block (`DOC_ID=$(...)`) and **before** the temp-file/clean section:

```bash
# GUARDRAIL: this update replaces the ENTIRE document via Drive media upload,
# which deletes every native Docs tab except the first (verified 2026-07-05).
# Refuse to run against a multi-tab doc unless --force is given.
TAB_COUNT=$(gws docs documents get \
	--params "{\"documentId\": \"$DOC_ID\", \"includeTabsContent\": true, \"fields\": \"tabs\"}" 2>/dev/null \
	| python3 -c '
import sys, json
def count(tabs):
	return sum(1 + count(t.get("childTabs") or []) for t in tabs or [])
print(count(json.load(sys.stdin).get("tabs")))
' 2>/dev/null || echo "1")

if [[ "$TAB_COUNT" -gt 1 && "$FORCE" != true ]]; then
	echo "ERROR: This doc has $TAB_COUNT native tabs. A full update would DELETE every tab but the first." >&2
	echo "  - To update a single tab (preserving the others): scripts/tab-update.sh <file.md> <doc> --tab <title-or-id>" >&2
	echo "  - To replace the whole doc anyway (destroys tabs):  re-run with --force" >&2
	exit 1
fi
```

- [ ] **Step 3: Syntax-check and behavior-check on a single-tab doc**

Run: `bash -n plugins/gws/skills/md-to-google-doc/scripts/update.sh && echo SYNTAX-OK`
Expected: `SYNTAX-OK`

Then verify the guardrail live (temporary manual check — automated in Task 4's smoke test): create a scratch doc, add a tab with `tabs.sh add`, attempt `update.sh` on it:

```bash
cd "$(mktemp -d /tmp/gws-guard.XXXXXX)"
printf '# t\n' > t.md
DOC_ID=$(gws docs documents create --json '{"title": "TMP guardrail test"}' 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['documentId'])")
bash /Users/JT/Code/claude-plugins/plugins/gws/skills/md-to-google-doc/scripts/tabs.sh add "$DOC_ID" "Second" >/dev/null
bash /Users/JT/Code/claude-plugins/plugins/gws/skills/md-to-google-doc/scripts/update.sh t.md "$DOC_ID"; echo "exit=$?"
gws drive files update --params "{\"fileId\": \"$DOC_ID\"}" --json '{"trashed": true}' >/dev/null 2>&1
```

Expected: the `update.sh` call prints the `ERROR: This doc has 2 native tabs...` message and `exit=1`. (Exit is non-fatal to the test shell because it's the last command before `echo`.)

- [ ] **Step 4: Commit**

```bash
cd /Users/JT/Code/claude-plugins
git add plugins/gws/skills/md-to-google-doc/scripts/update.sh
git commit -m "gws: refuse full-doc update on multi-tab docs without --force"
```

---

### Task 3: `replay_tab.py` — source-doc JSON → batchUpdate requests

The core of tab-safe publishing. Pure Python, stdlib only, unit-tested offline.

**Contract:** `python3 replay_tab.py <source-doc.json> <target-tab-id> --clear-end <N>` reads a `documents.get` JSON (the temp doc, single tab, so `body` is populated at top level), and prints `{"requests": [...]}` to stdout:
1. If `N > 2`: a `deleteContentRange` for `1..N-1` in the target tab (a tab's content can never be fully deleted — index 0 sectionBreak and the final newline remain, so an "empty" tab has body end index 2).
2. Replay requests for every structural element of the source body, all carrying `"tabId"`.

**The index-mirroring invariant:** the target tab starts empty (`"\n"`, body end 2) — identical in shape to an empty source doc. Requests are emitted in ascending source-index order, and every insert reproduces the source content exactly, so after each paragraph/table is settled, target indices equal source indices. Consequences:
- Insert each paragraph's text at the paragraph's source `startIndex`; apply styles using source ranges verbatim.
- **Skip the final newline of each container** (body, and each table cell): the target container already ends with an un-deletable `"\n"` that plays that role.
- **Tables:** `insertTable` inserts a newline *before* the table (API: "the table start index is location + 1"). So when a paragraph is immediately followed by a table, insert that paragraph's text *without* its trailing newline, then `insertTable` at `table.startIndex - 1` — the API-inserted newline lands exactly where the paragraph's newline was. A freshly inserted empty R×C table has the identical index skeleton as the source table's empty skeleton, so cell content also mirrors: walk cells in order, same skip-final-newline rule per cell.
- **Bullets:** `createParagraphBullets` derives nesting from leading tab characters and removes them. For each *group* of consecutive paragraphs sharing a `bullet.listId`: insert each paragraph's text prefixed with `nestingLevel` tab chars, then emit ONE `createParagraphBullets` over the whole group's range extended by the total inserted tabs. One request per group (not per paragraph) keeps numbered lists numbering continuously. After the request removes the tabs, indices are back in mirror.
- **Out of scope (log to stderr, skip):** inline images/objects (`inlineObjectElement` — their `contentUri` is auth-gated so `insertInlineImage` can't consume it), `horizontalRule`, footnotes, `person`/`richLink` chips. The element's text is replaced with nothing; a `WARNING: skipped <kind>` goes to stderr.

**Files:**
- Create: `plugins/gws/skills/md-to-google-doc/scripts/replay_tab.py`
- Test: `plugins/gws/skills/md-to-google-doc/tests/test_replay_tab.py`

- [ ] **Step 1: Write the failing unit tests**

Create `plugins/gws/skills/md-to-google-doc/tests/test_replay_tab.py`:

```python
#!/usr/bin/env python3
"""Unit tests for replay_tab.py request generation. Run:
python3 -m unittest plugins/gws/skills/md-to-google-doc/tests/test_replay_tab.py -v
(from repo root; test adds the scripts dir to sys.path)
"""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from replay_tab import build_requests  # noqa: E402

TAB = "t.testtab"


def para(start, runs, style="NORMAL_TEXT", bullet=None):
    """Build a paragraph structural element from (text, textStyle) runs."""
    elements, idx = [], start
    for text, tstyle in runs:
        elements.append({
            "startIndex": idx, "endIndex": idx + len(text),
            "textRun": {"content": text, "textStyle": tstyle or {}},
        })
        idx += len(text)
    p = {"paragraphStyle": {"namedStyleType": style}, "elements": elements}
    if bullet:
        p["bullet"] = bullet
    return {"startIndex": start, "endIndex": idx, "paragraph": p}


def doc(elements, lists=None):
    return {"body": {"content":
            [{"startIndex": 0, "endIndex": 1, "sectionBreak": {}}] + elements},
            "lists": lists or {}}


class TestClear(unittest.TestCase):
    def test_clear_emitted_when_tab_has_content(self):
        d = doc([para(1, [("\n", {})])])
        reqs = build_requests(d, TAB, clear_end=10)
        self.assertEqual(reqs[0], {"deleteContentRange": {"range": {
            "startIndex": 1, "endIndex": 9, "tabId": TAB}}})

    def test_no_clear_when_tab_empty(self):
        d = doc([para(1, [("\n", {})])])
        reqs = build_requests(d, TAB, clear_end=2)
        self.assertTrue(all("deleteContentRange" not in r for r in reqs))


class TestParagraphs(unittest.TestCase):
    def test_heading_then_body_with_bold(self):
        d = doc([
            para(1, [("Heading\n", {})], style="HEADING_1"),
            para(9, [("ab ", {"bold": True}), ("cd\n", {})]),
        ])
        reqs = build_requests(d, TAB, clear_end=2)
        # Insert heading text (with newline — not the last paragraph)
        self.assertIn({"insertText": {"location": {"index": 1, "tabId": TAB},
                                      "text": "Heading\n"}}, reqs)
        # Heading style over source range
        self.assertIn({"updateParagraphStyle": {
            "range": {"startIndex": 1, "endIndex": 9, "tabId": TAB},
            "paragraphStyle": {"namedStyleType": "HEADING_1"},
            "fields": "namedStyleType"}}, reqs)
        # Last paragraph: trailing newline skipped
        self.assertIn({"insertText": {"location": {"index": 9, "tabId": TAB},
                                      "text": "ab cd"}}, reqs)
        # Bold run styled over its source range
        self.assertIn({"updateTextStyle": {
            "range": {"startIndex": 9, "endIndex": 12, "tabId": TAB},
            "textStyle": {"bold": True}, "fields": "bold"}}, reqs)

    def test_link_style(self):
        d = doc([para(1, [("x\n", {"link": {"url": "https://e.com"}})])])
        reqs = build_requests(d, TAB, clear_end=2)
        style_reqs = [r for r in reqs if "updateTextStyle" in r]
        self.assertEqual(len(style_reqs), 1)
        self.assertEqual(style_reqs[0]["updateTextStyle"]["textStyle"],
                         {"link": {"url": "https://e.com"}})
        self.assertEqual(style_reqs[0]["updateTextStyle"]["fields"], "link")

    def test_empty_final_paragraph_inserts_nothing(self):
        d = doc([para(1, [("Hello\n", {})]), para(7, [("\n", {})])])
        reqs = build_requests(d, TAB, clear_end=2)
        inserts = [r["insertText"]["text"] for r in reqs if "insertText" in r]
        self.assertEqual(inserts, ["Hello\n"])


class TestBullets(unittest.TestCase):
    def _lists(self, glyph):
        return {"L1": {"listProperties": {"nestingLevels": [{"glyphType": glyph}]}}}

    def test_bullet_group_single_request(self):
        d = doc([
            para(1, [("one\n", {})], bullet={"listId": "L1"}),
            para(5, [("two\n", {})], bullet={"listId": "L1"}),
            para(9, [("after\n", {})]),
        ], lists=self._lists("GLYPH_TYPE_UNSPECIFIED"))
        reqs = build_requests(d, TAB, clear_end=2)
        bullets = [r for r in reqs if "createParagraphBullets" in r]
        self.assertEqual(len(bullets), 1)  # ONE request for the group
        self.assertEqual(bullets[0]["createParagraphBullets"]["bulletPreset"],
                         "BULLET_DISC_CIRCLE_SQUARE")
        # Range covers both paragraphs (no nesting → no tab padding)
        self.assertEqual(bullets[0]["createParagraphBullets"]["range"],
                         {"startIndex": 1, "endIndex": 9, "tabId": TAB})

    def test_numbered_preset(self):
        d = doc([para(1, [("one\n", {})], bullet={"listId": "L1"}),
                 para(5, [("\n", {})])],
                lists=self._lists("DECIMAL"))
        reqs = build_requests(d, TAB, clear_end=2)
        bullets = [r for r in reqs if "createParagraphBullets" in r]
        self.assertEqual(bullets[0]["createParagraphBullets"]["bulletPreset"],
                         "NUMBERED_DECIMAL_ALPHA_ROMAN")

    def test_nested_bullet_gets_tab_prefix_and_extended_range(self):
        d = doc([
            para(1, [("top\n", {})], bullet={"listId": "L1"}),
            para(5, [("sub\n", {})], bullet={"listId": "L1", "nestingLevel": 1}),
            para(9, [("\n", {})]),
        ], lists=self._lists("GLYPH_TYPE_UNSPECIFIED"))
        reqs = build_requests(d, TAB, clear_end=2)
        inserts = [r["insertText"]["text"] for r in reqs if "insertText" in r]
        self.assertIn("top\n", inserts)
        self.assertIn("\tsub\n", inserts)  # nesting via leading tab
        bullets = [r for r in reqs if "createParagraphBullets" in r][0]
        # group range 1..9 extended by the 1 inserted tab char
        self.assertEqual(bullets["createParagraphBullets"]["range"],
                         {"startIndex": 1, "endIndex": 10, "tabId": TAB})


class TestTables(unittest.TestCase):
    def _table_doc(self):
        # "P\n" (1-3), table (3-13): 1 row × 1 col, cell text "x\n", then "\n" (13-14)
        # Index skeleton for a 1x1 table starting at 3:
        #   3 table start, 4 row start, 5 cell start, cell paragraph "x\n" at 5-7,
        #   table endIndex 8... exact skeleton numbers matter only for OUR fixture
        # consistency: the generator reads whatever indices the fixture declares.
        cell_para = para(5, [("x\n", {})])
        return doc([
            para(1, [("P\n", {})]),
            {"startIndex": 3, "endIndex": 8, "table": {
                "rows": 1, "columns": 1,
                "tableRows": [{"startIndex": 4, "endIndex": 8, "tableCells": [
                    {"startIndex": 5, "endIndex": 8, "content": [cell_para]},
                ]}]}},
            para(8, [("\n", {})]),
        ])

    def test_table_replay(self):
        reqs = build_requests(self._table_doc(), TAB, clear_end=2)
        # Paragraph before table loses its newline (insertTable provides it)
        self.assertIn({"insertText": {"location": {"index": 1, "tabId": TAB},
                                      "text": "P"}}, reqs)
        self.assertIn({"insertTable": {"rows": 1, "columns": 1,
                       "location": {"index": 2, "tabId": TAB}}}, reqs)
        # Cell text inserted at source index, final cell newline skipped
        self.assertIn({"insertText": {"location": {"index": 5, "tabId": TAB},
                                      "text": "x"}}, reqs)
        # Ordering: para text before table, table before cell text
        kinds = [next(iter(r)) for r in reqs]
        self.assertLess(kinds.index("insertTable"),
                        [i for i, r in enumerate(reqs)
                         if r.get("insertText", {}).get("text") == "x"][0])


class TestSkips(unittest.TestCase):
    def test_inline_object_skipped(self):
        d = doc([{"startIndex": 1, "endIndex": 3, "paragraph": {
            "paragraphStyle": {"namedStyleType": "NORMAL_TEXT"},
            "elements": [
                {"startIndex": 1, "endIndex": 2,
                 "inlineObjectElement": {"inlineObjectId": "obj1"}},
                {"startIndex": 2, "endIndex": 3,
                 "textRun": {"content": "\n", "textStyle": {}}},
            ]}}])
        reqs = build_requests(d, TAB, clear_end=2)  # must not raise
        inserts = [r["insertText"]["text"] for r in reqs if "insertText" in r]
        self.assertEqual(inserts, [])  # image dropped, final newline skipped


if __name__ == "__main__":
    unittest.main()
```

**Note on the skipped-element index gap:** when a run is skipped (image), the mirror invariant breaks for everything after it — the target is 1 char shorter than the source. `build_requests` must track a running `offset` (target = source − skipped_chars_so_far) and apply it to every subsequent location/range. The tests above don't exercise post-skip content, but implement offset tracking anyway; the fixture md in Task 4 has no images, and the stderr warning tells the user fidelity may drift.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/JT/Code/claude-plugins && python3 -m unittest plugins.gws.skills.md-to-google-doc.tests.test_replay_tab -v 2>&1 | tail -3`

Note: the path has hyphens so module syntax won't work — run by file path instead:
`python3 -m unittest discover -s plugins/gws/skills/md-to-google-doc/tests -p 'test_replay_tab.py' -v`
Expected: `ImportError: No module named 'replay_tab'` (or similar) — confirming the tests run and fail for the right reason.

- [ ] **Step 3: Write `replay_tab.py`**

Create `plugins/gws/skills/md-to-google-doc/scripts/replay_tab.py`:

```python
#!/usr/bin/env python3
"""Generate Docs batchUpdate requests that replay a source document's body
into a target tab.

Usage: replay_tab.py <source-doc.json> <target-tab-id> [--clear-end N]

Reads the documents.get JSON of a single-tab source doc (body at top level),
prints {"requests": [...]} to stdout. All requests carry the target tabId.
If --clear-end N is given and N > 2, a deleteContentRange for 1..N-1 is
emitted first (empties the target tab; index 0 and the final newline are
un-deletable).

Strategy: the target tab is empty, elements are replayed in ascending source
order, so target indices mirror source indices (see plan doc for the proof
sketch). Skipped elements (images, chips) shift the mirror; a running offset
compensates.
"""
import json
import sys

UNORDERED_GLYPHS = {"GLYPH_TYPE_UNSPECIFIED", "NONE", ""}
BULLET_UNORDERED = "BULLET_DISC_CIRCLE_SQUARE"
BULLET_ORDERED = "NUMBERED_DECIMAL_ALPHA_ROMAN"

# textStyle fields we replay (order fixed for deterministic "fields" strings)
TEXT_STYLE_FIELDS = ["bold", "italic", "underline", "strikethrough",
                     "baselineOffset", "fontSize", "weightedFontFamily",
                     "foregroundColor", "backgroundColor", "link"]
PARA_STYLE_FIELDS = ["namedStyleType", "alignment", "indentStart",
                     "indentEnd", "indentFirstLine", "spaceAbove",
                     "spaceBelow"]


def warn(msg):
    print("WARNING: %s" % msg, file=sys.stderr)


class Replayer:
    def __init__(self, doc, tab_id):
        self.doc = doc
        self.tab = tab_id
        self.reqs = []
        self.offset = 0  # target index = source index + offset (skips make it negative)

    # -- helpers ----------------------------------------------------------
    def t(self, src_index):
        return src_index + self.offset

    def bullet_preset(self, list_id):
        props = (self.doc.get("lists", {}).get(list_id, {})
                 .get("listProperties", {}))
        levels = props.get("nestingLevels") or [{}]
        glyph = levels[0].get("glyphType", "")
        if glyph in UNORDERED_GLYPHS or "glyphSymbol" in levels[0]:
            return BULLET_UNORDERED
        return BULLET_ORDERED

    def filtered_style(self, style, allowed):
        picked = {k: style[k] for k in allowed if k in style}
        return picked, ",".join(k for k in allowed if k in style)

    # -- paragraph --------------------------------------------------------
    def paragraph_text(self, p_elem):
        """Concatenated textRun content; warns on skipped element kinds."""
        parts = []
        for el in p_elem["paragraph"].get("elements", []):
            if "textRun" in el:
                parts.append(el["textRun"].get("content", ""))
            else:
                kind = next((k for k in el if k not in
                             ("startIndex", "endIndex")), "unknown")
                warn("skipped unsupported element '%s' at index %s"
                     % (kind, el.get("startIndex")))
                self.offset -= (el.get("endIndex", 0)
                                - el.get("startIndex", 0))
        return "".join(parts)

    def replay_paragraph(self, p_elem, drop_trailing_newline, tab_prefix=0):
        text = self.paragraph_text(p_elem)
        if drop_trailing_newline and text.endswith("\n"):
            text = text[:-1]
        insert_at = self.t(p_elem["startIndex"])
        text = "\t" * tab_prefix + text
        if text:
            self.reqs.append({"insertText": {
                "location": {"index": insert_at, "tabId": self.tab},
                "text": text}})
        # Per-run text styles (source ranges + offset; clamp off the dropped \n)
        for el in p_elem["paragraph"].get("elements", []):
            if "textRun" not in el:
                continue
            style, fields = self.filtered_style(
                el["textRun"].get("textStyle", {}), TEXT_STYLE_FIELDS)
            if not fields:
                continue
            start, end = el["startIndex"], el["endIndex"]
            if drop_trailing_newline and end == p_elem["endIndex"]:
                end -= 1
            if end <= start:
                continue
            self.reqs.append({"updateTextStyle": {
                "range": {"startIndex": self.t(start) + tab_prefix,
                          "endIndex": self.t(end) + tab_prefix,
                          "tabId": self.tab},
                "textStyle": style, "fields": fields}})
        # Paragraph style (skip plain NORMAL_TEXT with no other props)
        pstyle, pfields = self.filtered_style(
            p_elem["paragraph"].get("paragraphStyle", {}), PARA_STYLE_FIELDS)
        if pfields and not (pfields == "namedStyleType"
                            and pstyle.get("namedStyleType") == "NORMAL_TEXT"):
            end = p_elem["endIndex"]
            if drop_trailing_newline:
                end -= 1
            self.reqs.append({"updateParagraphStyle": {
                "range": {"startIndex": self.t(p_elem["startIndex"]),
                          "endIndex": self.t(max(end, p_elem["startIndex"] + 1))
                                      + tab_prefix,
                          "tabId": self.tab},
                "paragraphStyle": pstyle, "fields": pfields}})

    # -- containers -------------------------------------------------------
    def replay_container(self, content):
        """Replay a list of structural elements (body or a table cell).
        The container's final newline already exists in the target."""
        # Identify paragraph groups sharing a bullet listId so numbered lists
        # get ONE createParagraphBullets request (continuous numbering).
        i = 0
        elems = [e for e in content if "sectionBreak" not in e]
        while i < len(elems):
            e = elems[i]
            is_last = (i == len(elems) - 1)
            if "table" in e:
                self.replay_table(e)
                i += 1
            elif "paragraph" in e and e["paragraph"].get("bullet"):
                # collect the bullet group
                list_id = e["paragraph"]["bullet"].get("listId")
                group = []
                while (i < len(elems) and "paragraph" in elems[i]
                       and elems[i]["paragraph"].get("bullet", {})
                       .get("listId") == list_id):
                    group.append((elems[i], i == len(elems) - 1))
                    i += 1
                total_tabs = 0
                for p_elem, last in group:
                    lvl = (p_elem["paragraph"]["bullet"]
                           .get("nestingLevel", 0))
                    self.replay_paragraph(p_elem, drop_trailing_newline=last,
                                          tab_prefix=lvl)
                    # NOTE: tab_prefix shifts THIS paragraph only; the range
                    # extension below accounts for all inserted tabs.
                    total_tabs += lvl
                self.reqs.append({"createParagraphBullets": {
                    "range": {"startIndex": self.t(group[0][0]["startIndex"]),
                              "endIndex": self.t(group[-1][0]["endIndex"])
                                          + total_tabs,
                              "tabId": self.tab},
                    "bulletPreset": self.bullet_preset(list_id)}})
            elif "paragraph" in e:
                # Peek: paragraph immediately followed by a table loses its
                # trailing \n (insertTable supplies it).
                next_is_table = (i + 1 < len(elems)
                                 and "table" in elems[i + 1])
                self.replay_paragraph(
                    e, drop_trailing_newline=is_last or next_is_table)
                i += 1
            else:
                kind = next((k for k in e if k not in
                             ("startIndex", "endIndex")), "unknown")
                warn("skipped structural element '%s'" % kind)
                self.offset -= e["endIndex"] - e["startIndex"]
                i += 1

    def replay_table(self, t_elem):
        table = t_elem["table"]
        self.reqs.append({"insertTable": {
            "rows": table["rows"], "columns": table["columns"],
            "location": {"index": self.t(t_elem["startIndex"]) - 1,
                         "tabId": self.tab}}})
        for row in table.get("tableRows", []):
            for cell in row.get("tableCells", []):
                self.replay_container(cell.get("content", []))

    # -- entry ------------------------------------------------------------
    def run(self, clear_end):
        if clear_end and clear_end > 2:
            self.reqs.append({"deleteContentRange": {"range": {
                "startIndex": 1, "endIndex": clear_end - 1,
                "tabId": self.tab}}})
        self.replay_container(self.doc["body"]["content"])
        return self.reqs


def build_requests(doc, tab_id, clear_end=0):
    return Replayer(doc, tab_id).run(clear_end)


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 1
    with open(argv[1]) as f:
        doc = json.load(f)
    tab_id = argv[2]
    clear_end = 0
    if "--clear-end" in argv:
        clear_end = int(argv[argv.index("--clear-end") + 1])
    print(json.dumps({"requests": build_requests(doc, tab_id, clear_end)}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/JT/Code/claude-plugins && python3 -m unittest discover -s plugins/gws/skills/md-to-google-doc/tests -p 'test_replay_tab.py' -v`
Expected: all tests PASS. If a test fails on an ordering/index detail, fix `replay_tab.py` (the tests encode the intended contract).

- [ ] **Step 5: Commit**

```bash
cd /Users/JT/Code/claude-plugins
git add plugins/gws/skills/md-to-google-doc/scripts/replay_tab.py plugins/gws/skills/md-to-google-doc/tests/test_replay_tab.py
git commit -m "gws: add replay_tab.py — doc JSON to tab-scoped batchUpdate requests"
```

---

### Task 4: `tab-update.sh` — publish markdown into one tab

**Files:**
- Create: `plugins/gws/skills/md-to-google-doc/scripts/tab-update.sh`
- Create: `plugins/gws/skills/md-to-google-doc/tests/fixtures/tab-fixture.md`
- Modify: `plugins/gws/skills/md-to-google-doc/tests/smoke-tabs.sh` (extend)

- [ ] **Step 1: Create the fixture markdown**

Create `plugins/gws/skills/md-to-google-doc/tests/fixtures/tab-fixture.md`:

```markdown
# Fixture Heading

Intro paragraph with **bold**, *italic*, and a [link](https://example.com).

## Second Level

- bullet one
- bullet two
  - nested bullet

1. first
2. second

| Col A | Col B |
| ----- | ----- |
| a1    | b1    |
| a2    | b2    |

Final paragraph.
```

- [ ] **Step 2: Write `tab-update.sh`**

```bash
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
```

- [ ] **Step 3: Syntax check**

Run: `chmod +x plugins/gws/skills/md-to-google-doc/scripts/tab-update.sh && bash -n plugins/gws/skills/md-to-google-doc/scripts/tab-update.sh && echo SYNTAX-OK`
Expected: `SYNTAX-OK`

- [ ] **Step 4: Extend the smoke test with the publish flow**

In `tests/smoke-tabs.sh`, replace the final line `echo "ALL TAB CRUD CHECKS PASSED"` with:

```bash
echo "ALL TAB CRUD CHECKS PASSED"

echo "== tab-update.sh publish into a tab =="
TAB2_ID=$(bash "$SCRIPTS/tabs.sh" add "$DOC_ID" "Publish Target")
cp "$SCRIPT_DIR/fixtures/tab-fixture.md" ./fixture.md
URL=$(bash "$SCRIPTS/tab-update.sh" ./fixture.md "$DOC_ID" --tab "Publish Target")
echo "$URL" | grep -q "tab=$TAB2_ID" || fail "unexpected URL: $URL"
pass "published fixture into $TAB2_ID"

echo "== verify tab content and isolation =="
gws docs documents get \
	--params "{\"documentId\": \"$DOC_ID\", \"includeTabsContent\": true}" 2>/dev/null > verify.json
python3 - verify.json "$TAB2_ID" <<'PYEOF'
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

d = json.load(open(sys.argv[1]))
tabs = {t["tabProperties"]["tabId"]: t for t in d["tabs"]}
assert len(tabs) == 2, "expected 2 tabs, got %d" % len(tabs)
target = text_of(tabs[sys.argv[2]]["documentTab"]["body"]["content"])
for needle in ("Fixture Heading", "bullet one", "nested bullet",
               "first", "a1", "b2", "Final paragraph"):
	assert needle in target, "missing %r in published tab" % needle
# heading style survived
paras = tabs[sys.argv[2]]["documentTab"]["body"]["content"]
h1 = [p for p in paras if p.get("paragraph", {})
      .get("paragraphStyle", {}).get("namedStyleType") == "HEADING_1"]
assert h1, "no HEADING_1 paragraph in published tab"
# a table exists
assert any("table" in p for p in paras), "no table in published tab"
# other tab untouched (still the empty default first tab)
first = [t for tid, t in tabs.items() if tid != sys.argv[2]][0]
assert text_of(first["documentTab"]["body"]["content"]).strip() == "", \
	"first tab was modified!"
print("PUBLISH VERIFY OK")
PYEOF
pass "tab content correct, sibling tab untouched"

echo "== re-publish (idempotent overwrite) =="
bash "$SCRIPTS/tab-update.sh" ./fixture.md "$DOC_ID" --tab "$TAB2_ID" >/dev/null
pass "re-publish into same tab succeeded"

echo "== guardrail: update.sh refuses multi-tab doc =="
printf '# nope\n' > nope.md
if bash "$SCRIPTS/update.sh" nope.md "$DOC_ID" 2>/dev/null; then
	fail "update.sh should have refused a 2-tab doc"
fi
pass "update.sh guardrail fired"

echo "ALL SMOKE CHECKS PASSED"
```

- [ ] **Step 5: Run the full smoke test**

Run: `bash plugins/gws/skills/md-to-google-doc/tests/smoke-tabs.sh`
Expected: `ALL SMOKE CHECKS PASSED` and `== scratch doc trashed ==`.

**Likely first-run failure points and what they mean:**
- `insertTable` index errors ("Index N must be less than the end index") → the table-location rule (`startIndex - 1`) or the preceding-paragraph newline-drop is off; inspect `$STEM-src.json`'s actual table indices from the converted fixture and adjust `replay_tab.py` + its unit-test fixture to match reality. The unit tests encode our model of the API; the smoke test is the ground truth. Update both together.
- Bullet numbering restarting at 1 for the ordered list → the grouping logic split the group; check consecutive-listId detection.
- `createParagraphBullets` range errors → tab-prefix extension math; remember only nested paragraphs contribute prefix tabs.

- [ ] **Step 6: Commit**

```bash
cd /Users/JT/Code/claude-plugins
git add plugins/gws/skills/md-to-google-doc/scripts/tab-update.sh \
        plugins/gws/skills/md-to-google-doc/tests/fixtures/tab-fixture.md \
        plugins/gws/skills/md-to-google-doc/tests/smoke-tabs.sh
git commit -m "gws: add tab-update.sh — publish markdown into one Doc tab, others preserved"
```

---

### Task 5: `google-doc-to-md` — list tabs and export a single tab

**Files:**
- Create: `plugins/gws/skills/google-doc-to-md/scripts/docjson_to_md.py`
- Modify: `plugins/gws/skills/google-doc-to-md/scripts/download.sh`
- Test: `plugins/gws/skills/google-doc-to-md/tests/test_docjson_to_md.py`

- [ ] **Step 1: Write the failing unit tests**

Create `plugins/gws/skills/google-doc-to-md/tests/test_docjson_to_md.py`:

```python
#!/usr/bin/env python3
"""Unit tests for docjson_to_md.py. Run:
python3 -m unittest discover -s plugins/gws/skills/google-doc-to-md/tests -p 'test_docjson_to_md.py' -v
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from docjson_to_md import tab_to_markdown  # noqa: E402


def para(text_runs, style="NORMAL_TEXT", bullet=None):
    elements = [{"textRun": {"content": t, "textStyle": s or {}}}
                for t, s in text_runs]
    p = {"paragraphStyle": {"namedStyleType": style}, "elements": elements}
    if bullet:
        p["bullet"] = bullet
    return {"paragraph": p}


def body(elements):
    return {"documentTab": {"body": {"content": elements}}}


class TestBasics(unittest.TestCase):
    def test_headings_and_text(self):
        md = tab_to_markdown(body([
            para([("Title\n", {})], style="HEADING_1"),
            para([("Body text\n", {})]),
            para([("Sub\n", {})], style="HEADING_2"),
        ]), lists={})
        self.assertEqual(md, "# Title\n\nBody text\n\n## Sub\n")

    def test_inline_styles(self):
        md = tab_to_markdown(body([
            para([("plain ", {}), ("bold", {"bold": True}),
                  (" ", {}), ("it", {"italic": True}),
                  (" ", {}),
                  ("lnk", {"link": {"url": "https://e.com"}}), ("\n", {})]),
        ]), lists={})
        self.assertEqual(md, "plain **bold** *it* [lnk](https://e.com)\n")

    def test_bullets(self):
        lists = {"L1": {"listProperties": {"nestingLevels": [
            {"glyphType": "GLYPH_TYPE_UNSPECIFIED"}]}}}
        md = tab_to_markdown(body([
            para([("one\n", {})], bullet={"listId": "L1"}),
            para([("sub\n", {})], bullet={"listId": "L1", "nestingLevel": 1}),
        ]), lists=lists)
        self.assertEqual(md, "- one\n  - sub\n")

    def test_numbered(self):
        lists = {"L1": {"listProperties": {"nestingLevels": [
            {"glyphType": "DECIMAL"}]}}}
        md = tab_to_markdown(body([
            para([("a\n", {})], bullet={"listId": "L1"}),
            para([("b\n", {})], bullet={"listId": "L1"}),
        ]), lists=lists)
        self.assertEqual(md, "1. a\n1. b\n")

    def test_table(self):
        cell = lambda t: {"content": [para([(t + "\n", {})])]}
        md = tab_to_markdown(body([
            {"table": {"rows": 2, "columns": 2, "tableRows": [
                {"tableCells": [cell("H1"), cell("H2")]},
                {"tableCells": [cell("a"), cell("b")]},
            ]}},
        ]), lists={})
        self.assertEqual(
            md, "| H1 | H2 |\n| --- | --- |\n| a | b |\n")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/JT/Code/claude-plugins && python3 -m unittest discover -s plugins/gws/skills/google-doc-to-md/tests -p 'test_docjson_to_md.py' -v`
Expected: import error (module doesn't exist yet).

- [ ] **Step 3: Write `docjson_to_md.py`**

Create `plugins/gws/skills/google-doc-to-md/scripts/docjson_to_md.py`:

```python
#!/usr/bin/env python3
"""Convert one tab of a documents.get(includeTabsContent=true) JSON to markdown.

Usage: docjson_to_md.py <doc.json> <tab-id>
Prints markdown to stdout. Supports headings, bold/italic/strikethrough,
links, bullet/numbered lists (with nesting), and tables. Everything else
degrades to plain text.
"""
import json
import sys

HEADINGS = {"HEADING_1": "#", "HEADING_2": "##", "HEADING_3": "###",
            "HEADING_4": "####", "HEADING_5": "#####", "HEADING_6": "######",
            "TITLE": "#"}
UNORDERED_GLYPHS = {"GLYPH_TYPE_UNSPECIFIED", "NONE", ""}


def run_to_md(run):
    text = run.get("textRun", {}).get("content", "")
    style = run.get("textRun", {}).get("textStyle", {})
    stripped = text.rstrip("\n")
    trailing = text[len(stripped):]
    if not stripped:
        return text
    out = stripped
    if style.get("bold"):
        out = "**%s**" % out
    if style.get("italic"):
        out = "*%s*" % out
    if style.get("strikethrough"):
        out = "~~%s~~" % out
    if style.get("link", {}).get("url"):
        out = "[%s](%s)" % (out, style["link"]["url"])
    return out + trailing


def para_text(p):
    return "".join(run_to_md(el) for el in p.get("elements", [])
                   if "textRun" in el).rstrip("\n")


def is_ordered(lists, list_id):
    levels = (lists.get(list_id, {}).get("listProperties", {})
              .get("nestingLevels") or [{}])
    glyph = levels[0].get("glyphType", "")
    return glyph not in UNORDERED_GLYPHS and "glyphSymbol" not in levels[0]


def content_to_md(content, lists):
    blocks = []
    prev_kind = None  # "list" | "para" | "table"
    for e in content:
        if "paragraph" in e:
            p = e["paragraph"]
            text = para_text(p)
            bullet = p.get("bullet")
            if bullet:
                indent = "  " * bullet.get("nestingLevel", 0)
                marker = "1." if is_ordered(lists, bullet.get("listId")) else "-"
                line = "%s%s %s" % (indent, marker, text)
                if prev_kind == "list":
                    blocks[-1] += "\n" + line
                else:
                    blocks.append(line)
                prev_kind = "list"
            else:
                if not text:
                    continue
                style = p.get("paragraphStyle", {}).get("namedStyleType", "")
                prefix = HEADINGS.get(style)
                blocks.append(("%s %s" % (prefix, text)) if prefix else text)
                prev_kind = "para"
        elif "table" in e:
            rows = []
            for row in e["table"].get("tableRows", []):
                cells = [" ".join(
                    para_text(c["paragraph"])
                    for c in cell.get("content", []) if "paragraph" in c
                ).strip() for cell in row.get("tableCells", [])]
                rows.append("| %s |" % " | ".join(cells))
            if rows:
                sep = "| %s |" % " | ".join(
                    ["---"] * e["table"].get("columns", 1))
                blocks.append("\n".join([rows[0], sep] + rows[1:]))
            prev_kind = "table"
    return "\n\n".join(blocks) + "\n" if blocks else ""


def tab_to_markdown(tab, lists):
    return content_to_md(tab["documentTab"]["body"]["content"], lists)


def find_tab(tabs, tab_id):
    for t in tabs or []:
        if t.get("tabProperties", {}).get("tabId") == tab_id:
            return t
        hit = find_tab(t.get("childTabs"), tab_id)
        if hit:
            return hit


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 1
    with open(argv[1]) as f:
        doc = json.load(f)
    tab = find_tab(doc.get("tabs"), argv[2])
    if not tab:
        print("ERROR: tab not found: %s" % argv[2], file=sys.stderr)
        return 1
    lists = tab.get("documentTab", {}).get("lists", {}) or doc.get("lists", {})
    sys.stdout.write(tab_to_markdown(tab, lists))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

Note: per-tab `lists` live under `documentTab.lists` when tabs content is requested; fall back to the doc-level `lists` (the code above handles both).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/JT/Code/claude-plugins && python3 -m unittest discover -s plugins/gws/skills/google-doc-to-md/tests -p 'test_docjson_to_md.py' -v`
Expected: all PASS.

- [ ] **Step 5: Add `--list-tabs` and `--tab` to `download.sh`**

In `download.sh`, extend the option parser (currently handling `--title`):

```bash
OUTPUT=""
USE_TITLE=false
LIST_TABS=false
TAB_ARG=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--title) USE_TITLE=true; shift ;;
		--list-tabs) LIST_TABS=true; shift ;;
		--tab) TAB_ARG="$2"; shift 2 ;;
		-*) echo "Unknown option: $1" >&2; usage ;;
		*) OUTPUT="$1"; shift ;;
	esac
done
```

Update `usage()` to: `Usage: $(basename "$0") <doc-id-or-url> [output.md] [--title] [--list-tabs] [--tab <tab-title-or-id>]`.

Then, immediately **after** the auth check and doc-ID extraction (before the title fetch), add:

```bash
TABS_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../md-to-google-doc/scripts/tabs.sh"

if [[ "$LIST_TABS" == true ]]; then
	source "$TABS_SH"
	list_tabs "$DOC_ID"
	exit 0
fi

if [[ -n "$TAB_ARG" ]]; then
	source "$TABS_SH"
	TAB_ID=$(resolve_tab_id "$DOC_ID" "$TAB_ARG")
	[[ -z "$OUTPUT" ]] && OUTPUT="${DOC_ID}-${TAB_ID}.md"
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	TMP_JSON="./__tmp-tabdl-$$-$RANDOM.json"
	trap 'rm -f "$TMP_JSON"' EXIT
	gws docs documents get \
		--params "{\"documentId\": \"$DOC_ID\", \"includeTabsContent\": true}" 2>/dev/null > "$TMP_JSON"
	python3 "$SCRIPT_DIR/docjson_to_md.py" "$TMP_JSON" "$TAB_ID" > "$OUTPUT"
	[[ -s "$OUTPUT" ]] || { echo "ERROR: tab export produced empty file." >&2; exit 1; }
	echo "$OUTPUT"
	exit 0
fi
```

- [ ] **Step 6: Syntax check + live spot-check**

Run: `bash -n plugins/gws/skills/google-doc-to-md/scripts/download.sh && echo SYNTAX-OK`
Expected: `SYNTAX-OK`

Live spot-check (scratch doc, self-cleaning):

```bash
cd "$(mktemp -d /tmp/gws-dl.XXXXXX)"
DOC_ID=$(gws docs documents create --json '{"title": "TMP dl test"}' 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['documentId'])")
TABS=/Users/JT/Code/claude-plugins/plugins/gws/skills/md-to-google-doc/scripts/tabs.sh
DL=/Users/JT/Code/claude-plugins/plugins/gws/skills/google-doc-to-md/scripts/download.sh
TAB_ID=$(bash "$TABS" add "$DOC_ID" "Notes")
bash "$DL" "$DOC_ID" --list-tabs
printf '# Hi\n\nSome **bold** text.\n' > hi.md
bash /Users/JT/Code/claude-plugins/plugins/gws/skills/md-to-google-doc/scripts/tab-update.sh hi.md "$DOC_ID" --tab Notes
bash "$DL" "$DOC_ID" out.md --tab Notes
cat out.md
gws drive files update --params "{\"fileId\": \"$DOC_ID\"}" --json '{"trashed": true}' >/dev/null 2>&1
```

Expected: `--list-tabs` prints two lines; `out.md` contains `# Hi` and `**bold**`.

- [ ] **Step 7: Commit**

```bash
cd /Users/JT/Code/claude-plugins
git add plugins/gws/skills/google-doc-to-md/scripts/docjson_to_md.py \
        plugins/gws/skills/google-doc-to-md/scripts/download.sh \
        plugins/gws/skills/google-doc-to-md/tests/test_docjson_to_md.py
git commit -m "gws: google-doc-to-md — list tabs and export a single tab as markdown"
```

---

### Task 6: Documentation + version bump

**Files:**
- Modify: `plugins/gws/skills/md-to-google-doc/SKILL.md`
- Modify: `plugins/gws/skills/google-doc-to-md/SKILL.md`
- Modify: `plugins/gws/.claude-plugin/plugin.json` (minor version bump)

- [ ] **Step 1: Update `md-to-google-doc/SKILL.md`**

Add after the "Updating an Existing Google Doc" section:

```markdown
### Updating a Single Tab (multi-tab docs)

Google Docs supports native tabs (left-sidebar). `update.sh` replaces the
ENTIRE document and **deletes every tab except the first** — it refuses to
run against a multi-tab doc unless you pass `--force`.

To publish markdown into one tab while preserving the others:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/tab-update.sh ./file.md DOC_ID --tab "Tab Title"
bash ${CLAUDE_SKILL_DIR}/scripts/tab-update.sh ./file.md DOC_ID --tab t.abc123
```

How it works: the markdown is converted server-side via a throwaway temp doc
(auto-trashed), whose structure is replayed into the target tab with
tab-scoped `batchUpdate` requests. Supported: headings, bold/italic/links,
nested bullet & numbered lists, tables. Not supported (skipped with a
warning): images, horizontal rules, footnotes.

### Managing Tabs

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/tabs.sh list DOC_ID
bash ${CLAUDE_SKILL_DIR}/scripts/tabs.sh add DOC_ID "Next Steps" --emoji "⭐" --index 1
bash ${CLAUDE_SKILL_DIR}/scripts/tabs.sh rename DOC_ID "Next Steps" "Action Items"
bash ${CLAUDE_SKILL_DIR}/scripts/tabs.sh delete DOC_ID t.abc123 --yes
```
```

Also update the frontmatter `description` to mention tabs, e.g. append: `Tab-aware: can publish into a single native Doc tab and manage tabs.` And add to Troubleshooting: `**"This doc has N native tabs" error:** the doc uses native tabs; use tab-update.sh (see "Updating a Single Tab") or pass --force to intentionally flatten the doc to one tab.`

- [ ] **Step 2: Update `google-doc-to-md/SKILL.md`**

Add a section:

```markdown
## Working with Native Doc Tabs

List a doc's tabs (id, index, title — indented by nesting):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/download.sh DOC_ID --list-tabs
```

Export a single tab as markdown (basic fidelity: headings, bold/italic,
links, lists, tables):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/download.sh DOC_ID out.md --tab "Tab Title"
```

Note: the default (no `--tab`) Drive export flattens ALL tabs into one
markdown file with each tab's title as a heading — fine for single-tab docs,
confusing for multi-tab ones. Use `--list-tabs` first when unsure.
```

Also append to the frontmatter `description`: `Supports native Doc tabs: --list-tabs and per-tab export via --tab.`

- [ ] **Step 3: Bump plugin version (minor)**

Read `plugins/gws/.claude-plugin/plugin.json`, bump the minor version (e.g. `1.12.0` → `1.13.0` — use whatever the current value is at implementation time).

- [ ] **Step 4: Run everything one last time**

```bash
cd /Users/JT/Code/claude-plugins
python3 -m unittest discover -s plugins/gws/skills/md-to-google-doc/tests -p 'test_*.py' -v
python3 -m unittest discover -s plugins/gws/skills/google-doc-to-md/tests -p 'test_*.py' -v
bash plugins/gws/skills/md-to-google-doc/tests/smoke-tabs.sh
```

Expected: all unit tests PASS; smoke prints `ALL SMOKE CHECKS PASSED`.

- [ ] **Step 5: Commit and push**

```bash
cd /Users/JT/Code/claude-plugins
git add plugins/gws/skills/md-to-google-doc/SKILL.md \
        plugins/gws/skills/google-doc-to-md/SKILL.md \
        plugins/gws/.claude-plugin/plugin.json
git commit -m "gws: document native Docs tab support (v1.13.0)"
git pull --rebase && git push
```

---

## Post-implementation validation (manual, outside this repo)

The motivating use case: `/Users/JT/Documents/Southport UDO/931-Hankinsville-ADU-Findings.md` publishes to Google Doc `1UGiV4X_Nq6coKAlA9gZvif8O49Ce4axajmecR6D9prs`, which now has a manually-created "Next Steps" tab. **Do not run this until JT confirms** — it writes to the live family doc:

1. `tabs.sh list 1UGiV4X_...` → confirm tab ids/titles ("Next Steps" tab expected at `t.t2vo9v7furq`).
2. Split the Next Steps section out of the findings markdown into `next-steps.md`.
3. `tab-update.sh 931-Hankinsville-ADU-Findings.md <doc> --tab <first-tab-id>` and `tab-update.sh next-steps.md <doc> --tab "Next Steps"`.
4. Eyeball both tabs in the browser; iterate on converter fidelity gaps if the real doc (heavy tables, ⭐/§ characters) exposes any.

## Known limitations (accepted, documented in SKILL.md)

- Images, horizontal rules, footnotes, and smart chips are not replayed into tabs (warned on stderr).
- Numbered lists interrupted by a non-list paragraph restart numbering.
- Very large docs: request payload passes through `--json "$(cat file)"` (argv), safe to ~1MB per 400-request chunk; far beyond any realistic markdown doc.
- The `?tab=` URL suffix format (`?tab=t.xxx`) matches what Google's own tab links use.
