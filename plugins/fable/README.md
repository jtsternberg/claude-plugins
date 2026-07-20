# fable

Skills for working with — and like — the Fable model (`claude-fable-5`).

## Skills

### `fable-delegate`

Delegation discipline for a main agent running on Fable. On Fable, the main agent's tokens are the scarcest resource in the session, so it should behave as the thinker/boss — not the doer.

**The role split:**

- **Fable keeps** planning, architecture, judgment calls, reviewing subagent output, talking to the user, and writing the parts where the wording *is* the work product.
- **Subagents (Opus/Sonnet) do** file edits, codebase searches, running tests and builds, mechanical multi-step execution, and research fan-out.

Delegate via the Agent tool with an explicit model override — `model: "opus"` for work needing competent execution, `model: "sonnet"` for cheap mechanical work — and write each delegation prompt like a work order. Then review what comes back: delegation without review is abdication.

**Triggers** at the start of a Fable session and whenever substantive work is about to begin — especially when the Fable main agent is about to edit files, run searches, run tests, or perform mechanical multi-step execution itself.

### `think-like-fable`

The operating stance that makes an agent's judgment trustworthy — for sessions running on non-Fable models (Opus, Sonnet) doing substantive work. What users experience with Fable as "wisdom" (less back-and-forth, first answers closer to intent, pushback with substance, thinking steps ahead) is the output of a stance, not a list of behaviors — so the skill teaches the generator, then shows its manifestations:

**The stance: you own the outcome, not the response.** Three commitments make it concrete:

1. **The message is evidence, not the task** — the user's words are the strongest data about the goal, not the boundary of the job.
2. **The user's attention is the budget you spend** — an obvious question costs trust like a wrong action does; decide everything reversible, ask only what's genuinely theirs.
3. **Your reasoning must track truth, not comfort** — distinguish measured from defaulted; when challenged, verify rather than fold or dig in.

From those follow the recognizable habits: fix the class not the instance, follow your own diagnosis to its consequences (bad-data writers imply bad data already written), consider the shape of the work first, verify end-to-end with receipts, commit verified work without asking, and end turns with decisions rather than menus.

**Triggers** at the start of any non-Fable session facing judgment calls about scope, autonomy, and when to ask vs. act.

**Install:** `claude plugin install fable@jtsternberg`
