# Output Conventions

Both skills in this plugin produce text that can get long — a 30-minute video is easily 10–20K tokens of transcript or caption text. Dumping that straight into the agent's context wastes space when the user's actual request often needs only a summary or a specific chunk.

## The default: write to `/tmp`, Read on demand

When running a command that produces transcript/caption/description text, redirect its output to a file under `/tmp/` and `Read` the file only if the user's request actually needs the content.

- **"transcribe this / get the transcript"** — run the command, report the file path back. Don't inline the content.
- **"TLDR / summarize / teach me about this / what did [X] say"** — run the command, then `Read` the file to answer. Keep the path in context across follow-up turns so repeat questions Read it again instead of re-running.
- **"extract X / translate / find the part where they discuss Y"** — Read (or Grep) the file and work from disk.
- **Short clip (under ~60s) and the user wants the text inline** — skip the redirect; a direct stdout capture is cheaper than a `Read` round-trip.

## `/tmp` naming conventions

Keep filenames predictable so either skill can find — or clean up — outputs produced by the other.

| Producer | Path | Purpose |
|:---|:---|:---|
| macwhisper-cli | `/tmp/mw-<name>.txt` | Transcript from `mw transcribe` |
| yt-dlp (captions) | `/tmp/ytmeta-<id>.en.vtt` | Auto-generated or creator-provided captions |
| yt-dlp (description) | `/tmp/ytmeta-<id>.description` | Video description text |
| yt-dlp (metadata) | `/tmp/ytmeta-<id>.info.json` | Title, chapters, duration, uploader, etc. |
| yt-dlp (audio) | `/tmp/yt-<id>.m4a` | Downloaded audio for transcription fallback |
| curl direct URL (audio) | `/tmp/dl-<slug>.<ext>` | Direct download of an audio/video URL |
| curl direct URL (transcript) | `/tmp/mw-dl-<slug>.txt` | Transcript of a direct-URL download |

**Picking the slug/id/name values:**

- `<name>` — source filename without extension (e.g., `mw-meeting.txt` for `meeting.m4a`).
- `<id>` — yt-dlp's `%(id)s` placeholder in `-o` templates, so multiple videos don't clobber each other.
- `<slug>` — for direct-URL downloads (not YouTube/Vimeo), derive a short identifier from the URL's basename (e.g., `podcast-ep42` from `https://example.com/media/podcast-ep42.mp3`) or use `$(date +%s)` as a fallback. **This matters:** without a slug, two direct-URL downloads in the same session would silently clobber each other — both the `.<ext>` audio and the `mw-dl-*.txt` transcript.

## Cleanup

`/tmp` is cleaned by macOS periodically, so explicit `rm` isn't required. For sensitive audio (private interviews, confidential meetings), clean up when done:

```bash
rm /tmp/mw-*.txt /tmp/ytmeta-* /tmp/yt-*.m4a /tmp/dl-*
```

## This is a default, not a rule

Use judgment. Short clips + explicit "just give me the text inline" requests are fine without the redirect. The point is to avoid unconsciously spending 15K tokens of context on a transcript the user only wanted summarized.
