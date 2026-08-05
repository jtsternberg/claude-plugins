---
name: validate-dual-harness-skill
description: "Validate new or edited plugin skills against Claude Code and Codex discovery, invocation, metadata, path, permission, and runtime contracts"
argument-hint: "<skill-name-or-path>"
disable-model-invocation: true
allowed-tools: Read Glob Grep Bash
---

Validate the skill identified by `$ARGUMENTS` without modifying it. If no path is supplied, infer the skill files changed on the current branch.

Codex: if the invocation token above is not substituted, use the text following the skill name in the current request.

## Establish scope

1. Resolve each target `SKILL.md`, its plugin root, manifest, bundled resources, tests, and `agents/openai.yaml` when present.
2. Read every applicable `AGENTS.md`. In this repository, treat `Dual-Harness Skill Contract` as authoritative.
3. Determine whether the skill promises dual-harness support or is explicitly harness-specific. Do not demand parity from a deliberate exception, but require the exception to be visible in metadata and documentation.
4. When reviewing branch changes, compare the target files with the merge base so removed Claude behavior is visible; do not review only the final text.

## Validate both harnesses

Report a concrete failure whenever one of these contracts is violated:

1. **Discovery and distribution**
   - Put reusable workflows at `plugins/<plugin>/skills/<name>/SKILL.md`; Codex does not expose legacy `commands/*.md` workflows.
   - Keep `.claude-plugin/plugin.json` and any native Codex catalog/manifest entries consistent with the plugin's intended availability.
   - Bump each affected plugin version once per unreleased branch, after the final plugin edit.
2. **Routing metadata**
   - Keep the terms Codex needs for implicit routing in `description`; it does not use Claude's `when_to_use`, `argument-hint`, or `effort` for routing.
   - Treat Claude's `allowed-tools` and dynamic `!` context as Claude-only behavior unless a current Codex probe proves otherwise.
   - If Claude has `disable-model-invocation: true`, require `policy.allow_implicit_invocation: false` in `agents/openai.yaml` for Codex.
3. **Invocation arguments**
   - Preserve one literal dollar sign immediately followed by `ARGUMENTS` wherever Claude must interpolate invocation text at a particular location, including migrated command workflows. Do not repeat that substitutable form in explanatory prose.
   - Preserve useful `argument-hint` metadata for Claude. Put Codex fallback instructions in adjacent prose instead of replacing the token.
4. **Skill and plugin paths**
   - In executable text, keep the braced shell variables named `CLAUDE_SKILL_DIR` and `CLAUDE_PLUGIN_ROOT` bare. Reject shell-default wrappers, traversal from a skill directory to its plugin root, hardcoded cache paths, and unanchored relative resource paths.
   - Put Codex substitution instructions in adjacent prose without repeating a Claude path token in the Codex-only sentence or comment.
   - Repeat the resolved local assignment in every independently executed block. Codex shells do not retain state between blocks.
   - Inspect inline and fenced dynamic-context commands separately; paths injected before the model sees the prompt must resolve mechanically under Claude.
5. **Runtime-specific behavior**
   - Keep Claude `allowed-tools` patterns synchronized with the literal commands Claude executes; do not broaden permissions as an incidental portability fix.
   - Treat hooks as a separate runtime surface. Do not infer hook variables or lifecycle events from skill-shell behavior.
   - Preserve documented invocation forms: Claude Code uses `/<plugin>:<skill>` and Codex uses `$<plugin>:<skill>`; use the bare skill name in prose.

## Prove the result

1. Run the target plugin's focused tests.
2. In this repository, run:
   - `bash plugins/codex/tests/skill-paths_test.sh`
   - `node --test plugins/codex/tests/compatibility.test.mjs`
   - `bash tests/run-all.sh`
3. If the edit changes paths, arguments, routing, hooks, permissions, or dynamic context, run a representative installed-plugin probe under both Claude Code and Codex. Static scans alone are insufficient.
4. Report blockers first with file and line references, then non-blocking follow-ups, then exact test/probe evidence. If no issue remains, say which contracts were checked rather than giving a generic approval.
