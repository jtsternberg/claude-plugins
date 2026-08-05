# Session Tools

A bucket of skills for working with Claude Code session transcripts stored under `~/.claude/projects/`. Recap them, catch up on one you abandoned, clean up, retitle, or otherwise make sense of what your past sessions contain.

## Install

```bash
claude plugin install session-tools@jtsternberg
```

Or locally:

```bash
claude plugins add /path/to/claude-plugins/plugins/session-tools
```

---

## Skills

### 📅 sessions-weekly-recap

Generate daily or weekly recap markdown notes from your Claude Code session transcripts. Extracts user prompts, follow-ups, and commits — then synthesizes them into themed summaries grouped by topic (PR Reviews, Feature Work, Bug Investigation, etc.).

Forked from Fernando Duro's upstream `sessions-recap`. Adds weekly mode, `--output-dir` override, and a macOS launchd installer.

#### What's new vs. upstream

- **`--weekly` flag** — groups sessions by ISO week (Mon–Sun); defaults to the previous full week
- **`--output-dir PATH`** — override the default output location
- **`scripts/install_cron.sh`** — manages a weekly launchd job that fires `claude -p "/session-tools:sessions-weekly-recap --weekly ..."` headlessly
- **Renamed to `sessions-weekly-recap`** to avoid clobbering upstream `sessions-recap` if re-installed via amskills

#### Modes

- **Daily (default):** one `YYYY-MM-DD.md` per date
- **Weekly (`--weekly`):** one `Week-M.D.YY.md` per ISO week (unpadded Monday date, e.g. `Week-4.13.26.md`)

#### Usage

**Generate recaps:**

```
/session-tools:sessions-weekly-recap                                    # Daily, last 7 days
/session-tools:sessions-weekly-recap --since 2026-04-01                 # Daily, from a date
/session-tools:sessions-weekly-recap --weekly                           # Weekly, previous full week
/session-tools:sessions-weekly-recap --weekly --output-dir "~/notes"    # Weekly, custom output
```

**Manage the weekly cron (macOS launchd):**

```
/session-tools:sessions-weekly-recap --install-cron --output-dir "/absolute/path" [--day mon] [--time 09:00]
/session-tools:sessions-weekly-recap --cron-status
/session-tools:sessions-weekly-recap --cron-run-now
/session-tools:sessions-weekly-recap --cron-logs
/session-tools:sessions-weekly-recap --uninstall-cron
```

Default output:
- Daily → `~/.claude/daily-notes/`
- Weekly → `~/.claude/weekly-notes/`

#### Style anchor

Every invocation, Claude is shown a sample weekly recap as a style reference — headings, Summary section, theme organization, bullet density. By default the skill uses a bundled generic example (`skills/sessions-weekly-recap/references/EXAMPLE-WEEKLY.md`).

To override with a past recap you like, set `$SESSIONS_RECAP_EXAMPLE` to its absolute path:

```bash
# In ~/.claude/settings.json "env", or exported in your shell:
export SESSIONS_RECAP_EXAMPLE="/absolute/path/to/my-favorite-Week-X.Y.Z.md"
```

Override resolution:
- `$SESSIONS_RECAP_EXAMPLE` set + readable → use the user file
- else → use the bundled default

The bundled default contains placeholder content (no real work references); the override lets you anchor Claude's voice to your actual past recaps without committing your work details to this public plugin repo.

#### Scheduling details

Cron flags route through `scripts/install_cron.sh`. The installer writes a plist to `~/Library/LaunchAgents/` and loads it via `launchctl`.

If you prefer to bypass the skill and call the script directly (e.g. from a plain shell):

```bash
SCRIPTS=/path/to/claude-plugins/plugins/session-tools/skills/sessions-weekly-recap/scripts
bash $SCRIPTS/install_cron.sh install --output-dir "/absolute/path" --day mon --time 09:00
bash $SCRIPTS/install_cron.sh status
bash $SCRIPTS/install_cron.sh logs
bash $SCRIPTS/install_cron.sh run-now
bash $SCRIPTS/install_cron.sh uninstall
```

The installed plist:
- **Label:** `com.jtsternberg.sessions-weekly-recap`
- **Path:** `~/Library/LaunchAgents/com.jtsternberg.sessions-weekly-recap.plist`
- **Fires:** `claude -p "/session-tools:sessions-weekly-recap --weekly --output-dir \"<path>\"" --dangerously-skip-permissions`
- **Logs:** `~/.claude/logs/sessions-weekly-recap.{out,err}.log`

`--dangerously-skip-permissions` is required because there's no TTY to approve tool calls during the scheduled run. The job runs as your user with your existing Claude Code auth.

#### Requirements

- Python 3.10+
- Claude Code session transcripts at `~/.claude/projects/`
- macOS for the launchd installer (the skill itself works on any OS)

#### Files

| File | Purpose |
|------|---------|
| `skills/sessions-weekly-recap/SKILL.md` | Skill definition — modes, merge rules, writing guidelines |
| `skills/sessions-weekly-recap/scripts/extract_sessions.py` | Scans `~/.claude/projects/*.jsonl` and emits structured JSON |
| `skills/sessions-weekly-recap/scripts/install_cron.sh` | Installs/manages the weekly launchd job |

---

### 🛟 sessions-catch-up

Brief yourself on a **different** session without touching it. Point it at a session id (or prefix, or slug) and it reads that session's transcript off disk and tells you where the work landed and what's waiting on you.

Built for one specific moment: you come back after a couple of days to a stalled session and can't remember what you were doing. **Speed is the point** — you could scroll back and read the whole thing yourself, so if this isn't faster than that, it's worthless.

```
/session-tools:sessions-catch-up 5263bfb5                 # id prefix
/session-tools:sessions-catch-up eager-roaming-rose       # session slug
/session-tools:sessions-catch-up 5263bfb5 --deep          # also mine the long arc
```

#### Why not `/export`?

`/export` can't be driven from outside a session. `claude -p "/export <path>"` answers *"/export isn't available in this environment"* and writes nothing — it's a TUI-only local command, and there's no `claude export` subcommand. The only other way to reach it is typing into a live REPL, which needs the session running in a pane and **appends a turn to the session you're trying to read**.

So this reads the JSONL directly. That works on dead sessions, costs zero tokens, mutates nothing, and returns in ~100 ms. It also allows a better shape than a transcript dump:

- Tool-result bodies dropped entirely (they're ~70% of a transcript, and stored *twice*), tool calls collapsed to one-line labels
- Recent turns near-verbatim, older turns compressed to a timeline
- **Derived signals** a dump has no concept of: whether the session is blocked on *you*, the last todo state, referenced beads **re-resolved to their current status**, files touched, errors, subagents dispatched
- Compaction summaries surfaced (detection is `isCompactSummary`, not the long-gone `type: "summary"`)

Typical reduction is 200–800x. Measured: 5.4 MB → 6 KB in 117 ms.

#### `export-session.mjs` — the `claude export` that doesn't exist

The digest is one format of a general-purpose transcript reader, usable on its own and by other tools:

```bash
SCRIPTS=plugins/session-tools/scripts
node $SCRIPTS/export-session.mjs <id|prefix|slug> --format digest   # catch-up briefing
node $SCRIPTS/export-session.mjs <id> --format md                   # full transcript (archive fidelity)
node $SCRIPTS/export-session.mjs <id> --format json                 # structured
node $SCRIPTS/export-session.mjs --list                             # id · idle · slug · cwd
```

Other flags: `--fast`, `--window N`, `--max-chars N` (a hard ceiling), `--truncate N`, `--compaction-full`, `--no-beads`, `--out PATH`, `--cwd PATH`.

Resolution order is exact id → id prefix → slug/title, disambiguated by proximity to your cwd. **Ambiguity is reported, never guessed** — you get a candidate list, same posture as `graveyard peek`.

#### Optional shell wrapper

```bash
bash $SCRIPTS/install-wrapper.sh install      # → ~/.local/bin/claude-session-catchup
claude-session-catchup <id>
claude-session-catchup --yolo <id>            # or CLAUDE_CATCHUP_YOLO=1
```

`--dangerously-skip-permissions` is **never** assumed — it's opt-in via `--yolo` or the env var. (Bash rather than PHP/Node on purpose: it hands an interactive TTY to `claude`, and a wrapper that captured output would swallow the REPL.)

#### Progressive enhancements

If `hotline` is installed and the target session is blocked on a question, the skill offers to send your answer over. If `handoff` is installed, it can persist the caught-up state. Neither is required, and a small ledger (`~/.claude/sessions-catch-up.prefs.json`) makes sure a declined offer degrades to a one-line protip and then goes quiet permanently.

#### Requirements

Node 18+. (`sessions-weekly-recap` uses Python; this skill uses Node so its parser can be a direct port of the richest existing implementation rather than a third translation of it.)

---

### 🌱 sessions-fork

**The `handoff` skill, inverted.** Handoff pushes context *forward* to a future session;
this pulls it *back* from a past one — so the session you're in starts out knowing what it
needs to know.

```
/sessions-fork 5263bfb5
/sessions-fork eager-roaming-rose
```

It reads the session, reports what transferred, and **stops on a check-in.** It doesn't
plan, scaffold, or start work — because the work you're about to do may have nothing to do
with the session you just read. That's the whole point: catching up is what makes the
session useful for whatever comes next, related or not.

The most valuable thing it surfaces is **dead ends** — what was already tried and
abandoned, so it isn't retried. Since `thinking` blocks are empty on disk, it says "the
transcript doesn't say why" rather than inventing a rationale.

Same reader as `sessions-catch-up`, different question. Catch-up answers *"what's the
status of that session, and what's waiting on me in it?"* Fork answers *"what does this
session now know that it didn't before?"*

The source session is never resumed, forked, or written to.

---

## Shared machinery (why it lives at the plugin root)

Three skills read transcripts — `sessions-catch-up`, `sessions-fork`, and
`sessions-weekly-recap` — so the reader lives **once**, at the plugin root, not inside any
one skill:

```
plugins/session-tools/
├── scripts/            ← shared: lib/, export-session.mjs, nudge.mjs, install-wrapper.sh
├── references/         ← shared prose: reading-a-digest.md
├── tests/              ← transcript.test.mjs
└── skills/             ← sessions-catch-up, sessions-fork, sessions-weekly-recap
```

Skills reach it with `${CLAUDE_PLUGIN_ROOT}` — the documented variable for a plugin's
install directory, which keeps working after a marketplace install:

```bash
node "${CLAUDE_PLUGIN_ROOT}/scripts/export-session.mjs" <target> --format digest
```

This matters because the parser has already drifted twice across this repo; a per-skill
copy would guarantee a third. `tests/parser-drift.test.mjs` guards the one remaining
duplicate (hotline's switchboard).

| File | Purpose |
|------|---------|
| `scripts/lib/transcript.mjs` | **Source of truth** for parsing + derived signals |
| `scripts/lib/session-index.mjs` | id/prefix/slug resolution + cached index |
| `scripts/lib/format.mjs` | digest / md / text / json renderers |
| `scripts/export-session.mjs` | CLI entry |
| `scripts/nudge.mjs` | Offer-backoff ledger |
| `scripts/install-wrapper.sh` | Optional `claude-session-catchup` shim |
| `references/reading-a-digest.md` | How to read a digest; tail states; what to trust |

#### Tests

Covered by the repo-wide runner (`bash tests/run-all.sh`), or directly:

```bash
node --test plugins/session-tools/tests/transcript.test.mjs
```

---

## Planned skills

Candidates for future inclusion (not built yet):

- **sessions-prune** — archive or delete old transcripts
- **sessions-retitle** — rename session files based on actual content
- **sessions-search** — full-text search across transcripts

---

## Credits

`sessions-weekly-recap` is based on [sessions-recap](https://skills.awesomemotive.com) by Fernando Duro.
