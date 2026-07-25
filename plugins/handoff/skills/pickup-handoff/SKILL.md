---
name: pickup-handoff
description: Resume work from a handoff written by a previous agent. Use when the user points you at a HANDOFF file, says "pick up where we left off", "continue this handoff", "resume from the handoff doc", hands you a HANDOFF-*.md or a beads issue titled "Handoff:", or a session-start notice reported a pending handoff. Pairs with the handoff skill.
allowed-tools: Bash, Read, Glob, Grep
argument-hint: "[<beads-issue-id> | <path-to-HANDOFF.md>]"
---

# Pickup Handoff

Resume work from a handoff written by a previous agent (via the companion `handoff` skill, whose docs point here: `/handoff:pickup-handoff`).

**Assume the user has NOT read the handoff.** They are handing you a pointer and expecting you to get up to speed and tell *them* what's going on. Don't silently continue — surface your understanding and plan first.

**The handoff is a boot artifact, not a living document.** Read it once, boot from it, then work from the repo — the repo is the source of truth from that moment on. Never update a handoff after reading it:

- Don't append progress to it.
- Don't "keep it current" as you work.
- Don't edit it "for the next agent" — writing a fresh handoff at session end is the `handoff` skill's job, not an edit to this one.

## Steps

1. **Find the handoff.**

   **If `$ARGUMENTS` holds an identifier, that IS the handoff — go straight to step 2.**
   The `handoff` skill emits it precisely so this step costs one command:

   - looks like a beads id (e.g. `claude-plugins-20xu`) → `bd show <id>`
   - looks like a path → `Read` it

   Do **not** also glob for `HANDOFF*.md`, list open `Handoff:` issues, or check the
   branch — you were told which one. Skip all of it. Only fall through to the search
   below if the identifier turns out not to resolve, and say so when you do.

   **With no argument**, search in this order:
   - `HANDOFF*.md` in the current working directory — prefer the one matching the current branch (`git branch --show-current`), then `HANDOFF.md`.
   - If bd is available (`command -v bd >/dev/null 2>&1 && [ -d .beads ]`): open issues titled `Handoff:` — `bd list --status open,in_progress --title-contains "Handoff:" --json`.
   - Multiple candidates and no clear match → list them and ask which to use.

2. **Read it in full** (file, or `bd show <id>`).

3. **Reconcile against reality.** The doc describes the past; check the present:
   - If it has an **Anchor** section, run `git log --oneline <anchor-sha>..HEAD` — report "N commits since the handoff was written" and what they touched.
   - Run `git status`; spot-check the doc's "Files Changed" claims.
   - Note anything the doc claims that the repo contradicts.

4. **Brief the user**, plainly (they haven't seen the doc):
   - **Where things stand**: the goal and what's already done, in a few sentences.
   - **Drift**: commits/changes since the handoff was written and whether they affect the plan.
   - **Your plan**: concrete, ordered next steps — the doc's "Next Steps" reconciled with what you actually found.
   - **Anything that doesn't add up**: discrepancies or open questions the doc left unresolved.
   - **Stale sweep**: list any *other* `HANDOFF*.md` files in the directory with mechanical facts only — file age, commits since their anchor SHA, whether their branch is merged or deleted (`git branch --merged`) — and flag obvious corpses for deletion. Cheap git commands only; no subagents for this.

5. **If the doc is thin on a detail you need**: its **Session** section (when present) names the previous session's transcript JSONL — grep it for the missing specifics (decisions, error messages, exact commands). If the `hotline:dial` skill is available, you can also offer to dial a fresh agent seeded with that transcript for interactive questioning; read hotline's dial skill for how.

6. **Proceed with the plan** (respecting the current permission mode / plan mode).

7. **When the work the handoff describes is complete**: delete the handoff file (or `bd close <id> --reason "<what completed>"` for a beads handoff), and tell the user you did. A completed handoff left behind is the next session's false alarm.
