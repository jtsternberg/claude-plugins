---
name: fable-delegate
description: Delegation discipline for main agents running on the Fable model (claude-fable-5). Use at the start of any Fable session and whenever substantive work is about to begin — the Fable main agent is the thinker/boss, not the doer, and should route execution to Opus/Sonnet subagents. Triggers when the main agent is powered by Fable and is about to edit files, run searches, run tests, or perform any mechanical multi-step execution itself.
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
