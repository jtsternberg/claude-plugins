# Proposal: promote the tripwire mechanism to a distributed beads-workflow skill

**Status:** awaiting review · **Parent:** claude-plugins-7u9g · **Date:** 2026-08-31

## Recommendation (tl;dr)

Yes — graduate the *mechanism* (matcher + grammar + an optional edit-time hook)
into `beads-workflow` as one skill, `tripwire-scan`, backed by a shared matcher
script and a `PostToolUse` hook. Keep the *authoring convention prose* repo-private
in `docs/compounding.md`; that's this repo's guidance, not a beads feature. Rewrite
`compounding-preflight` step 5 to call the shared matcher instead of hand-grepping.

Fold all three candidates in, but reframed: **the inline `# tripwire: <id>` comment
(C) becomes the primary anchor** (decided with JT), which simultaneously fixes the
coarse-match weakness (A) *and* the line-range-drift problem A introduces *and* the
self-announce weakness (3). Symbol/string anchors are the next fallback; a raw
line-range is last-resort and must be pinned to a git ref (an unpinned range drifts
and is rejected). The `PostToolUse` hook is central, not optional.

## Why it generalizes (the "should it move at all" question)

The `tripwire-paths:` convention depends on exactly two things: `bd` and `git`.
Both are what `beads-workflow` already assumes. It does **not** depend on
`compounding.md` — that file is merely *one consumer* (the preflight's step 5).
The generalizable core is: *a parked bead declares where its knowledge bites, and
something matches that against what you're about to edit and surfaces the bead.*
That is beads-native and useful in any repo; `compounding.md` is not. So the
mechanism graduates out and the preflight becomes a thin caller — which is exactly
the "graduate a rule into a mechanical guard" move `compounding.md`'s own write
gate preaches.

## The three weaknesses map cleanly onto the three candidates

| Weakness | Fix | Mechanism |
|---|---|---|
| 1. Fires late, only if someone runs preflight | **B** — hook | `PostToolUse` on Edit/Write injects a one-line reminder at edit time, for any agent |
| 2. Whole-file match cries wolf | **A** — anchors + hunk match | match the diff *hunks*, not the filename |
| 3. Watched file doesn't self-announce | **C** — inline comment | `# tripwire: <bead-id>` at the site, visible when you open the file |

The insight that unifies them: **an inline comment is a self-relocating, self-
announcing anchor.** Git moves it with the code (no line-range rot), the reader
sees it on arrival (weakness 3), and the matcher fires only when a hunk touches a
commented line (weakness 2). C isn't the weakest candidate — it's the keystone.

## The grammar (`tripwire-paths:`, extended, back-compatible)

Today: `tripwire-paths: path/a.sh, path/b.py` — comma-separated files, whole-file
match. That stays valid (coarsest tier). Add optional anchors:

```
tripwire-paths:
  plugins/hotline/tests/dial_wrapper_test.sh#make_cmux   # comment-anchored (DEFAULT)
  plugins/hotline/tests/socket-stub.py:"HOTLINE_SCREEN_TAIL_LINES"  # string
  plugins/hotline/scripts/repl-state.sh@57450af:L161-203 # line-range, PINNED to a ref (last resort)
  plugins/hotline/tests/cmux-call_test.sh                # whole-file (back-compat)
```

Anchors form a strict preference ladder — pick the highest that fits:

1. **`path#name`** — comment anchor. **Default. Use this.** The matcher greps `path`
   for a line containing `tripwire: <this-bead-id>` and fires only if a diff hunk
   overlaps that line's *current* position. `name` is a human hint; the bead-id in
   the comment is the real key. Git relocates the comment as the file changes, so it
   **cannot rot** — this is why it's the default, not a nicety.
2. **`path#symbol`** / **`path:"string"`** — symbol or string anchor. Next fallback
   when you can't or won't plant a comment. Fires when a hunk touches the symbol /
   when a changed line contains the string. Content-addressed, so it tolerates drift.
3. **`path@<ref>:Lstart-end`** — line-range, **pinned to a git ref/blob SHA**. Last
   resort, for files where nothing above works (fixtures, data, generated). The
   matcher resolves the range *at that ref* and maps it through `git diff <ref>..` to
   current positions before overlapping hunks. **An unpinned floating `:Lstart-end`
   is a bug, not a syntax option** — line numbers move as the file changes, so a bare
   range silently points at the wrong code the first time anything above it shifts.
   The matcher rejects an unpinned line-range rather than matching it loosely.
4. **`path`** — whole file. Back-compat; coarsest. The only tier that still cries wolf.

Matching is against `git diff` hunk ranges, not filenames — that alone kills the
7u9g false positive (edit at line 1640 no longer trips a make_cmux tripwire).

## The skill: `tripwire-scan`

**Name:** `tripwire-scan` (verb-noun, matches `triage-beads`).

**Claude `description` / `when_to_use`:** model-invocable like `triage-beads`. Fires
on "check tripwires", "scan for tripwires", and at PR/review time. Scans a change-set
against open beads' `tripwire-paths:` anchors and reports each hit as
`bead-id → matched anchor → the bead's one-line why`.

**Codex routing terms in `description`** (Codex ignores `when_to_use`): "tripwire",
"parked bead", "edit-time warning", "before you change this file".

**What it scans:** same change-set resolution as `compounding-preflight` step 1 —
default working/staged diff, else `main...HEAD`, else an explicit range/PR. Builds
the tripwire index from `bd list --json` (grep descriptions for `tripwire-paths:`),
resolves anchors, matches hunks.

**Invocation:** `/beads-workflow:tripwire-scan` (Claude) / `$beads-workflow:tripwire-scan`
(Codex). Model-invocable (`allow_implicit_invocation: true`, no
`disable-model-invocation`), matching `triage-beads`.

**Shared matcher script** lives at the **plugin root** (`plugins/beads-workflow/scripts/tripwire-match.sh`),
not under the skill, because the hook needs it too — per CLAUDE.md § "Sharing Code
Between Sibling Skills." Skill and hook both call it; one implementation, no drift.

## The companion hook (candidate B) — central to the design

JT endorsed this as a first-class part of the design (2026-08-31), not an optional
add-on: it's the edit-time trigger the original pitch promised. Still Claude-primary
per the Codex trust/injection caveat below.

`plugins/beads-workflow/hooks/hooks.json`, `PostToolUse` matcher `Edit|Write|MultiEdit`:
read the touched path from `tool_input`, match it (via the shared script) against the
tripwire index, inject a one-line `system-reminder` naming the bead when it hits.

Noise control, non-negotiable for a hook that fires on every edit:
- **Once per file per session** — touch a marker in a session tmp dir; skip if present.
- **Anchor-aware** — if the bead's anchor is comment/line/string, fire only on an
  actual anchor hit, not the mere filename. (At `PostToolUse` you have the file and
  the edited region, enough to check line/string/comment anchors.)
- **Index cached once per session** — `bd list --json` on every keystroke-batch is
  too slow; build the index on first edit (or `SessionStart`) with a short TTL.
- **Suppress the bead's own tripwire while it's being worked** — see risk 5.

This makes the tripwire fire for *any* agent regardless of preflight discipline —
the actual "edit-time trigger" the original pitch promised.

## Degradation (must-haves for a distributed skill)

- **No beads db / `bd` not on PATH** → matcher exits 0, empty report; hook is silent.
  A repo with no beads sees nothing, ever.
- **No hooks, or Codex hook untrusted** → the *pull* path (skill at PR/review time)
  still works. The hook is the enhancement; the skill is the floor.
- **No inline comment planted** → falls back to line-range or whole-file match.
  Coarser, but never worse than today.
- **Codex** → `PostToolUse` is schema-backed (`docs/codex/hooks-under-codex.md`) and
  hook stdout reaches the model, but Codex gates hooks behind first-run trust, and
  I have **not** verified `PostToolUse`-specific context injection under Codex (only
  `UserPromptSubmit`/`SessionStart` were probed). Ship the hook Claude-primary,
  Codex best-effort, and probe before claiming parity.

## Preflight after the move

`compounding-preflight` step 5 collapses to: run `tripwire-scan` (or the shared
script directly) and report its hits. The `compounding.md` "Park a bead only with
its trigger planted where it fires" entry stays — it's the authoring rule — but its
"the compounding-preflight diff scan matches" clause changes to point at the skill,
per the doc's own graduate-and-prune gate.

## Tests (repo contract)

Node layout guard at `plugins/beads-workflow/tests/tripwire-scan-layout.test.mjs`
(model-invocable, portable execution contract, script exists + is read-only), mirroring
`triage-beads-layout.test.mjs`. Bash behavior suite at
`plugins/beads-workflow/tests/tripwire-match_test.sh`: whole-file match, line-range
overlap/miss, string hit, comment-anchor hit after simulated line drift, no-bd graceful
exit, one-fixture-per-direction per `compounding.md`'s accept/reject-guard rule. Both
are auto-discovered by `tests/run-all.sh`'s globs.

## Open questions / risks for JT

1. **Anchor default — DECIDED (JT, 2026-08-31).** Comment-anchor (`path#name` +
   `# tripwire: <id>`) is the default. Symbol/string is the next fallback. A raw
   line-range is last-resort *and must be pinned to a git ref/blob SHA* — an unpinned
   floating line-range is a bug the matcher rejects, because line numbers drift as the
   file changes. Locked in; see the grammar ladder above.
2. **Hook cost & throttle.** Is a per-session-cached `bd list` + "once per file per
   session" the right noise/cost tradeoff, or too chatty / too quiet?
3. **Codex hook parity.** Ship hook Claude-primary and file a probe task for Codex
   `PostToolUse` context injection, or block the hook on that probe first?
4. **Symbol anchors (`file:symbol`).** Defer to comment/line/string for v1 (no
   language-aware symbol resolution), or invest now? (Rec: defer — the comment anchor
   gives you symbol-precision without a parser.)
5. **Self-trip suppression.** When you edit a file *because* you're fixing its
   tripwire bead, the tripwire fires on you. Simplest guard: fire only for
   `open`/`blocked` tripwire beads, and let a `tripwire-scan --resolving <id>` flag /
   the hook skipping the in-progress bead handle the rest. Good enough, or want
   something smarter?
6. **Authoring surface.** One `tripwire-scan` skill with authoring documented in its
   SKILL.md, or a second `park-with-tripwire` skill? (Rec: document it; don't add a
   second skill for v1.)

## Not done in this pass

No skill implemented — this is the consider pass. No bd impl task filed yet: the
direction is pending your review, and filing "build the tripwire skill" before you've
picked between the options above would be acting on an unmade decision. Say go and I'll
file it discovered-from claude-plugins-7u9g with the answers baked in.
