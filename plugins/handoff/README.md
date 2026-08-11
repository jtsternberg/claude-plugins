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

- **Beads** (preferred, when the `bd` CLI is installed and the repo has a `.beads/` directory): the handoff is stored as a bd issue titled `pending-handoff: <work-name>`. No file litter, and completion maps to `bd close`. The marker is deliberately an unusual string — a plain `Handoff:` prefix collides with ordinary issues *about* handoffs, and `bd --title-contains` matches case-insensitively and anywhere in the title.
- **Files** (universal fallback): a `HANDOFF-<work-name>.md` in the working directory, named for the work (branch-based by default, descriptive when the branch name is generic). The file opens with a pickup banner containing the harness-specific pickup command, and gets added to `.git/info/exclude` so it never pollutes the repo.

### Pickup handoff

Claude Code: `/handoff:pickup-handoff [<bd-issue-id> | <path>]`

Codex: `$handoff:pickup-handoff [<bd-issue-id> | <path>]`

Resume work from a handoff in a fresh session.

**Pass the identifier when you have one** — `/handoff:pickup-handoff myproject-20xu` in Claude Code or `$handoff:pickup-handoff myproject-20xu` in Codex — and it resolves that handoff in a single lookup. The `handoff` skill detects the active harness and prints the correct command when it saves, and the session-start notice lists the identifier per finding, so it's almost always available. Without it, pickup has to search (branch/descriptive `HANDOFF*.md` → open `pending-handoff:` bd issues), which is guesswork once more than one handoff is open.

It then reads the handoff once, reconciles it against the actual repo state using the Anchor SHA ("N commits since the handoff was written; here's what changed"), and — assuming the user hasn't read the doc — plainly reports where things stand and the concrete plan before continuing. It also sweeps for stale leftover handoff files and flags obvious corpses.

**Lifecycle rule:** the handoff is a boot artifact, not a living document. The pickup agent never updates it after reading; when the work completes, the file is deleted (or the bd issue closed) and the user is told.

## Hooks

Installed automatically with the plugin (`hooks/hooks.json`):

- **Session start** (`startup`/`resume`): scans for `HANDOFF*.md` files and open bd issues matching the `pending-handoff` marker, printing one compact line per finding (identifier, age, commits since its anchor) and telling the agent to run `/handoff:pickup-handoff <id-or-filename>` in Claude Code or `$handoff:pickup-handoff <id-or-filename>` in Codex. If the hook cannot distinguish the harness safely, it gives a neutral instruction instead of guessing. Prints nothing when clean. It also caches the session's ID and transcript path to `/tmp/claude-handoff/<pid>.json` for either Claude Code or Codex, which is where the handoff skill's Session section comes from.

  Matches are **sorted, never discarded.** Titles starting with `pending-handoff:` (any casing) are reported as pending handoffs; anything that merely mentions the marker is listed separately as a weaker signal. Dropping a real handoff means a cold start — the exact failure the hook exists to prevent — while labelling an ordinary issue as a handoff trains you to ignore the notice. If *only* weak matches exist, it says so rather than claiming a pending handoff.
- **Post-compaction** (`PostCompact`, `manual`/`auto`): refreshes that cache and prints a one-line reminder to run `/handoff:handoff` in Claude Code or `$handoff:handoff` in Codex. If the hook cannot distinguish the harness safely, it gives a neutral instruction instead of guessing. It is a dedicated post-compaction event, so the nudge runs once rather than also using `SessionStart`'s `compact` source.

Codex requires a review/trust decision before a newly installed or changed plugin command hook runs. Open `/hooks` and trust the `handoff` hook definition before treating startup or compaction behavior as enabled. Claude Code does not use Codex's hook trust gate.

Hook scripts are pure bash with no hard dependencies and degrade silently on any failure.

```bash
bash plugins/handoff/tests/session-start_test.sh   # stubs `bd` via PATH; touches no real database
```

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
