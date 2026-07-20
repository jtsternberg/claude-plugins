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

**Install:** `claude plugin install fable@jtsternberg`
