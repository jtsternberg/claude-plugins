---
name: publish-release
description: Manually invoked release runbook for this repo. Bump the changed plugin's manifest version, validate, push/merge, then refresh the plugin in both Codex and Claude Code. Run this when a plugin/skill change is ready to ship to marketplace users — do not auto-invoke.
disable-model-invocation: true
---

# Publish a plugin/skill release

Manual entry point for shipping a plugin change to the people who install these
plugins. Invoke it only when a change is ready to release — `/publish-release`.
It is the checklist; the authoritative step-by-step procedure lives in
[`docs/codex/release.md`](../../../docs/codex/release.md), which this skill
points into rather than duplicating.

A change that reaches only your local working tree is not released. "Released"
means the version is bumped, tests pass, and the change is merged to the ref
marketplace users install from.

## When to run

- A plugin's skills, commands, hooks, scripts, or metadata changed in a way
  installers would care about, and the change is ready to ship.
- The user says ship / publish / release / push a plugin.

Do **not** run for whitespace/typo-only commits or unmerged local experiments.

## The one non-negotiable

Every plugin change **must** bump the version in that plugin's manifest before
you release it. Plugin versions are release identifiers **and** Codex cache
keys — an installer-visible change with no version bump defeats the cache
transition and leaves users on stale content. Semver: patch for fixes, minor
for non-breaking additions, major for breaking changes.

## Steps

Follow `docs/codex/release.md` for the full detail of each; the short form:

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

## If a Claude-specific runbook is ever needed

Today `docs/codex/release.md` covers the Claude side in §4, so there is one
shared runbook. If the Claude release path grows steps that don't belong in the
Codex doc, add `docs/claude/release.md` and link it here alongside the Codex
one — keep this skill as the single manual entry point that fans out to both.
