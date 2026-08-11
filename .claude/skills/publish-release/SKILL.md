---
name: publish-release
description: Release runbook for this repo — invoke when a plugin change-set is ready to ship to marketplace users, or the user says ship/publish/release a plugin. Judge first whether the change is installer-visible and the change-set is complete; then bump the affected plugin's manifest version once, validate, push/merge, and refresh the plugin in both Codex and Claude Code.
---

# Publish a plugin/skill release

Runbook for shipping a plugin change to the people who install these plugins.
Run it — using the judgment below, or on an explicit `/publish-release` — once a
change-set is complete and ready to release. It is the checklist; the
authoritative step-by-step procedure lives in
[`docs/release.md`](../../../docs/release.md), which this skill
points into rather than duplicating.

A change that reaches only your local working tree is not released. "Released"
means the version is bumped, tests pass, and the change is merged to the ref
marketplace users install from.

## When to run — and when not to

Run it when **both** are true:

- The change is **installer-visible**: a plugin's skills, commands, hooks,
  scripts, or manifest changed in a way someone who installs the plugin would
  notice.
- The **change-set is complete** — the feature or fix is done, not mid-flight.
  Commit and iterate freely while you work; a release is the moment the whole
  set is ready, not each step along the way.

The user saying ship / publish / release / push a plugin is an explicit signal
that both are true.

Do **not** run for:

- Whitespace-, typo-, or comment-only commits, unless the user asks.
- Changes that never reach installers: repo-root `AGENTS.md` / `README.md`,
  `docs/`, maintainer `scripts/`, `tests/`, CI config, or a repo-local
  `.claude/` skill like this one — none of these is a distributed plugin.
- Local experiments not yet merged.

When it is genuinely ambiguous whether a change is installer-visible, remember a
release is outward-facing and hard to walk back — confirm before shipping rather
than bumping on a hunch.

## The one non-negotiable

When you **do** release, the affected plugin's manifest version **must** be
bumped as part of that release. Plugin versions are release identifiers **and**
Codex cache keys — an installer-visible change that ships with no version bump
defeats the cache transition and leaves users on stale content. Semver: patch
for fixes, minor for non-breaking additions, major for breaking changes.

**One release, one bump.** Bump once for the whole change-set, at release
time — not on every interim fix or commit within a session. Several fixes
shipping together get a single version delta, not one bump per commit. If more
than one plugin changed, bump each affected plugin's manifest independently and
release each; never bump a manifest for a plugin that did not actually change.

## Steps

Follow `docs/release.md` for the full detail of each; the short form:

1. **Identify what changed and which surfaces publish it.** Which plugin
   directory changed? Is it offered through the Claude marketplace
   (`.claude-plugin/marketplace.json`), the Codex-native catalog
   (`.agents/plugins/marketplace.json`), or both? (release.md §1)
2. **Bump the manifest version** in the affected plugin's
   `.claude-plugin/plugin.json` (or `.codex-plugin/plugin.json` for a
   Codex-native-only plugin). Do not bump manifests the plugin does not
   actually publish. (release.md §1–2)
3. **Validate.** If a skill changed, run `validate-dual-harness-skill` against
   it and do representative Claude Code + Codex probes when behavior changed.
   Then run the repo gate and read its summary, not just the exit code:
   ```bash
   bash tests/run-all.sh
   ```
   (release.md §2)
4. **Commit, push, and merge** the complete change to the ref installers use.
   (release.md §2)
5. **Refresh Codex** and confirm the new version materialized in the cache.
   (release.md §3)
6. **Verify Claude Code** — update the marketplace, install/update the plugin,
   start a new session, and run a `/<plugin>:<skill>` probe. Codex-native-only
   plugins have no Claude step. (release.md §4)

## If a harness-specific runbook is ever needed

Today `docs/release.md` is the shared runbook. If either harness grows a
specialized release path, add a harness-specific companion under `docs/claude/`
or `docs/codex/` and link it from the shared guide—keep this skill as the single
manual entry point that fans out to both.
