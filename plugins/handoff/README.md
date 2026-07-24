# Handoff Plugin

Preserve context between Claude Code sessions: one skill banks the current work into a handoff, a companion skill boots a fresh session from it, and hooks make the loop mechanical — pending handoffs are detected at session start, and a post-compaction nudge reminds the agent to bank context while it's still fresh.

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
claude plugin install handoff@jtsternberg
```

## Skills

Both are skills, so each can be invoked explicitly by slash command **or** triggered automatically by Claude when the conversation calls for it.

### `/handoff:handoff`

Create or update a handoff for the current work.

**What it captures** (the content contract):

- **Goal** — including how it evolved from the original ask
- **Current Progress**, **Files Changed**, **What Worked**, **What Didn't Work**, **Next Steps**
- **Anchor** — branch, HEAD SHA, and timestamp, so the next session can measure exactly what changed since the handoff was written
- **Session** — the session ID and transcript path (when the plugin's hooks have cached them), so the next agent can grep the previous session's transcript for details the doc left out

**Two storage backends**, detected automatically:

- **Beads** (preferred, when the `bd` CLI is installed and the repo has a `.beads/` directory): the handoff is stored as a bd issue titled `Handoff: <work-name>`. No file litter, and completion maps to `bd close`.
- **Files** (universal fallback): a `HANDOFF-<work-name>.md` in the working directory, named for the work (branch-based by default, descriptive when the branch name is generic). The file opens with a pickup banner telling the next agent to run `/handoff:pickup-handoff`, and gets added to `.git/info/exclude` so it never pollutes the repo.

### `/handoff:pickup-handoff`

Resume work from a handoff in a fresh session.

Finds the handoff (named file → branch/descriptive `HANDOFF*.md` → open `Handoff:` bd issues), reads it once, reconciles it against the actual repo state using the Anchor SHA ("N commits since the handoff was written; here's what changed"), and — assuming the user hasn't read the doc — plainly reports where things stand and the concrete plan before continuing. It also sweeps for stale leftover handoff files and flags obvious corpses.

**Lifecycle rule:** the handoff is a boot artifact, not a living document. The pickup agent never updates it after reading; when the work completes, the file is deleted (or the bd issue closed) and the user is told.

## Hooks

Installed automatically with the plugin (`hooks/hooks.json`):

- **Session start** (`startup`/`resume`): scans the working directory for `HANDOFF*.md` files and open `Handoff:` bd issues. If any exist, prints one compact line per finding (name, age, commits since its anchor) suggesting `/handoff:pickup-handoff`. Prints nothing when clean. It also caches the session's ID and transcript path to `/tmp/claude-handoff/<pid>.json`, which is where the handoff skill's Session section comes from.
- **Post-compaction** (`compact`): refreshes that cache and prints a one-line reminder that `/handoff:handoff` can bank fresh context before details fade.

Hook scripts are pure bash with no hard dependencies and degrade silently on any failure.

## Standalone use

Both skills work without the plugin's hooks (e.g. copied into a project as bare skills): detection at session start and the Session section simply don't happen, and everything else — writing, finding, reconciling, lifecycle — behaves the same.

## Use Cases

- **Session transitions**: end-of-day handoff to morning session
- **Context compaction**: bank details right after a compaction, while they're still recoverable
- **Long tasks**: preserve state for multi-day projects
- **Collaboration**: pass context to another developer on the same machine

## Additional Documentation

- [skills/handoff/SKILL.md](skills/handoff/SKILL.md) — handoff skill definition ([file backend](skills/handoff/references/files.md), [beads backend](skills/handoff/references/beads.md))
- [skills/pickup-handoff/SKILL.md](skills/pickup-handoff/SKILL.md) — pickup skill definition
