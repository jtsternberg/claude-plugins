---
name: sessions-weekly-recap
description: "Generate daily or weekly recap notes from Claude Code session transcripts. Extracts session data, synthesizes human-readable summaries grouped by theme, and writes them as markdown files. Supports incremental merge into existing notes. JT's fork — adds --weekly mode, --output-dir override, and launchd cron management (macOS only)."
disable-model-invocation: true
allowed-tools: "Bash(python3 *), Bash(bash *), Read, Write, Edit"
argument-hint: "[--weekly] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--output-dir PATH] [--all]"
---

# Sessions Weekly Recap

Generate daily or weekly recap markdown notes from Claude Code session transcripts. Extract what was worked on, synthesize it into themed sections, and write one `.md` file per period.

> **Platform:** recap generation works on any OS. The cron management flags (`--install-cron` etc.) are **macOS-only** — they wrap `launchctl`. On Linux, point the user at `cron` or `systemd --user` as manual alternatives.

## Modes

- **Daily (default):** one `YYYY-MM-DD.md` per date.
- **Weekly (`--weekly`):** one `Week-M.D.YY.md` per ISO week (Monday of that week, no zero padding).

## Output Directory

Default: `~/.claude/daily-notes/` for daily, `~/.claude/weekly-notes/` for weekly.

Override with `--output-dir "/some/path"`. If the directory doesn't exist, create it.

## Arguments

Parse the `$ARGUMENTS` string for these flags.

**Recap generation flags:**
- `--weekly` — enable weekly mode
- `--since YYYY-MM-DD` — start of date range
- `--until YYYY-MM-DD` — end of date range
- `--output-dir PATH` — override output directory (path may contain spaces; strip surrounding quotes; resolve `~` and relative paths to absolute before forwarding to the extractor or cron installer)
- `--all` — include sessions of any age (overrides the default 7-day lookback; takes precedence over `--since`). Use when the user asks for a recap spanning months or their entire history.

When `--weekly` is set without dates, the extraction script defaults to the previous full week (last Monday through last Sunday). That's the expected behavior for the weekly cron that runs Monday morning.

**Cron management flags (mutually exclusive with recap generation):**
- `--install-cron`, `--uninstall-cron`, `--cron-status`, `--cron-logs`, `--cron-run-now`

If any cron flag is present, **load `references/CRON.md` and follow its instructions**. Skip the recap workflow below — the cron flags are handled entirely in that reference.

## Workflow

### Step 1: Extract Session Data

Run the extraction script, passing through `--weekly`, `--since`, `--until`, `--all`:

```bash
python3 ${CLAUDE_SKILL_DIR}/scripts/extract_sessions.py [--weekly] [--since ...] [--until ...] [--all]
```

**Do not pass `--output-dir` to the script** — that flag is handled by this SKILL.md, not the extractor.

The script outputs JSON. In daily mode: `{"dates": {"YYYY-MM-DD": [sessions]}, ...}`. In weekly mode: `{"weeks": {"YYYY-MM-DD": [sessions]}, ...}` where the key is the Monday of that week.

Each session includes:
- `first_message` — initial user prompt (up to 500 chars)
- `follow_ups` — subsequent user messages (up to 8)
- `commits` — git commits made during the session
- `subagent_count`, `size_bytes` — complexity proxies
- `date`, `time` — when it ran

### Step 2: Check for Existing Notes

For each period (date or week) in the extracted data, check if a note already exists at the target filename. Read it if so (merge rules in Step 3).

**Filename conventions:**
- Daily: `{output_dir}/YYYY-MM-DD.md`
- Weekly: `{output_dir}/Week-M.D.YY.md` — Monday date, **no zero padding** (e.g., `Week-4.13.26.md`, `Week-12.1.25.md`)

### Step 3: Synthesize Notes

For each period, read the session data and write the note. This is the creative step.

#### Style Anchor

A sample weekly recap is always injected below as a **style reference** — use it to match the level of specificity, bullet density, theme organization, and tone. **Do not copy content or events from the anchor into new recaps** — it may be a generic template or a past recap of entirely different work.

Resolution order:
1. If `$SESSIONS_RECAP_EXAMPLE` is set and readable, inject that file (user override).
2. Otherwise, inject the bundled generic default (`references/EXAMPLE-WEEKLY.md`).

```!
if [ -n "${SESSIONS_RECAP_EXAMPLE:-}" ] && [ -r "${SESSIONS_RECAP_EXAMPLE:-}" ]; then
  echo "<!-- style anchor: user override (\$SESSIONS_RECAP_EXAMPLE=$SESSIONS_RECAP_EXAMPLE) -->"
  cat "$SESSIONS_RECAP_EXAMPLE"
else
  echo "<!-- style anchor: bundled default -->"
  cat "${CLAUDE_SKILL_DIR}/references/EXAMPLE-WEEKLY.md"
fi
```

#### Daily Writing Guidelines

- **Heading:** `# YYYY-MM-DD — Day of Week`
- **Group by theme**, not by session: PR Reviews, Feature Work, Bug Investigation, Production Incidents, Tooling, Git Maintenance, Communication, etc.
- **Use bullet points**; bold PR/issue numbers (e.g., `**backend#689**`).
- **One line per activity** when possible.
- **Extract "what" and "why"** from user prompts. First message = what was started; follow-ups reveal pivots and outcomes.
- **Include outcomes** when visible ("Fixed and pushed", "Closed PR", "Created issue").
- **Do not fabricate.** If prompts are thin, write thin bullets. Don't invent findings.

#### Weekly Writing Guidelines

Same principles, but:

- **Heading:** `# Week of YYYY-MM-DD — Mon Mmm D to Sun Mmm D` (e.g., `# Week of 2026-04-13 — Mon Apr 13 to Sun Apr 19`)
- **Add a "Summary" section at the top** (2-3 sentences) with the week's main themes and biggest wins.
- **More aggressive consolidation.** Seven days of work deserves tighter grouping than a single day. Merge related bullets across days into one entry with a date range or count.
- **Theme sections below the summary** — same themes as daily, but organize by impact, not chronology. Biggest/most visible work first.
- **Optional subsection per theme** listing the days things happened, if useful.

#### Merge Rules (existing note found)

1. Read the existing note. Understand what's already covered.
2. Match extracted sessions against existing content by PR/issue numbers, keywords, activity descriptions.
3. Only add entries for sessions not already represented.
4. Append to existing theme headings where appropriate; create new headings if needed.
5. **Do not rewrite or rephrase existing content.** Preserve the user's edits.
6. If all sessions are already covered, skip and move on.

### Step 4: Write Notes

Write each note to the resolved path. Create parent directories if missing.

### Step 5: Report

Show:
- Mode (daily/weekly)
- Notes created / updated / skipped
- Period(s) covered
- Output directory path
- Path to each file written

## Scheduling a Weekly Recap

The skill can install a macOS launchd job that runs `claude -p` headlessly on a schedule. See `references/CRON.md` for full details, flag mapping, and the bypass-the-skill direct-invocation syntax.
