---
description: Pick up where a previous agent left off from a handoff document
allowed-tools: Bash, Read, Glob
---

Resume work from a handoff document written by a previous agent (see `/handoff`).

**Assume the user kicking you off has NOT read the handoff document.** They are handing you a file and expecting you to get up to speed and tell *them* what's going on. So don't just silently continue — surface your understanding and plan first.

Steps:
1. Find the handoff file:
   - If the user named a file, use it.
   - Otherwise, get the current branch via `git branch --show-current` and look for `HANDOFF-<branch>.md` in the current working directory, then fall back to `HANDOFF.md`.
   - If multiple `HANDOFF-*.md` files exist and none clearly matches the branch, list them and ask which to use.
2. Read the handoff document in full.
3. Verify the current state against it — check `git status`, `git log`, and the listed "Files Changed" — so your plan reflects reality, not just what the doc claims.
4. Present to the user, plainly (they have not seen the doc):
   - **Where things stand**: the goal and what's already been done, in a few sentences.
   - **Your plan**: concrete, ordered next steps you intend to take, based on the handoff's "Next Steps" reconciled with what you actually found in the repo.
   - **Anything that doesn't add up**: discrepancies between the doc and the current state, or open questions the doc left unresolved.
5. Then proceed with the plan (respecting the current permission mode / plan mode).
