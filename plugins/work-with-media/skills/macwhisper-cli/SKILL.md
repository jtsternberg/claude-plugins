---
name: macwhisper-cli
description: Transcribes local audio and video files on macOS using the MacWhisper `mw` CLI. Use whenever the user has an audio/video file on disk (or downloaded to /tmp from another skill) that needs to become text — even when they don't explicitly name MacWhisper. Handles whisper-cpp, WhisperKit, Parakeet, and Apple speech models, with streaming, one-off model overrides, and persist-to-history. URL-based requests (YouTube, Vimeo, direct URLs) route through the yt-dlp skill first — subs-first is usually cheaper than audio transcription; this skill takes over when yt-dlp decides transcription is actually needed.
when_to_use: |
  Triggers on "transcribe this file", "transcribe this recording", "macwhisper",
  "mw transcribe", "transcribe meeting", "dictation transcript", "audio to text"
  for a local file, "video to text" for a local file, or any request to convert
  a recording already on disk (`.m4a`/`.wav`/`.mp3`/`.mp4`) into text on macOS.
  URL-based requests belong to the yt-dlp skill.
allowed-tools: Bash(mw *) Bash(tee *) Bash(pbcopy)
---

# MacWhisper CLI

Control MacWhisper from the terminal. The `mw` binary connects to the running MacWhisper.app over a local socket and transcribes audio or video files using whichever model is active. It auto-launches MacWhisper if it's not already running (~5s typical first-run handshake).

> **Platform:** macOS only. Apple speech models additionally require macOS 26+.

## Prerequisites

```!
command -v mw >/dev/null && echo "mw: $(mw version 2>&1)" || echo "mw: NOT INSTALLED — open MacWhisper → Settings → Advanced → Install command-line tool"
```

If that prints a version, you're ready. Otherwise install the CLI from MacWhisper (**Settings → Advanced → Install**) — it drops a binary at `/usr/local/bin/mw`.

**Currently active model:** !`mw models list 2>/dev/null | awk '/▸/ {print $2; found=1} END {if (!found) print "(none active — run mw models select <id>, or see references/choosing-a-model.md)"}'` — this is what `mw transcribe` will use unless you override with `--model`. For help picking or changing models, read [references/choosing-a-model.md](references/choosing-a-model.md).

## Live CLI reference

The `mw` CLI is small; keep these dumps authoritative rather than paraphrasing.

```!
mw --help 2>&1
```

```!
mw help transcribe 2>&1
```

```!
mw help models 2>&1
```

## Output handling

Transcripts can be long — follow the plugin's [shared output conventions](../../shared/output-conventions.md). The short version: redirect `mw transcribe` output to `/tmp/mw-<name>.txt` and `Read` the file on demand based on what the user actually asked for (path-back for "transcribe this", Read-and-answer for "TLDR/Q&A", skip-the-redirect for short inline-text requests).

## Common workflows

Examples below follow the write-to-file pattern. Deviate when the situation calls for it.

### Basic transcribe

```bash
mw transcribe ~/Desktop/meeting.m4a > /tmp/mw-meeting.txt
```

Transcript → stdout (captured in the file); progress → stderr stays on screen. Add `2>/dev/null` to silence progress too.

### Pipe to the clipboard (if user explicitly wants the text on the clipboard)

```bash
mw transcribe ~/Desktop/voicenote.m4a | pbcopy
```

Clipboard is the explicit destination — no /tmp file. Skip the redirect.

### Save transcript alongside each file in a folder

```bash
for f in ~/Recordings/*.m4a; do
  mw transcribe "$f" > "${f%.m4a}.txt"
done
```

Writing alongside the source is the point of this workflow — the user wants `.txt` files next to their `.m4a` files, not temp files. The `mw` CLI dispatches to a single MacWhisper.app instance, so parallel backgrounded runs may queue or contend. Start serial; if throughput matters on a bulk job, test serial vs. parallel on a small sample before committing.

### Stream partial segments as they finalize

```bash
mw transcribe --stream lecture.m4a | tee /tmp/mw-lecture.txt
```

`tee` both streams to the terminal and captures to the file.

Use `--stream` when:
- You want to see progress in real time (long recordings, exploratory runs).
- You're piping into something that benefits from incremental input (live display, line-oriented processing).

Skip `--stream` when the active engine doesn't support it. `mw help transcribe` documents `--stream` as local-engine-only; if you see one big blob instead of incremental segments, the active engine doesn't support streaming — switch to another model via `mw models select` and retry.

### One-off model override

```bash
mw transcribe --model whisperkit:openai_whisper-small quick-note.m4a > /tmp/mw-quick-note.txt
```

Use this when the default model is wrong for this specific file (e.g., default is English-only but this clip is multilingual). Doesn't change the persistent default.

### Save the transcript into MacWhisper's history

```bash
mw transcribe --persist ~/Recordings/meeting.m4a > /tmp/mw-meeting.txt
```

`--persist` puts the transcript in the MacWhisper app (searchable history, annotation, re-export) *and* the redirect keeps a copy at `/tmp/mw-meeting.txt` so the agent can Read it for follow-up questions. Without `--persist`, MacWhisper drops the transcript from its history after the run — the /tmp file is all you have.

Rule of thumb: **one-shot scripts default to transient; "record this meeting" workflows default to `--persist`.**

### Transcribing audio that the yt-dlp skill has already downloaded

When the yt-dlp skill hands off at `/tmp/yt-<id>.m4a`, this is just a basic transcribe with a specific source path:

```bash
mw transcribe /tmp/yt-<id>.m4a > /tmp/mw-yt-<id>.txt
```

Keep the yt-dlp skill's metadata files (`/tmp/ytmeta-<id>.*`) in place — they may supplement the transcript for follow-up questions.

## Important guidelines

1. **For local audio/video, `mw transcribe` is the natural choice on this machine.** The user installed MacWhisper and its CLI specifically, so reaching for it instead of rolling a bespoke `whisper.cpp` / `ffmpeg + whisper` chain keeps models and history in one place.

2. **Quote file paths with spaces.** `mw transcribe "My Voice Memo.m4a"` — paths with spaces, unicode, or shell metacharacters need quoting like any other CLI.

3. **Check `mw help <command>`** for any flag not covered here. The surface is narrow but may grow between MacWhisper releases.

4. **Model questions → [references/choosing-a-model.md](references/choosing-a-model.md).** If the user asks which model to use, wants to switch models, or the current model looks wrong for the file (wrong language, too slow), read that file rather than guessing.

5. **URL inputs → [yt-dlp skill](../yt-dlp/SKILL.md).** `mw transcribe <url>` errors with `File not found`. Before reaching for a download-then-transcribe pipeline, check the [routing guide](../../shared/routing.md) — for YouTube especially, captions + description usually beat audio transcription.

## Troubleshooting

- **"NOT INSTALLED" from the prerequisites block** — Open MacWhisper → Settings → Advanced → **Install** under Command-Line Tool. Binary lands at `/usr/local/bin/mw`.
- **Long pause on first command, then it works** — `mw` auto-launched MacWhisper.app and waited for the socket. Subsequent commands should be fast. If the first-run handshake hasn't completed within ~10s, open MacWhisper manually and retry.
- **"Unknown model" or the wrong language in output** — Run `mw models list` to see installed models and which one is active (`▸`). Change with `mw models select <engine>:<model-id>` or override per call with `--model`.
- **Transcript missing from MacWhisper app history** — The run didn't include `--persist`. Transcripts are transient by default.
- **`--stream` produced one big blob instead of segments** — The active (or `--model`-overridden) engine doesn't support streaming. `mw help transcribe` documents `--stream` as local-engine-only but doesn't enumerate which engines qualify. Switch to a different model via `mw models select` (or `--model` per call) and retry.
- **File-not-found errors on relative paths** — `mw` runs under MacWhisper.app, but paths resolve relative to the shell's cwd. Pass absolute paths if you're unsure, or `cd` to the file's directory first.
- **Apple speech models not listed** — They require macOS 26+. On older macOS, they won't appear in `mw models list`.
