---
name: macwhisper-cli
description: "Transcribe local audio/video files (.m4a/.wav/.mp3/.mp4) to text on macOS via the MacWhisper `mw` CLI — meetings, recordings, dictation. Any file-on-disk transcription, even unnamed; URL-based requests (YouTube etc.) route through the yt-dlp skill first."
when_to_use: |
  Triggers on "transcribe this file", "transcribe this recording", "macwhisper",
  "mw transcribe", "transcribe meeting", "dictation transcript", "audio to text"
  for a local file, "video to text" for a local file, or any request to convert
  a recording already on disk (`.m4a`/`.wav`/`.mp3`/`.mp4`) into text on macOS.
  URL-based requests belong to the yt-dlp skill.
  Also when the user names whisper-cpp, WhisperKit, Parakeet, or Apple speech models.
allowed-tools: "Bash(mw *) Bash(tee *) Bash(pbcopy) Bash(jq *)"
---

# MacWhisper CLI

Control MacWhisper from the terminal. The `mw` binary connects to the running MacWhisper.app over a local socket and transcribes audio or video files using whichever model is active. It auto-launches MacWhisper if it's not already running (5-second timeout).

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

**Long recordings (a big file, or hour-plus audio) take minutes — run them in the background and let the completion notification wake you.** Transcription is harness-tracked work: start it backgrounded (redirecting to the `/tmp` file as above), then wait for the completion event rather than blocking the session or foreground-`sleep`-polling for the output file. Cold-loading a large model adds to the wall time, so the first progress you see on stderr is model load, not a stall.

`--format` picks the shape of that output. Which formats you can use depends on the license:

| `--format` | What you get | Needs Pro |
|---|---|---|
| `txt` | plain text (default) | — |
| `srt` | SubRip subtitles, numbered timed cues | — |
| `vtt` | WebVTT subtitles | — |
| `csv` | semicolon-delimited `start;end;transcript` (plus speaker when detected) | — |
| `json` | millisecond timestamps, per-segment speaker, word-level timings | Pro |
| `md` | markdown, timestamped segment blocks with speaker headings | Pro |
| `html` | standalone HTML document (same as the app's HTML export) | Pro |
| `avid` | Avid subtitle text with SMPTE timecodes (see `--fps`) | Pro |

Redirecting is still the rule — name the file for the format (`> /tmp/mw-meeting.srt`). `-o <path>` / `--output-dir <dir>` are the CLI's own way to write files, and **neither overwrites an existing file unless you add `--overwrite`.**

## Common workflows

Examples below follow the write-to-file pattern. Deviate when the situation calls for it.

### Basic transcribe

```bash
mw transcribe ~/Desktop/meeting.m4a > /tmp/mw-meeting.txt
```

Transcript → stdout (captured in the file); progress → stderr stays on screen. Add `2>/dev/null` to silence progress too.

### Speaker-labeled transcript (meetings, interviews, anything multi-voice)

```bash
mw transcribe ~/Desktop/interview.m4a --speakers > /tmp/mw-interview.txt
```

The transcript comes back grouped by speaker — one labeled paragraph per speaker turn (`Speaker 1`, `Speaker 2`, …). Reach for this by default on interviews, calls, and meetings: "who said what" is usually the thing the user actually wants.

Variations:

```bash
# Grouped paragraphs, no name labels
mw transcribe interview.m4a --speakers --no-speaker-names > /tmp/mw-interview.txt

# One labeled, timestamped segment per line
mw transcribe interview.m4a --speakers --style segments > /tmp/mw-interview.txt

# Subtitles with "Speaker 1:" prefixed cues
mw transcribe interview.m4a --speakers --format srt > /tmp/mw-interview.srt
```

- **Detection needs a model that supports it.** An explicit `--speakers` on a model that can't detect speakers fails with a clear error rather than quietly returning an unattributed transcript — so a failure here is a model problem, not a flag problem. For switching models, see [references/choosing-a-model.md](references/choosing-a-model.md).
- **Two different switches.** `--speakers` / `--no-speakers` control whether detection *runs*; `--speaker-names` / `--no-speaker-names` control whether the labels are *shown*. Names turn on automatically whenever speakers were detected, so most of the time `--speakers` is all you need.
- **`--no-speakers` is the faster path.** It skips loading the speaker-detection model entirely — use it when the user just wants the text.

### Structured JSON (the agent-friendly transcript)

```bash
mw transcribe ~/Desktop/interview.m4a --format json > /tmp/mw-interview.json
```

This is MacWhisper's recommended path for an AI coding agent: every segment carries millisecond `start`/`end` times, its `text`, the `speaker` (when detected), and per-word timings when the engine produced them. Use it whenever the task needs more than flat prose — quoting with timecodes, per-speaker analysis, clipping audio around a phrase, or building a subtitle/chapter list yourself.

Then extract just the fields you need instead of Reading the whole blob:

```bash
jq -r '.segments[] | "\(.start)\t\(.speaker // "")\t\(.text)"' /tmp/mw-interview.json
```

Add `--speakers` to get the `speaker` field populated. **`json` requires MacWhisper Pro** — if it errors on a license, fall back to `csv` (start, end, transcript, plus speaker when detected), which is free.

### Pipe to the clipboard (if user explicitly wants the text on the clipboard)

```bash
mw transcribe ~/Desktop/voicenote.m4a | pbcopy
```

Clipboard is the explicit destination — no /tmp file. Skip the redirect.

### Batch a folder into a folder of transcripts (default batch approach)

```bash
mw transcribe ~/Recordings --output-dir /tmp/mw-recordings
```

`--output-dir` is the native batch mode and the right default: one transcript per input, named after the input with the format's extension. Folder structure is mirrored, so same-named recordings in different subfolders don't collide. Add `--recursive` to include subfolders, and `--format` to change the shape of every file:

```bash
# Include subfolders
mw transcribe ~/Recordings --recursive --output-dir /tmp/mw-recordings

# A folder of .srt files from a folder of videos
mw transcribe ~/Videos --output-dir /tmp/mw-subs --format srt
```

Failed files are reported and skipped — the run continues, prints a summary at the end (`Transcribed 4 of 5 files, 1 failed: broken.m4a`), and **exits non-zero if anything failed**. Read that summary before reporting a batch as done. Existing files are never overwritten unless you pass `--overwrite`, so a re-run over a populated output dir needs that flag.

You can also collect a mixed set of files and folders into one transcript:

```bash
mw transcribe intro.m4a ~/Recordings/interviews outro.mp3 > /tmp/mw-all.txt
```

### Save transcript alongside each source file

```bash
for f in ~/Recordings/*.m4a; do
  mw transcribe "$f" > "${f%.m4a}.txt"
done
```

Use the loop only for this case — writing next to the source, which `--output-dir` can't do. When the destination is a separate folder, prefer `--output-dir` above; it gets you the failure summary and non-zero exit that a hand-rolled loop silently drops.

The `mw` CLI dispatches to a single MacWhisper.app instance, so parallel backgrounded runs may queue or contend. Start serial; if throughput matters on a bulk job, test serial vs. parallel on a small sample before committing.

### Stream partial segments as they finalize

```bash
mw transcribe --stream lecture.m4a | tee /tmp/mw-lecture.txt
```

`tee` both streams to the terminal and captures to the file.

Use `--stream` when:
- You want to see progress in real time (long recordings, exploratory runs).
- You're piping into something that benefits from incremental input (live display, line-oriented processing).

Per MacWhisper's CLI docs, `--stream` works on local engines (WhisperKit, ParakeetKit, Apple speech) and has no effect on cloud engines (OpenAI, Groq, Deepgram, ElevenLabs, MacWhisper AI — they return one final result regardless). If streaming matters, make sure the active model uses a local engine.

### One-off model override

```bash
mw transcribe --model whisperkit:openai_whisper-small quick-note.m4a > /tmp/mw-quick-note.txt
```

Use this when the default model is wrong for this specific file (e.g., default is English-only but this clip is multilingual). Doesn't change the persistent default.

`--language <iso|auto|multilingual>` pins the source language for one run (`--language nl`, `--language auto`, `--language multilingual` for models that switch mid-audio). It's validated against the resolved model and fails loudly rather than being silently ignored — so on a single-language model (Apple's on-device models, for instance) the fix is a different `--model`, not a different `--language`.

### Save the transcript into MacWhisper's history

```bash
mw transcribe --persist ~/Recordings/meeting.m4a > /tmp/mw-meeting.txt
```

`--persist` saves the transcription into MacWhisper's history (same as a regular in-app transcription) *and* the redirect keeps a copy at `/tmp/mw-meeting.txt` so the agent can Read it for follow-up questions. Without `--persist`, the run is transient — the text prints and is gone.

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
- **Long pause on first command, then it works** — `mw` auto-launched MacWhisper.app and waited for the socket. Subsequent commands should be fast. If the CLI hangs or can't reach the app, quit and relaunch MacWhisper, then try `mw version`.
- **"Sandboxed process" connection error** — `mw` was invoked by a sandboxed program, and the sandbox blocked access to MacWhisper's local socket. Claude Code runs Bash sandboxed, so this is a live failure mode here, not a hypothetical. The error text names the restriction. Fix: run the command outside the sandbox, or have the user run it directly in Terminal — retrying the same command inside the sandbox won't help.
- **A format fails with a Pro error** — `json`, `md`, `html`, and `avid` need a MacWhisper Pro license; `txt`, `srt`, `vtt`, and `csv` are available to everyone. For structured output without Pro, `csv` carries start, end, transcript, and speaker (when detected).
- **`--speakers` fails instead of labeling speakers** — The active model doesn't support speaker detection; `mw` errors rather than returning an unattributed transcript. Switch models (`mw models list`, then `mw models select <id>` or `--model` per call; [references/choosing-a-model.md](references/choosing-a-model.md) covers picking one) or drop to `--no-speakers` if plain text is enough.
- **"Unknown model" or the wrong language in output** — Run `mw models list` to see installed models and which one is active (`▸`). Change with `mw models select <engine>:<model-id>` or override per call with `--model`.
- **Transcript missing from MacWhisper app history** — The run didn't include `--persist`. Transcripts are transient by default.
- **`--stream` produced one big blob instead of segments** — The active engine is a cloud engine (OpenAI, Groq, Deepgram, ElevenLabs, or MacWhisper AI) — those return one final result regardless of `--stream`. Per the CLI docs, engines that actually stream are the local ones: WhisperKit, ParakeetKit, Apple speech. Switch to one of those via `mw models select` (or `--model` per call) and retry.
- **File-not-found errors on relative paths** — `mw` runs under MacWhisper.app, but paths resolve relative to the shell's cwd. Pass absolute paths if you're unsure, or `cd` to the file's directory first.
- **Apple speech models not listed** — They require macOS 26+. On older macOS, they won't appear in `mw models list`.
