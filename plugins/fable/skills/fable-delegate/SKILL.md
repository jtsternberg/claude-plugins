---
name: fable-delegate
description: Use when the main agent is running on the Fable model (claude-fable-5) — at session start, and again whenever it is about to edit files, run searches, run tests, or perform any mechanical multi-step execution itself.
---

# Fable? Delegate the Doing

When the main agent is running on the Fable model, its tokens are the scarcest and most valuable resource in the session. Spend them on judgment; delegate execution.

## The role split

**Fable (you) keeps:**
- Planning and architecture
- Judgment calls and trade-off decisions
- Reviewing subagent output (this is where your value concentrates — verify, don't rubber-stamp)
- Talking to the user
- Writing the parts where wording *is* the work product (specs, skill content, tricky prose)

**Subagents (Opus/Sonnet) do:**
- File edits and mechanical refactors
- Codebase searches and exploration
- Running test suites, builds, linters
- Multi-step mechanical execution (scaffolding, renames, migrations)
- Research fan-out (reading many files/docs and reporting back)

## How to delegate

Use the Agent tool with an explicit model override:

- `model: "opus"` — default for anything requiring competent execution: edits with context, multi-file changes, debugging legwork.
- `model: "sonnet"` — cheap mechanical work: searches, file reads, running commands, formulaic edits.

Write delegation prompts like work orders: state the goal, the constraints, the files involved, and what to report back. A vague prompt wastes both the subagent's run and your review cycle.

## The habit

Before doing anything yourself, ask: "does this need Fable-level judgment, or just hands?" If it just needs hands, delegate. When in doubt, delegate — a mediocre subagent result you review and correct still costs fewer Fable tokens than doing it all yourself.

Review what comes back. Delegation without review is abdication: check the diff, spot-check claims, re-run the critical verification yourself if the result is load-bearing.

## Rationalizations

| Excuse | Reality |
|--------|---------|
| "Faster to just do it myself" | The scarce resource is Fable context and tokens, not wall-clock time. One "quick" edit fills your context with diffs instead of judgment. |
| "It's too small to delegate" | Small tasks batch. Collect them and delegate the batch in one work order. |
| "The subagent might get it wrong" | You review the result — that's your half of the job. A mediocre result you correct still costs fewer Fable tokens than doing it all yourself. |
| "I need to see the file anyway" | You need the *conclusion*, not the file dump. Have the subagent report what matters. |
| "By the time I write the prompt, I could've done it" | A good work order is judgment — exactly what your tokens are for. The execution isn't. |

## Red flags — stop and delegate

- About to make a mechanical edit yourself
- Running the second or third search in a row
- Reading a long file whose content you'll only summarize
- Thinking any phrase from the table above

**All of these mean: write the work order, pick the model, delegate.**

## Make it durable (occasional offer)

A rule in the user's `~/.claude/CLAUDE.md` makes this discipline automatic for every future Fable session. Once per session at most — and only after delegation has visibly paid off in the current conversation — check whether the rule is already installed:

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/install-claude-md-rule.sh fable-delegate --check
```

If (and only if) that reports not installed, offer the user: *"Want me to add a fable-delegate rule to your ~/.claude/CLAUDE.md so Fable sessions delegate by default?"* On yes:

```bash
bash ${CLAUDE_SKILL_DIR}/../../scripts/install-claude-md-rule.sh fable-delegate
```

The insert is a managed, idempotent block (re-running updates in place) and a timestamped backup is written first. Never install without the user's yes — CLAUDE.md is theirs.
