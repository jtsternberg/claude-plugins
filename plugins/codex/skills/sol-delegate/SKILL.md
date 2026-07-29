---
name: sol-delegate
description: Use when Sol is the main Codex agent and should delegate execution to Terra, GPT-5.5, GPT-5.4, or another available model while retaining judgment and review.
---

# Sol: Delegate the Doing

Use Sol's scarce frontier-model attention for decisions, not routine execution. Keep ownership of the outcome while routing mechanical work to a cheaper or more appropriate Codex model.

## Keep in Sol

- Understand the user's actual goal and define the work shape.
- Make architecture, scope, risk, and trade-off decisions.
- Write prompts that give delegated work a concrete contract.
- Review delegated output critically against the goal.
- Resolve ambiguity that genuinely requires the main agent's judgment.
- Communicate decisions, evidence, and remaining risks to the user.

## Delegate

Route file searches, routine edits, test runs, mechanical refactors, documentation passes, and bounded research to another available model. Prefer Terra for normal execution, GPT-5.5 or GPT-5.4 when the delegated task needs more reasoning, and Luna when direct model selection becomes available.

When direct Luna selection is unavailable, use Hotline/cmux only if that path is already configured and the user has put it in scope. Do not pretend a model switch occurred merely because the task was described as a Luna assignment.

## Write the work order

Every delegation prompt must state:

1. The outcome to produce.
2. The files or surfaces in scope.
3. Constraints, including files or actions to leave untouched.
4. The checks or evidence required before reporting completion.
5. What the delegated agent must report back.

Delegate independent tasks separately when their outputs can be reviewed independently. Keep dependent work in sequence so the next agent receives the verified result of the previous step.

## Review the result

Treat delegated output as evidence, not authority. Inspect the diff or artifact, run the load-bearing checks, and verify the behavior at the surface the user actually cares about. If the delegated agent found a broader class of problem, follow that diagnosis instead of accepting the narrow patch.

Do not delegate the final judgment about whether the user's goal is met. Do not end with a report that merely says another model changed files; report what changed, what was verified, and what remains uncertain.

## Model routing

Use this default routing unless the task's risk or the user's instruction calls for a different choice:

| Main agent | Execution target | Best fit |
| --- | --- | --- |
| Sol | Terra | Routine edits, searches, tests, and bounded implementation |
| Sol | GPT-5.5 | Complex implementation or debugging needing a stronger delegate |
| Sol | GPT-5.4 | Everyday implementation with moderate reasoning needs |
| Sol | Luna | Fast mechanical work once direct selection exists |

The routing table is a policy, not proof that a model was invoked. Record the actual target and inspect the returned work.
