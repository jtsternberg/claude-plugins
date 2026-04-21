---
name: create-skill
description: End-to-end skill builder that creates a new Claude Code skill, automatically reviews it against current best practices, and self-heals it before presenting the finished skill. Use when the user asks to create, make, scaffold, or build a skill and wants a polished result delivered in one pass without being interrupted mid-process. Make sure to use this skill whenever the user says "create a skill", "make a skill", "new skill", "scaffold a skill", "build me a skill", or otherwise asks for a skill to be produced end-to-end rather than drafted and reviewed separately.
argument-hint: "<skill-name-or-description>"
disable-model-invocation: true
effort: high
allowed-tools: Read Write Edit Glob Grep Bash Skill
---

# Create Skill

Wrapper that chains `skill-creator:skill-creator` → `skill-tools:review-skill` → self-heal → present. The user does not get interrupted between stages. The goal is a refined, review-hardened skill delivered in one pass.

## Why this exists

Creating a skill and then reviewing it are two separate workflows. Running them back-to-back manually interrupts the user twice — once to confirm the draft, once to confirm review fixes. This wrapper collapses that into a single hand-off: the user describes the skill they want, and the finished skill comes back already improved.

## Arguments

`$ARGUMENTS` is the skill idea — a name, a one-line description, or freeform intent. If empty, fall back to conversation context.

## Contract with the user

While this wrapper is running:

- The review file stays internal — Step 5 presents the conclusions directly. The finished SKILL.md gets opened in the editor at the end.
- Apply qualifying review recommendations automatically; the wrapper has authority to answer "yes, apply" on the user's behalf.
- One up-front confirmation happens in Step 1 (location + audience). Everything after runs straight through.
- Collect any other clarifications as "open questions" in the Step 5 summary.

### Tips

* If the user interrupts mid-step to correct something (save path, name, trigger phrases, any piece of Step 1's confirmed plan), **re-enter the affected step cleanly**.

* Always call `Skill(skill-creator:skill-creator)` before drafting anything yourself.

## Step 1: Decide where the skill lives (and who it's for)

Before invoking skill-creator, infer the location from the skill's intent. Location drives how the skill is written (hardcoded personal values vs. parameterized env vars), so picking it after drafting means rewriting. Do it up front.

### Classify the skill

Think through which of these three buckets fits best. Pick deliberately — most skills could technically live anywhere, but the *right* home depends on audience and portability.

1. **Project-specific** — only makes sense inside one codebase (references its scripts, schemas, commands, or conventions).
   - Path: `<project-root>/.claude/skills/<skill-name>/`
   - Signals: instructions mention files or tools unique to the current working directory; the skill would be meaningless in a different repo.

2. **Personal (private)** — useful across the user's own projects, but contains private paths, credentials, internal URLs, or personal preferences that should not be shared.
   - Path: `~/.claude/skills/<skill-name>/`
   - Signals: absolute personal paths (e.g., `/Users/<user>/...`), personal emails/usernames, private infrastructure names, internal-only domains.

3. **Public (shared via a plugin)** — reusable by other people. Anything personal **must** be parameterized out (env vars with sensible defaults), not hardcoded.
   - Default path: read `$CLAUDE_PUBLIC_SKILLS_DIR` — if set, propose creating the skill at `$CLAUDE_PUBLIC_SKILLS_DIR/<plugin-name>/skills/<skill-name>/`.
   - Otherwise, ask which plugin it belongs in (existing or new), or use the current `plugins/<plugin>/skills/<skill-name>/` layout if the user is working inside a plugin repo already.
   - **Parameterization pattern** — reference `plugins/session-tools/README.md`'s `$SESSIONS_RECAP_EXAMPLE` override. The bundled skill ships a generic default; an env var lets the user point at their own private file without committing it. Apply the same pattern for anything personal the skill needs: hardcode a safe generic fallback, check an env var for the real value, document both in the skill's README.

### Confirm before drafting

Send the user one message with three things:

1. **Classification** — project / personal / public, plus one-sentence rationale.
2. **Proposed path** — the exact directory where the skill will be created.
3. **Parameterization plan** (public only) — which personal values will become env vars, and their fallback defaults.

Wait for a yes / redirect. Then proceed to Step 2. If the user just says "yes" or equivalent, the entire rest of the wrapper runs without further interruption.

## Step 2: Create the skill via skill-creator

Invoke the official skill-creator: `skill-creator:skill-creator` from the claude-plugins-official marketplace. If a look-alike exists in another plugin (e.g., `compound-engineering:skill-creator`), prefer the official one — it has the workflow this wrapper is built to chain with.

**Invocation:** call the `Skill` tool with `skill-creator:skill-creator`, passing the user's intent as the argument/context. Skill invocability is per-skill; attempt the call and observe the result rather than inferring from another skill's frontmatter.

**Fallback:** if the `Skill` tool returns a concrete refusal error, switch to inline execution:

1. Read `~/.claude/plugins/cache/claude-plugins-official/skill-creator/*/skills/skill-creator/SKILL.md` (glob the version segment).
2. Follow its instructions directly in this conversation.

Run skill-creator in **lightweight mode**: draft the skill and stop. The test-case / benchmark / description-optimization loops can be invoked separately when the user asks for them — review-skill (Step 3) handles the quality pass in this flow.

Let skill-creator:

1. Capture intent — use conversation context and `$ARGUMENTS`; the location is already settled from Step 1, so do not re-ask.
2. Write SKILL.md and any bundled resources the skill genuinely needs.
3. Save to the path confirmed in Step 1.
4. If the classification is **public**, apply the parameterization plan from Step 1 — replace personal values with env-var lookups that fall back to safe generic defaults, and note each env var in the skill's README section.

Record the final skill path — Step 3 needs it.

## Step 3: Review the skill via review-skill (inline execution)

`skill-tools:review-skill` has `disable-model-invocation: true`, which means the `Skill` tool cannot invoke it programmatically. Execute its flow inline instead — the orchestration still belongs to this wrapper.

1. Read the review-skill instructions: `${CLAUDE_SKILL_DIR}/../review-skill/SKILL.md` (or resolve the absolute path under `plugins/skill-tools/skills/review-skill/SKILL.md`).
2. Follow review-skill's Step 1 (fetch docs, read the new skill, note key areas).
3. Follow review-skill's Step 2 — use `ultrathink` — and write the review to `/tmp/skill-review-{skill-name}.md`.
4. Follow review-skill's Step 3 — use `ultrathink` — to challenge and refine the review.
5. **Skip** review-skill's "Now present the findings to the user and open the review file in their editor" instruction. This wrapper owns that handoff and defers it to Step 5.
6. **Skip** review-skill's Step 4 ("Ask the user if they would like to apply the recommendations"). Proceed directly to this wrapper's Step 4.

### Extra review criterion for public skills

If Step 1 classified the skill as **public**, add one more check during the review pass: scan the drafted skill for any leftover hardcoded personal values (paths containing the user's home dir, personal emails/usernames, internal URLs). Flag each as a self-heal target — the fix is to convert it to the env-var pattern with a safe default.

## Step 4: Self-heal

ultrathink

Read the refined review from `/tmp/skill-review-{skill-name}.md`. For each recommendation, decide:

- **Apply automatically** when the recommendation solves a concrete problem the reviewer identified, needs no clarification from the user, and aligns with the user's stated intent for the skill.
- **Defer** when the recommendation involves a design decision the user should own (e.g., renaming the skill, narrowing the trigger scope, splitting the skill in two). Deferred items become Step 5's "open questions".
- **Drop** when the recommendation is speculative, relies on unverifiable claims, or conflicts with a deliberate design choice the user made.

After applying fixes, re-read the skill end-to-end. If the review surfaced a genuine need for bundled resources (`scripts/`, `references/`, `assets/`), create them now. Cap the review loop at two passes; if open issues remain after the second pass, carry them into Step 5 as open questions.

## Step 5: Present

The user has waited silently through a create pass and a review pass. Reward that patience with a tight, scannable summary — under ~15 lines unless they ask for depth.

Include:

1. **Created** — skill path, classification (project / personal / public), and one-sentence purpose.
2. **Auto-applied fixes** — review recommendations that were applied, one line each. Skip this section entirely if nothing was applied.
3. **Env vars** (public skills only) — list any env vars the skill exposes, with their defaults, so the user can set them if they want non-default behavior.
4. **Open questions** — deferred recommendations needing a user decision, if any.
5. **Try it** — the slash command or trigger phrase for the new skill.

After the summary, open the finished `SKILL.md` in the user's editor so they can inspect and iterate — macOS: `open <path-to-SKILL.md>`; other platforms: the `$EDITOR` equivalent.

If the skill is part of a plugin, remind the user that plugin version bumps and `marketplace.json` registration are separate steps this wrapper does not perform.

## Non-goals

- Running skill-creator's full eval/benchmark loop. Users who want that should invoke `skill-creator:skill-creator` directly.
- Updating `marketplace.json`, bumping plugin versions, writing README entries, or committing the new skill. Those are separate workflows.
- Looping on review more than twice. Two passes is the cap; any remaining items land in Step 5 as open questions.
