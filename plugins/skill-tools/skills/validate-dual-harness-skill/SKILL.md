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
2. Read every applicable `AGENTS.md` and `CLAUDE.md`. If one states a dual-harness skill contract (in jtsternberg/claude-plugins, the `Dual-Harness Skill Contract` section), it overrides this checklist where they differ. If none does, this checklist is the contract, and the repo's missing setup gets reported (see the last section).
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

1. Run the bundled static checker against every target skill directory, in every repository:

   Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.

   ```bash
   SKILL_DIR="${CLAUDE_SKILL_DIR}"
   bash "$SKILL_DIR/scripts/check-skill.sh" <skill-dir-or-SKILL.md>...
   ```

   It reports `file:line: [rule]` for path tokens, Codex-only prose, dynamic-context placeholders, and explicit-only parity, and exits 1 on any violation. It cannot judge routing metadata, `allowed-tools` sync, or runtime behavior; check those by reading.
2. Run the target plugin's focused tests, if the repository has any.
3. Run the repository's own dual-harness checks when they exist. In jtsternberg/claude-plugins they are:
   - `bash plugins/codex/tests/skill-paths_test.sh`
   - `node --test plugins/codex/tests/compatibility.test.mjs`
   - `bash tests/run-all.sh`, only when the change touches scripts, tests, path tokens, invocation arguments, hooks, or a manifest or catalog.
   Elsewhere, look for equivalents named in `AGENTS.md`/`CLAUDE.md`, CI workflows, or `tests/`. Do not invent commands.
4. If the edit changes paths, arguments, routing, hooks, permissions, or dynamic context, run a representative installed-plugin probe under both Claude Code and Codex. Static scans alone are insufficient.
5. Report blockers first with file and line references, then non-blocking follow-ups, then exact test/probe evidence. If no issue remains, say which contracts were checked rather than giving a generic approval.

## When the repository lacks the setup

A missing contract or missing checks never fails the skill under review. Report it in a separate **Repo setup** section after the findings, naming only what is actually missing:

- **No written contract:** recommend adding the section in `${CLAUDE_SKILL_DIR}/references/repo-contract-template.md` to the repository's `AGENTS.md` (or `CLAUDE.md` when that file is what agents load there), adapted to the repo's layout.
- **No automated check:** recommend running `check-skill.sh` in the repository's test suite or CI over its skill directories. Since the script lives in the installed plugin, the repository needs its own copy (for example `scripts/check-skill.sh`). Note that a copy does not pick up later rule changes on its own.
- **No dual-harness probe:** recommend one documented smoke test per harness: install the plugin, invoke one skill with an argument, and confirm a bundled script path resolves.

Codex: the template sits at `references/repo-contract-template.md` inside the directory containing this SKILL.md.

Offer these as recommendations. Edit the repository only if the user asks.
