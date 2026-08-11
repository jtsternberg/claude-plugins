---
name: handoff
description: "Write or update a handoff so a next agent with fresh context can continue — 'hand off', 'wrap up for the next agent', session ending, or right after mid-task compaction."
when_to_use: |
  Also 'write a handoff', 'save context for later'. Not for routine note-taking mid-task.
allowed-tools: Bash, Read, Write
---

# Handoff

Bank the current work's context so a fresh agent can continue it. Handoffs live in one of two backends — a beads issue when beads is available, a `HANDOFF*.md` file otherwise.

## Backend preflight

```!
command -v bd >/dev/null 2>&1 && [ -d .beads ] && echo "Backend: beads — read references/beads.md before writing" || echo "Backend: files — read references/files.md before writing"
```

If the preflight above didn't run, run the check yourself: `command -v bd >/dev/null 2>&1 && [ -d .beads ]` → beads. **Read exactly one reference** ([references/beads.md](references/beads.md) or [references/files.md](references/files.md)) for where and how the handoff is stored, then fill the contract below.

## Work name (both backends)

Name the handoff for the **work**, not just the branch. Default to `git branch --show-current`; when that doesn't describe the work — a generic default branch (`main`, `master`, `develop`, `trunk`), a bare ticket ID, or a branch carrying several unrelated tasks — pick a short kebab-case name from what this session is actually about (e.g. `grafana-skill`). Not in a git repo / detached HEAD with no obvious short name → no name.

## Content contract (both backends)

Sections, in order:

1. **Goal** — what we're trying to accomplish. If it evolved from the original ask, note how and why.
2. **Current Progress** — what's been done so far.
3. **Files Changed** — files modified, created, or deleted this session.
4. **What Worked** — approaches that succeeded.
5. **What Didn't Work** — approaches that failed, so they're not repeated.
6. **Next Steps** — concrete, ordered action items for continuing.
7. **Anchor** — omit when not in a git repo. Exact shape (the `HEAD:` line is machine-parsed for drift detection):

   ```
   ## Anchor
   - Branch: <git branch --show-current>
   - HEAD: `<git rev-parse HEAD>`
   - Written: <date -u +%Y-%m-%dT%H:%M:%SZ>
   ```

8. **Session** — run:

   ```bash
   # Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
   SKILL_DIR="${CLAUDE_SKILL_DIR}"
   bash "$SKILL_DIR/scripts/session-info.sh"
   ```

   If it prints JSON, include the `session_id` and `transcript_path` values here (they let the next agent grep this session's transcript). If it prints nothing, errors, or the script doesn't exist, omit this section silently — no placeholder, no apology.

## To resume (end every run with this)

After saving, generate the harness-specific pickup command with the identifier just saved:

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/generate-command.sh" "<identifier>"
```

Reproduce the generated command exactly in this output:

```
Handoff saved: <absolute file path, or beads issue ID>

To resume in a fresh session, run <generated command>
Fallback: <backend-specific resume line from the reference>
```

**`<identifier>` is required, not decorative** — the beads issue ID or the absolute
file path, whichever backend you just wrote to. You know it at this point; pass it.
Emitting a bare pickup command forces the next agent to rediscover what
you already had, and that search is guesswork when several handoffs are open. Handing
it the identifier makes pickup deterministic: one `bd show <id>` / one `Read`.
