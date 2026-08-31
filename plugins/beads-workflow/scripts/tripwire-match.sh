#!/usr/bin/env bash
#
# tripwire-match.sh — match a change-set (or a single edited file) against the
# tripwire anchors declared by open/blocked beads, and report each hit.
#
# A parked bead declares where its knowledge bites via a `tripwire-paths:` line
# in its description. This script is the shared engine behind BOTH the
# tripwire-scan skill (pull path, run at review/PR time) and the PostToolUse hook
# (push path, fires at edit time). Bead enumeration is delegated to the shared
# bd-enumerate.sh so there is exactly one `bd list` path in this plugin.
#
# Only OPEN and BLOCKED beads are enumerated — never in_progress. That is the
# self-trip suppression: the moment you claim the bead you're editing a file to
# fix (its status becomes in_progress), its own tripwire stops firing on you.
#
# Anchor ladder (highest that fits wins; see the tripwire-scan SKILL.md):
#   path#name              comment anchor  — DEFAULT. Matches when a hunk touches
#                          the line carrying `tripwire: <bead-id>` in the file.
#                          `name` is a human hint; the bead-id is the real key.
#                          Git relocates the comment, so it cannot rot.
#   path:"string"          string anchor   — matches when a changed line contains
#                          the string. Content-addressed; drift-tolerant.
#   path@<ref>:Lstart-end  pinned range    — LAST RESORT. Resolves the lines AT
#                          <ref> to their content and matches that content against
#                          the change-set. Pinned to a git ref so it can't float.
#   path                   whole file      — back-compat; coarsest.
#   path:Lstart-end        UNPINNED range  — REJECTED. Line numbers drift; a bare
#                          range silently points at the wrong code. Warned, never
#                          matched.
#
# Usage:
#   tripwire-match.sh scan [--json] [<git-diff-spec>]
#       Match the change-set. Default spec: `git diff HEAD` (staged+unstaged) if
#       non-empty, else the merge-base with the default branch. An explicit spec
#       (a range like main...HEAD, or a commit) is passed to `git diff`.
#   tripwire-match.sh check <file-path>
#       Match a single edited file (the hook's mode). Emits one tab-separated hit
#       line per matching bead: <bead-id>\t<path>\t<kind>\t<why>. No diff needed.
#
# Degradation (both modes): `bd` absent, no beads db, or not a git repo → exit 0
# with nothing matched. The tripwire is an enhancement; its absence is never an
# error.

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENUMERATE="$SCRIPT_DIR/bd-enumerate.sh"

MODE="${1:-}"
shift || true

JSON=0
case "$MODE" in
  scan)
    while [ $# -gt 0 ] && [ "${1:-}" = "--json" ]; do JSON=1; shift; done
    DIFF_SPEC="${1:-}"
    ;;
  check)
    CHECK_PATH="${1:-}"
    [ -n "$CHECK_PATH" ] || { echo "tripwire-match.sh check: needs a file path" >&2; exit 2; }
    ;;
  -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "tripwire-match.sh: mode must be 'scan' or 'check'" >&2; exit 2 ;;
esac

# --- git repo root (degrade silently where there is none) -------------------
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
# Force it physical so the check-mode prefix test below always compares like
# with like — git's toplevel is physical on some setups and logical on others,
# and a mismatch silently drops every edit (the /var→/private/var trap).
[ -n "$REPO_ROOT" ] && REPO_ROOT=$(cd "$REPO_ROOT" 2>/dev/null && pwd -P || printf '%s' "$REPO_ROOT")
if [ -z "$REPO_ROOT" ]; then
  [ "$MODE" = "scan" ] && [ "$JSON" -eq 0 ] && echo "tripwire-match: not a git repository — nothing to scan."
  [ "$MODE" = "scan" ] && [ "$JSON" -eq 1 ] && echo '{"hits":[],"note":"not a git repository"}'
  exit 0
fi

# --- build the tripwire index (open/blocked beads only) ---------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

set +e
bash "$ENUMERATE" --status open,blocked >"$tmp/index.json" 2>"$tmp/index.err"
enum_rc=$?
set -e
if [ "$enum_rc" -ne 0 ]; then
  # 127 = no bd; anything else = bd list failed. Either way the tripwire simply
  # has nothing to say — never a hard error at an edit or a review.
  if [ "$MODE" = "scan" ]; then
    reason=$(head -1 "$tmp/index.err" 2>/dev/null || echo "beads unavailable")
    [ "$JSON" -eq 1 ] && echo "{\"hits\":[],\"note\":\"beads unavailable\"}" \
                      || echo "tripwire-match: beads unavailable ($reason) — nothing to scan."
  fi
  exit 0
fi

# --- gather the change-set (scan) or normalize the path (check) -------------
if [ "$MODE" = "scan" ]; then
  if [ -z "$DIFF_SPEC" ]; then
    if [ -n "$(git -C "$REPO_ROOT" diff HEAD --name-only 2>/dev/null)" ]; then
      DIFF_SPEC="HEAD"
    else
      base=$(git -C "$REPO_ROOT" merge-base HEAD main 2>/dev/null \
             || git -C "$REPO_ROOT" merge-base HEAD origin/main 2>/dev/null || true)
      DIFF_SPEC="${base:+$base...HEAD}"
    fi
  fi
  # --unified=0: exact changed-line ranges, no context lines to blur overlap.
  # --no-color: a machine that forces color.ui=always would otherwise wrap every
  # `+++`/`@@`/`+`/`-` line in ANSI escapes and the parser below would match none.
  # shellcheck disable=SC2086
  git -C "$REPO_ROOT" -c color.ui=never diff --no-color --unified=0 $DIFF_SPEC >"$tmp/diff.txt" 2>/dev/null || : >"$tmp/diff.txt"
else
  # Normalize the edited path to repo-relative, whatever the caller passed.
  abs="$CHECK_PATH"
  case "$abs" in
    /*) : ;;
    *) abs="$PWD/$abs" ;;
  esac
  # Realpath without requiring the file to still exist (a delete still matters).
  # pwd -P resolves symlinks so this matches git's physical --show-toplevel: on
  # macOS /var and /tmp are symlinks, and a logical pwd would fail the REPO_ROOT
  # prefix test below and silently drop every in-repo edit.
  norm=$(cd "$(dirname "$abs")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$abs")" || printf '%s' "$abs")
  case "$norm" in
    "$REPO_ROOT"/*) CHECK_REL="${norm#"$REPO_ROOT"/}" ;;
    *) exit 0 ;;  # edit outside this repo — not ours to warn about
  esac
fi

# --- match (python does the anchor parsing + hunk overlap) ------------------
MODE="$MODE" JSON="$JSON" REPO_ROOT="$REPO_ROOT" \
CHECK_REL="${CHECK_REL:-}" DIFF_FILE="$tmp/diff.txt" \
python3 - "$tmp/index.json" <<'PY'
import json, os, re, subprocess, sys

mode      = os.environ["MODE"]
as_json   = os.environ.get("JSON") == "1"
repo_root = os.environ["REPO_ROOT"]

with open(sys.argv[1]) as fh:
    beads = json.load(fh)

warnings = []

# --- parse each bead's tripwire-paths line(s) into anchor specs --------------
# The value starts after `tripwire-paths:` and may wrap across lines; it ends at
# a blank line or the next `key:` header. Entries are separated by commas OR
# newlines. A trailing `   # annotation` (whitespace then #) is not an anchor.
HEADER_RE = re.compile(r'(?im)^[ \t]*tripwire-paths:[ \t]*(.*)$')
NEXTKEY_RE = re.compile(r'^[ \t]*[A-Za-z0-9_-]+:[ \t]')

def extract_block(desc):
    m = HEADER_RE.search(desc or "")
    if not m:
        return None
    lines = desc[m.start():].splitlines()
    block = [m.group(1)]
    for ln in lines[1:]:
        if ln.strip() == "":
            break
        if NEXTKEY_RE.match(ln) and not ln.lstrip().lower().startswith("tripwire-paths:"):
            break
        block.append(ln)
    return "\n".join(block)

def split_entries(block):
    entries = []
    for chunk in re.split(r'[,\n]', block):
        raw = chunk.strip()
        if not raw:
            continue
        # Drop a trailing annotation: whitespace then '#'. The anchor '#' is
        # attached to the path (no space before it), so a spaced '#' is prose.
        raw = re.split(r'\s+#', raw, maxsplit=1)[0].strip()
        raw = raw.strip().strip(',').strip()
        if raw:
            entries.append(raw)
    return entries

PINNED_RE   = re.compile(r'^(?P<path>[^@]+)@(?P<ref>[^:]+):L(?P<a>\d+)-(?P<b>\d+)$')
UNPINNED_RE = re.compile(r'^(?P<path>[^@:]+):L(?P<a>\d+)-(?P<b>\d+)$')
STRING_RE   = re.compile(r'^(?P<path>[^:]+):"(?P<s>.*)"$')

def parse_entry(entry, bead_id):
    m = PINNED_RE.match(entry)
    if m:
        return {"path": m["path"], "kind": "linerange",
                "ref": m["ref"], "a": int(m["a"]), "b": int(m["b"])}
    if UNPINNED_RE.match(entry):
        warnings.append(f"{bead_id}: unpinned line-range '{entry}' rejected — "
                        f"pin it to a git ref (path@<ref>:Lstart-end) or use a "
                        f"comment/string anchor; line numbers drift.")
        return None
    m = STRING_RE.match(entry)
    if m:
        return {"path": m["path"], "kind": "string", "s": m["s"]}
    # A '#' not at position 0 is a comment/symbol anchor. `name` is a hint only.
    hi = entry.find("#")
    if hi > 0:
        return {"path": entry[:hi], "kind": "comment", "name": entry[hi+1:]}
    return {"path": entry, "kind": "file"}

index = []  # {bead_id, why, spec}
for b in beads:
    spec_block = extract_block(b.get("description", ""))
    if not spec_block:
        continue
    bead_id = b.get("id")
    why = (b.get("title") or "").strip()
    for entry in split_entries(spec_block):
        spec = parse_entry(entry, bead_id)
        if spec:
            index.append({"bead_id": bead_id, "why": why, "spec": spec})

# --- change-set (scan) -------------------------------------------------------
plus_ranges = {}   # path -> [(start, count)] on the new side
changed_lines = {} # path -> [trimmed content of +/- lines]
changed_files = set()

if mode == "scan":
    cur = None
    with open(os.environ["DIFF_FILE"], encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("diff --git "):
                cur = None   # reset per file so a deletion never misattributes
                continue
            if line.startswith("+++ "):
                p = line[4:]
                if p != "/dev/null":
                    cur = p[2:] if p.startswith("b/") else p
                    changed_files.add(cur)
                continue
            if line.startswith("--- "):
                p = line[4:]
                # deletion: new side is /dev/null, so anchor to the old path
                if p not in ("/dev/null",) and (cur is None):
                    cur = p[2:] if p.startswith("a/") else p
                continue
            if line.startswith("@@"):
                m = re.search(r'\+(\d+)(?:,(\d+))?', line)
                if m and cur is not None:
                    start = int(m.group(1))
                    count = int(m.group(2)) if m.group(2) is not None else 1
                    plus_ranges.setdefault(cur, []).append((start, count))
                    changed_files.add(cur)
                continue
            if cur is None:
                continue
            if line.startswith("+"):
                changed_lines.setdefault(cur, []).append(line[1:].strip())
            elif line.startswith("-"):
                changed_lines.setdefault(cur, []).append(line[1:].strip())

def hunks_touch_line(path, lineno):
    for (start, count) in plus_ranges.get(path, []):
        lo = start
        hi = start + (count if count > 0 else 1) - 1
        if lo <= lineno <= hi:
            return True
    return False

def comment_line_numbers(path, bead_id):
    full = os.path.join(repo_root, path)
    if not os.path.isfile(full):
        return []
    pat = re.compile(r'tripwire:\s*' + re.escape(bead_id) + r'\b')
    nums = []
    with open(full, encoding="utf-8", errors="replace") as fh:
        for i, ln in enumerate(fh, start=1):
            if pat.search(ln):
                nums.append(i)
    return nums

def file_contains(path, needle):
    full = os.path.join(repo_root, path)
    if not os.path.isfile(full):
        return False
    with open(full, encoding="utf-8", errors="replace") as fh:
        return needle in fh.read()

def pinned_content(ref, path, a, b):
    try:
        out = subprocess.run(["git", "-C", repo_root, "show", f"{ref}:{path}"],
                             capture_output=True, text=True, check=True).stdout
    except Exception:
        return None
    lines = out.splitlines()
    picked = lines[a-1:b]  # 1-indexed inclusive
    return {ln.strip() for ln in picked if ln.strip()}

# --- decide hits -------------------------------------------------------------
hits = []
seen = set()

for item in index:
    bead_id, why, spec = item["bead_id"], item["why"], item["spec"]
    path, kind = spec["path"], spec["kind"]

    if mode == "scan":
        if path not in changed_files:
            continue
        matched = False
        if kind == "file":
            matched = True
        elif kind == "comment":
            matched = any(hunks_touch_line(path, n)
                          for n in comment_line_numbers(path, bead_id))
        elif kind == "string":
            matched = any(spec["s"] in cl for cl in changed_lines.get(path, []))
        elif kind == "linerange":
            content = pinned_content(spec["ref"], path, spec["a"], spec["b"])
            if content is None:
                warnings.append(f"{bead_id}: pinned range {path}@{spec['ref']} "
                                f"could not be resolved (bad ref/path?) — skipped.")
                matched = False
            else:
                matched = any(cl in content for cl in
                              (c.strip() for c in changed_lines.get(path, [])) if cl)
    else:  # check: single file, no diff available
        if path != os.environ["CHECK_REL"]:
            continue
        if kind == "file":
            matched = True
        elif kind == "comment":
            matched = bool(comment_line_numbers(path, bead_id))
        elif kind == "string":
            matched = file_contains(path, spec["s"])
        elif kind == "linerange":
            matched = True  # conservative: no diff in-hook, fire at file level
        else:
            matched = False

    if matched:
        key = (bead_id, path)
        if key in seen:
            continue
        seen.add(key)
        hits.append({"bead_id": bead_id, "path": path, "kind": kind, "why": why})

# --- output ------------------------------------------------------------------
if mode == "check":
    for h in hits:
        print(f"{h['bead_id']}\t{h['path']}\t{h['kind']}\t{h['why']}")
    sys.exit(0)

if as_json:
    print(json.dumps({"hits": hits,
                      "changed_files": sorted(changed_files),
                      "warnings": warnings}, indent=2))
else:
    if warnings:
        for w in warnings:
            print(f"⚠  {w}", file=sys.stderr)
    if not hits:
        print(f"tripwire-scan: no open bead watches any file in this change-set "
              f"({len(changed_files)} changed).")
    else:
        print(f"tripwire-scan: {len(hits)} tripwire(s) tripped by this change-set:")
        for h in hits:
            print(f"  • {h['bead_id']} → {h['path']} ({h['kind']}) — {h['why']}")
        print("Each is parked knowledge for code you touched. Act on it, "
              "consciously defer, or close the bead as satisfied "
              "(and claim it in_progress first to silence its tripwire).")
PY
