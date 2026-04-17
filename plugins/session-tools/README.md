# Session Tools

A bucket of skills for working with Claude Code session transcripts stored under `~/.claude/projects/`. Recap, clean up, retitle, or otherwise make sense of what your past sessions contain.

## Install

```bash
/plugin install session-tools@jtsternberg
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
- **`scripts/install_cron.sh`** — manages a weekly launchd job that fires `claude -p "/sessions-weekly-recap --weekly ..."` headlessly
- **Renamed to `sessions-weekly-recap`** to avoid clobbering upstream `sessions-recap` if re-installed via amskills

#### Modes

- **Daily (default):** one `YYYY-MM-DD.md` per date
- **Weekly (`--weekly`):** one `Week-M.D.YY.md` per ISO week (unpadded Monday date, e.g. `Week-4.13.26.md`)

#### Usage

```
/sessions-weekly-recap                                    # Daily, last 7 days
/sessions-weekly-recap --since 2026-04-01                 # Daily, from a date
/sessions-weekly-recap --weekly                           # Weekly, previous full week
/sessions-weekly-recap --weekly --output-dir "~/notes"    # Weekly, custom output
```

Default output:
- Daily → `~/.claude/daily-notes/`
- Weekly → `~/.claude/weekly-notes/`

#### Scheduling a weekly recap (macOS launchd)

The skill ships with a helper that installs a `launchctl`-managed plist.

```bash
# From inside a Claude Code session with this plugin enabled:
bash ${CLAUDE_SKILL_DIR}/scripts/install_cron.sh install \
  --output-dir "/absolute/path/to/output" \
  --day mon \
  --time 09:00

# Other actions:
bash ${CLAUDE_SKILL_DIR}/scripts/install_cron.sh status
bash ${CLAUDE_SKILL_DIR}/scripts/install_cron.sh logs
bash ${CLAUDE_SKILL_DIR}/scripts/install_cron.sh run-now
bash ${CLAUDE_SKILL_DIR}/scripts/install_cron.sh uninstall
```

Outside of a skill context (e.g. from a plain shell), call the script directly:

```bash
bash /path/to/claude-plugins/plugins/session-tools/skills/sessions-weekly-recap/scripts/install_cron.sh install \
  --output-dir "/absolute/path/to/output"
```

The installed plist:
- **Label:** `com.jtsternberg.sessions-weekly-recap`
- **Path:** `~/Library/LaunchAgents/com.jtsternberg.sessions-weekly-recap.plist`
- **Fires:** `claude -p "/sessions-weekly-recap --weekly --output-dir \"<path>\"" --dangerously-skip-permissions`
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

## Planned skills

Candidates for future inclusion (not built yet):

- **sessions-prune** — archive or delete old transcripts
- **sessions-retitle** — rename session files based on actual content
- **sessions-search** — full-text search across transcripts

---

## Credits

`sessions-weekly-recap` is based on [sessions-recap](https://skills.awesomemotive.com) by Fernando Duro.
