---
name: foresight
description: "Read meeting transcripts, summaries, attendees, and notes from the Google AI Edge Foresight macOS app (on-device meeting transcription), draft meeting notes from them, and optionally write those notes back into the app behind guards with an undo journal. Use for \"review today's meeting transcripts\", \"draft meeting notes\", \"what did we decide in the X meeting\", \"search my meetings for Y\", \"Foresight\", or any request about locally transcribed meetings."
when_to_use: |
  Use when the user says "review the meeting transcripts from today and draft some meeting notes",
  "draft notes for the <name> meeting", "what was said about X in yesterday's call",
  "search my meeting transcripts", "put these notes into Foresight", "undo that notes write",
  or mentions Foresight / Google AI Edge Foresight meetings, transcripts, or enhanced notes.
---

# Foresight meetings

Foresight records meetings on-device and keeps everything in one SQLite file. The
bundled `foresight.py` is the only way in: it reads with `mode=ro`, checks the schema
first, and guards its one write. macOS only (the app is).

Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"
python3 "$SKILL_DIR/scripts/foresight.py" doctor
```

Every command takes `--json`. Exit 3 means the app's schema changed under the tool —
report it to the user and stop; do not query the database by hand to get around it.
Exit 4 is a missing or ambiguous meeting (the message lists candidates).

## Find the meetings

Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"
python3 "$SKILL_DIR/scripts/foresight.py" meetings --today --transcribed
python3 "$SKILL_DIR/scripts/foresight.py" meetings --since 2026-10-19 --until 2026-10-22 --name standup
```

Windows: `--today`, `--yesterday`, `--date D`, `--since D [--until D]` (local dates,
inclusive). Each row shows start, duration, flags (`T` transcript, `S` the app's own
summary, `N` user notes, `E` enhanced notes), the `event_id`, and the title. Meetings
without `T` are empty "[New Meeting]" shells the app creates — skip them.

A meeting reference is its `event_id`, its note id, or a title substring that matches
exactly one meeting.

## Read one

Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"
python3 "$SKILL_DIR/scripts/foresight.py" show <ref>            # metadata, app summary, notes, enhanced notes
python3 "$SKILL_DIR/scripts/foresight.py" transcript <ref>      # header + full transcript
python3 "$SKILL_DIR/scripts/foresight.py" notes <ref> --json    # user notes + content_sha256 (needed to write)
python3 "$SKILL_DIR/scripts/foresight.py" search "pricing" --since 2026-10-01
```

How to read a transcript:

- **Speakers are audio channels, not people.** `[Microphone]` is the user's own mic;
  `[Remote]` is everyone else on the call, merged. Attribute a `[Remote]` line to a named
  person only when the text itself makes it clear ("thanks, Sam"), and say so when you
  can't. `attendees` (calendar emails, when present) tell you who could have spoken.
- Text is automatic speech recognition: expect misheard names and jargon. Prefer the
  spelling in the title, attendees, or the user's own notes.
- Transcripts run 10K–150K characters. For several meetings, hand each one to a
  subagent that returns its draft, rather than loading every transcript into one context.
- The app's own summary (`S`) and enhanced notes (`E`) are model output; use them as a
  cross-check, not as the source.

## Draft meeting notes

Default shape, in markdown — adjust to what the user asks for:

```markdown
# <Title> — <YYYY-MM-DD>
**Attendees:** <from attendees, or "not recorded">

## Summary
2–4 sentences: what the meeting was for and where it landed.

## Decisions
- <decision> — <who, if known>

## Action items
- [ ] <owner or "unassigned">: <task> (<due date if stated>)

## Discussion
- <topic>: <the substance, with numbers and names as spoken>

## Open questions
- <unresolved item>
```

Put only what the transcript supports. Mark inferences ("likely", "unclear who").
When the user already has notes (`N`), build on them rather than contradicting them.
Show the draft to the user, or save it to a file they name; writing it into the app is
a separate step they ask for.

## Write notes back into the app (only when asked)

This updates the meeting's **notes pane** (`notes_table.content`). It never touches the
transcript or the app's enhanced notes, and it never creates a row.

What is known: a write shows up in the running app after navigating back to that
meeting. What is **not** known: whether the app overwrites the write from memory when
the same note is open or being edited, and whether writing during an active recording
is safe. So the tool refuses unless the notes are unchanged since you read them, and,
while the app runs, unless you pass `--allow-app-running`; and always unless the
database has been quiet for 60 seconds (the app's helper process can outlive the app).

1. Read the current notes and keep `content_sha256`:

   Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.

   ```bash
   SKILL_DIR="${CLAUDE_SKILL_DIR}"
   python3 "$SKILL_DIR/scripts/foresight.py" notes <ref> --json
   ```

2. Save the draft to a file. If the user has notes there, use `--append` unless they
   asked you to replace them.
3. Ask the user to confirm the meeting is not open in Foresight and nothing is
   recording. That confirmation is what `--allow-app-running` asserts.
4. Dry run, then write:

   Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.

   ```bash
   SKILL_DIR="${CLAUDE_SKILL_DIR}"
   python3 "$SKILL_DIR/scripts/foresight.py" write-notes <ref> --file draft.md --expect-sha256 <sha> --append --allow-app-running --dry-run
   python3 "$SKILL_DIR/scripts/foresight.py" write-notes <ref> --file draft.md --expect-sha256 <sha> --append --allow-app-running
   ```

5. The write reads itself back before reporting success. Ask the user to open the
   meeting in the app, then run `notes <ref> --json` again: if `content_sha256` no
   longer matches the write's `new_sha256`, the app replaced it — tell the user.

Refusals (exit 5) say which guard fired and what to do; follow that rather than adding
override flags. `--ignore-recent-activity` is for a user who has confirmed the app is
idle; never pass it on your own.

### Undo

Before every write the note's prior row goes to an undo journal
(`~/.local/state/google-foresight/undo.jsonl`, last 50 writes, mode 600). It holds note
text, so it is as private as the app's own data.

Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"
python3 "$SKILL_DIR/scripts/foresight.py" history <ref>
python3 "$SKILL_DIR/scripts/foresight.py" restore <ref> --undo-id <id> --expect-sha256 <current sha> --allow-app-running
```

`restore` goes through the same guards and journals the version it replaces, so a
restore can itself be undone. Without `--undo-id` it takes the newest entry for that
note — after a restore, that newest entry is the version the restore just replaced, so
pass `--undo-id` when stepping back more than once. It restores `content`, `timestamp`,
and `last_manual_edit`; enhanced notes stay as the app has them.

`--full-backup` additionally copies the whole database (tens of MB) under the state dir
before writing. Use it only when the user asks.
