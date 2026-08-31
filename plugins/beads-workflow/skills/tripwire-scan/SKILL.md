---
name: tripwire-scan
description: >-
  Match a change-set against the tripwire anchors that parked beads (bd issues)
  declare, and surface each parked bead whose watched code you're about to change
  — the edit-time warning that `bd ready` can't give, because it only fires when
  someone asks for work, never when you touch the file a bead warns about. Use
  when reviewing or creating a PR, before finishing a change, or when asked to
  "check tripwires", "scan for tripwires", or "what parked beads touch this
  change". A parked bead plants a `tripwire-paths:` line naming where its
  knowledge bites; this scans your diff against those anchors and reports each
  hit as bead-id → matched file → the bead's one-line why. Safe and read-only.
when_to_use: >-
  At review/PR time, or before finishing a change, to catch parked beads whose
  watched code the change-set touches. Read-only; safe to run repeatedly.
argument-hint: "[<git-diff-spec>]"
---

# Tripwire Scan

Parked beads hold contingent knowledge — "if you ever touch `make_cmux`, its
fixture renders the screen upside-down." That knowledge is invisible in `bd
ready`, which is a pull channel: it surfaces work when you ask for it, never at
the moment you edit the file it concerns. A tripwire is the missing edit-time
trigger. This skill is the review-time half of it (the companion PostToolUse hook
is the live half); both share one matcher.

Optional diff spec: `$ARGUMENTS`

Codex: if the invocation text above is not populated, use the text after the
skill name; with none, scan the default change-set. The plugin-root path below
resolves under Claude Code — substitute the installed plugin directory (the one
containing this skill's plugin) wherever `${CLAUDE_PLUGIN_ROOT}` appears.

## Run the scan

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
bash "$PLUGIN_ROOT/scripts/tripwire-match.sh" scan $ARGUMENTS
```

Codex: `PLUGIN_ROOT` is the installed plugin directory; substitute it for the
token. Re-assign it in each block you run — shell state does not persist between
blocks.

With no argument it resolves the change-set the way a review does: the
staged+unstaged diff vs `HEAD` if the tree is dirty, otherwise the merge-base
delta with the default branch. Pass an explicit spec (`main...HEAD`, a commit,
any `git diff` range) to scan that instead. Add `--json` for machine output
(`{hits, changed_files, warnings}`).

Only **open** and **blocked** beads are scanned. The bead you're editing a file
to fix is `in_progress`, so its own tripwire never fires on you — claim a bead
`in_progress` before you work it and it self-suppresses.

## Read the result

Each hit is `bead-id → matched file (anchor kind) → the bead's one-line why`. A
hit is parked knowledge for code this change-set touches. For each: run
`bd show <id>`, then either act on it, consciously defer, or close the bead as
satisfied. Warnings (e.g. an unpinned line-range, a pinned range whose ref no
longer resolves) print to stderr — they name a malformed anchor to fix, not a hit.

An empty report means no open bead watches anything in the change-set. Where
there is no beads db or the tree isn't a git repo, the scan degrades to that
empty result — never an error.

## Authoring a tripwire (how to plant one)

Add a `tripwire-paths:` line to the bead's description naming where the knowledge
bites. Entries are comma- or newline-separated; a trailing ` # note` (whitespace
then `#`) is a human annotation, not part of the anchor. Pick the **highest**
anchor tier that fits — precision is what keeps the tripwire from crying wolf:

1. **`path#name` — comment anchor. The default.** Plant `# tripwire: <bead-id>`
   (any comment syntax) on the exact line the knowledge concerns; `name` in the
   anchor is a human hint, the bead-id in the comment is the key. The scan fires
   only when a diff hunk touches that commented line. Git relocates the comment as
   the file changes, so it **cannot rot**, and anyone opening the file sees it.
2. **`path:"string"` — string anchor.** Fires when a changed line contains the
   string. Content-addressed, so it tolerates drift. Good for "if anyone touches
   this constant/flag."
3. **`path@<ref>:Lstart-end` — line-range PINNED to a git ref/blob SHA.** Last
   resort, for files you can't comment (fixtures, data, generated). The scan reads
   the lines *at that ref* and matches their content against the change-set, so
   the ref is what makes it drift-proof. **A bare `path:Lstart-end` with no `@ref`
   is rejected, not matched** — raw line numbers drift as the file changes and
   would silently point at the wrong code.
4. **`path` — whole file.** Back-compat and coarsest; every edit to the file
   trips it. Use only when the knowledge really is file-wide.

Prefer the comment anchor. It fixes all three weaknesses at once: precise (hunk
match, not filename), self-announcing (visible in the file), and drift-proof
(git moves it).

## The companion hook

`beads-workflow` ships a `PostToolUse` hook (Edit/Write/MultiEdit) that runs the
same matcher on each edited file and injects a one-line reminder — the live
edit-time trigger, for any agent, independent of whether anyone runs this scan.
It fires at most once per file per session. It is Claude-primary (see the hook
script header for the Codex caveat); this skill is the harness-independent floor.
