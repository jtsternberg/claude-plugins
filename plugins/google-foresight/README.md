# google-foresight

Work with the data of Google AI Edge Foresight, the macOS
app that transcribes meetings on-device and keeps notes beside them. Ask "review the
meeting transcripts from today and draft some meeting notes" and the `foresight` skill
finds the meetings, reads each transcript, and drafts the notes — and, only when asked,
writes them into the app's notes pane.

```bash
claude plugin install google-foresight@jtsternberg
```

Invoke as `/google-foresight:foresight` (Claude Code) or let the description route it.
Requires macOS, the Foresight app, and `python3` (stdlib only).

## The CLI

`skills/foresight/scripts/foresight.py` is a thin wrapper over the app's database at
`~/Library/Application Support/com.google.AIEdgeForesight/database.sqlite`
(override with `--db` or `FORESIGHT_DB`). Every command takes `--json`.

| Command | What it does |
| --- | --- |
| `doctor` | database path, schema check, app running, seconds since last DB write |
| `meetings [--today\|--yesterday\|--date D\|--since D --until D] [--name S] [--transcribed]` | list meetings |
| `show REF` | metadata, attendees, the app's summary, notes, enhanced notes |
| `transcript REF [--with-summary]` | full transcript; consecutive turns by one speaker joined |
| `notes REF [--enhanced]` | the notes pane (or the app's enhanced notes) plus `content_sha256` |
| `search QUERY [window flags]` | substring search over titles, transcripts, summaries, notes |
| `write-notes REF --file F --expect-sha256 S [--append]` | guarded write to the notes pane |
| `history REF` / `restore REF [--undo-id ID] [--force] --expect-sha256 S` | undo journal |

`REF` is an `event_id`, a note id (`note_<event_id>`), or a unique title substring.

Exit codes: 0 ok, 1 runtime error, 2 usage, 3 schema mismatch, 4 meeting not found or
ambiguous, 5 write refused by a guard, 6 write did not verify.

## What is in the database

- `event_transcript_table` — one row per recording: `transcript` is JSON,
  `[{segment_title, duration_seconds, turns: [{speaker, text}]}]`. `speaker` is the
  audio channel: `Microphone` (the user) or `Remote` (everyone else, merged).
  `attendees` is a comma-separated email list when the meeting came from a calendar.
- `notes_table` — `id` is `note_<event_id>`. `content` is the user's markdown notes
  pane, `enhanced_content` the app's generated "Enhanced notes". The notes `title` is
  the name the app shows.
- No audio is kept; transcripts are text only.

The schema is an undocumented app internal. Each run checks the columns it uses and
exits 3 naming what is missing. When `PRAGMA user_version` differs from the tested
value (5, app build 1.0.0.28), reads warn and `write-notes`/`restore` refuse (exit 5)
unless passed `--allow-untested-schema`.

## Writes and their risk

Reads open the database read-only. `write-notes` and `restore` update one row's
`content`, `timestamp`, and `last_manual_edit`, and only after:

1. **Compare-and-swap** — `--expect-sha256` must match the notes as they are now,
   checked again inside the write transaction.
2. **App idle** — with Foresight running, the write needs `--allow-app-running` (the
   caller has confirmed the meeting is not open or recording). Whether or not it runs,
   the database must be untouched for 60 seconds (`FORESIGHT_QUIET_SECONDS`), since
   the app's `ForesightHelper` process outlives the app window.
3. **Undo journal** — the prior row is appended to
   `~/.local/state/google-foresight/undo.jsonl` (`FORESIGHT_STATE_DIR`; the last 50
   writes across all meetings, not per meeting — `FORESIGHT_UNDO_LIMIT` overrides
   the 50 with any positive integer; file 600, directory 700) before the
   commit, and removed again if the write does not commit. Each entry records the
   database file it belongs to; `history`/`restore` ignore other copies. A
   whole-database copy (mode 600) is made only with `--full-backup`.
4. **Read-back** — the write is re-read and compared before it reports success.

If the app holds a write lock, the write refuses with exit 5 and nothing written.
`restore` also refuses unless the notes are exactly what the chosen entry's write left
(edited since, a later write, or a write that never landed); `--force` overrides.

Verified: a write appears in the running app after navigating back to the meeting.
**Untested:** whether the app overwrites a write from memory when that note is open or
being edited, and whether writing during a recording is safe. The guards narrow that
window; they do not close it. After a write, open the meeting in the app and re-check
`notes REF --json` against the write's `new_sha256`.

## Tests

```bash
python3 -m unittest discover -s plugins/google-foresight/skills/foresight/tests
```

The suite builds a fixture database from `tests/fixtures/schema.sql` (the app's DDL,
no data) and fills it with invented meetings. It never opens the real database.
