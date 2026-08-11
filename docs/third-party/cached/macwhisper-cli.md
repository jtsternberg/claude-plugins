---
source: https://docs.macwhisper.com/article/57-macwhisper-command-line-tool
cached_from: research-tools:fetch-docs --md
last_updated: 2026-08-10
related:
  - work-with-media:macwhisper-cli
---

  MacWhisper Command-Line Tool

# MacWhisper Command-Line Tool

Good Snooze

* * *

To celebrate the launch of the MacWhisper CLI you can upgrade to MacWhisper Pro with a 10% discount using [this link](https://goodsnooze.gumroad.com/l/macwhisper/clicli).

## Using the MacWhisper Command-Line Tool

MacWhisper ships with a command-line tool called `mw` that lets you drive the app from the terminal — transcribe files (with speaker detection, subtitles, structured JSON and more), list and switch models, pipe results into other programs, and automate transcription from scripts.

The CLI talks to the running MacWhisper app over a local socket, so it uses the exact same engines, models, and settings you've configured in the UI. If MacWhisper isn't running when you invoke `mw`, the CLI will launch it for you automatically.

## 1\. Installing the CLI

1.  Open **MacWhisper → Settings → Advanced**.
2.  Under **Command-Line Tool**, click **Install**.
3.  MacWhisper will place the `mw` binary at `/usr/local/bin/mw`. macOS may ask for your password the first time — this is required to write into `/usr/local/bin`.
4.  When the install is complete, the pane shows a green checkmark: "installed at /usr/local/bin/mw".

To remove it later, return to the same pane and click **Uninstall**.

### Verify the install

Open a new Terminal window and run:

$ mw version
MacWhisper 14.4.1 (1467)

If you see a version number, you're ready to go. If your shell can't find `mw`, make sure `/usr/local/bin` is on your `PATH` (it is by default on macOS).

## 2\. Quick start

Run `mw` on its own for a set of example commands to get you started.

Transcribing a file is one line:

$ mw transcribe ~/Desktop/meeting.m4a
Hello everyone, welcome to the meeting...

When stderr is a terminal, `mw transcribe` renders a live `Transcribing: 47%` progress line on stderr. The actual transcript goes to stdout, so redirection stays clean:

\# Transcript.txt contains ONLY the transcript
mw transcribe foo.m4a > transcript.txt

# Grep sees only transcript lines
mw transcribe foo.m4a | grep "hello"

# Suppress progress when scripting
mw transcribe foo.m4a 2>/dev/null

# Capture both, if you want progress too
mw transcribe foo.m4a > out.txt 2>&1

You can interrupt a transcription at any time with Ctrl+C.

## 3\. Commands at a glance

Command

What it does

`mw`

Status overview: app connectivity, selected model, downloaded models, example commands

`mw version`

Prints the MacWhisper version. Handy as a connectivity check.

`mw models list`

Lists your installed transcription models.

`mw models select <id>`

Changes the active model used by MacWhisper.

`mw transcribe <files>`

Transcribes audio/video files or whole folders and prints the text.

Add `--help` to any subcommand for detailed options (`mw transcribe --help`).

The `mw transcribe` flags, grouped by what they control:

Flag

What it does

`--speakers` / `--no-speakers`

Turn speaker detection on or off for this run; `--speakers` outputs the transcript grouped by speaker

`--format <fmt>`

Output format: `txt` (default), `srt`, `vtt`, `json`, `csv`, `md`, `html`, `avid`

`--style <style>`

Layout style: `transcript`, `subtitles`, or `segments` — the same styles as the app's Export panel

`--model <id>`

Use a specific model for this run without changing the app's selection

`--language <code>`

Source language for this run: an ISO code (`en`, `de`, `nl`, …), `auto`, or `multilingual`

`--output <path>` / `-o`

Write the transcript to a file instead of stdout

`--output-dir <dir>`

Batch mode: write one transcript file per input into a folder

`--recursive`

When a folder is given, include its subfolders too

`--overwrite`

Allow `--output` / `--output-dir` to replace existing files

`--stream`

Print segments live as they finalize instead of waiting for the whole file

`--persist`

Keep the transcription in MacWhisper's history

`--timestamps`, `--end-timestamps`, `--milliseconds`, `--speaker-names`, `--group`, `--max-chars-per-line`, `--fps`

Fine-tuning levers for the output layout — see section 7

## 4\. Working with models

### List installed models

$ mw models list
  ID                                        NAME                      SIZE
  whisper-cpp:ggml-tiny.en                  Tiny (English Only)       80 MB
  whisperkit:openai\_whisper-small           Small                     483 MB
▸ parakeet-pro:nvidia\_parakeet-v3\_494MB     Parakeet v3 (494MB)       494 MB
  apple:en-GB                               English (United Kingdom)  -

*   The `▸` marker shows the currently selected model.
*   The ID column (e.g. `whisperkit:openai_whisper-small`) is what you pass to `--model` or `mw models select`.
*   `apple:<locale>` entries are Apple's on-device speech models provided by macOS 26+. Their size shows `-` because the OS manages storage for them.

### Switch the active model

$ mw models select parakeet-pro:nvidia\_parakeet-v3\_494MB
Selected: parakeet-pro:nvidia\_parakeet-v3\_494MB (Parakeet v3)

The change applies immediately to both the CLI and the MacWhisper UI. If the model isn't installed, the command fails with a clear error — download it from the MacWhisper UI first.

## 5\. Transcribing files

The simplest case — print a transcript to stdout:

$ mw transcribe ~/Desktop/meeting.m4a
Hello everyone, welcome to the meeting...

By default, transcriptions are **transient** — they are returned to the terminal and then discarded. They do not show up in your MacWhisper history unless you pass `--persist`.

### Useful flags

\# One-off model override
$ mw transcribe meeting.m4a --model whisperkit:openai\_whisper-small

# Force Dutch source language
$ mw transcribe meeting.m4a --language nl

# Force language auto-detection
$ mw transcribe meeting.m4a --language auto

# Keep it in MacWhisper's history
$ mw transcribe meeting.m4a --persist

# Print segments as they finalize
$ mw transcribe meeting.m4a --stream

# Write to a file instead of stdout
$ mw transcribe meeting.m4a -o transcript.txt

# Replace an existing file
$ mw transcribe meeting.m4a -o transcript.txt --overwrite

*   **`--language` is validated against the model.** Passing a language the resolved model can't transcribe fails with a clear error instead of being silently ignored — Apple's on-device models are single-language, for example. `multilingual` lets models that support it switch languages mid-audio.
*   **`--stream`** works with local engines (WhisperKit, ParakeetKit, Apple speech), which produce segments incrementally. Cloud engines (OpenAI, Groq, Deepgram, ElevenLabs, etc) only return one final result, so `--stream` has no effect for them. Streaming outputs plain text only, and can be combined with `-o` to append segments to a file live.
*   **`--output` is safe by default.** An existing file is never overwritten unless you also pass `--overwrite`.

## 6\. Speaker detection

Pass `--speakers` and the transcript comes back grouped by speaker — one labeled paragraph per speaker turn:

$ mw transcribe interview.m4a --speakers
Speaker 1
So tell me how you got started with the project.

Speaker 2
It actually began as a weekend experiment. I never expected it to grow the way it did.

Speaker 1
And when did you realize it was becoming something bigger?

Variations:

\# Grouped paragraphs, no name labels
$ mw transcribe interview.m4a --speakers --no-speaker-names

# One labeled, timestamped segment per line
$ mw transcribe interview.m4a --speakers --style segments

# Subtitles with "Speaker 1:" prefixed cues
$ mw transcribe interview.m4a --speakers --format srt

# JSON with a speaker field per segment
$ mw transcribe interview.m4a --speakers --format json

# Skip speaker detection (faster)
$ mw transcribe interview.m4a --no-speakers

*   Speaker detection requires a model that supports it. An explicit `--speakers` on a model that can't detect speakers fails with a clear error rather than silently producing an unattributed transcript.
*   `--speaker-names` / `--no-speaker-names` control whether names are _shown_ in the output; `--speakers` / `--no-speakers` control whether detection _runs_. Names turn on automatically whenever the transcript has speakers, so most of the time you only ever need `--speakers`.
*   `--no-speakers` also skips loading the speaker-detection model, so it's the faster option when you just want text.

## 7\. Output formats & layout

Choose the output shape with `--format`:

Format

Description

Requires Pro

`txt`

Plain text (default)

—

`srt`

SubRip subtitles with numbered, timed cues

—

`vtt`

WebVTT subtitles

—

`csv`

Semicolon-delimited rows: start, end, transcript (plus speaker when detected)

—

`json`

Structured JSON with millisecond timestamps, per-segment speakers, and word-level timings

Pro

`md`

Markdown, timestamped segment blocks with speaker headings

Pro

`html`

A full standalone HTML document (same as the app's HTML export)

Pro

`avid`

Avid-style subtitle text with SMPTE timecodes (see `--fps`)

Pro

$ mw transcribe meeting.m4a --format srt > meeting.srt
$ mw transcribe meeting.m4a --format json | jq '.segments\[0\]'
$ mw transcribe meeting.m4a --format html > meeting.html
$ mw transcribe meeting.m4a --format avid --fps 30 > meeting.txt

The `json` format is made for feeding transcripts into scripts and AI pipelines. Each segment carries millisecond `start`/`end` times, its text, the speaker (when detected), and per-word timings when the engine produced them:

{
  "text": "Hello everyone.\\nWelcome to the meeting.",
  "segments": \[
    {
      "id": "6B29FC40-CA47-1067-B31D-00DD010662DA",
      "start": 0,
      "end": 1600,
      "text": "Hello everyone.",
      "speaker": "Speaker 1",
      "words": \[
        { "text": "Hello", "start": 0, "end": 640 },
        { "text": "everyone.", "start": 660, "end": 1600 }
      \]
    }
  \]
}

### Styles and fine-tuning

Every format has a sensible default layout, and `--style` switches between the same layout styles as the app's Export panel: `transcript` (flowing text, optionally grouped), `subtitles` (timed cues), and `segments` (one block per segment). On top of the style, optional levers fine-tune the output:

*   `--timestamps` / `--no-timestamps` — show or hide per-segment timestamps (text formats)
*   `--end-timestamps` — render start–end ranges instead of just the start (text formats)
*   `--milliseconds` — include milliseconds in timestamps (text formats)
*   `--speaker-names` / `--no-speaker-names` — show or hide speaker labels (auto: on when speakers were detected)
*   `--group <none|words|sentences|people>` — how the `transcript` style groups text into paragraphs
*   `--max-chars-per-line <n>` — wrap long lines/cues at `n` characters
*   `--fps <n>` — frames per second for Avid timecodes

\# Timestamped segment blocks
$ mw transcribe meeting.m4a --format txt --style segments

# One sentence per paragraph
$ mw transcribe meeting.m4a --style transcript --group sentences

# Per-speaker paragraphs
$ mw transcribe meeting.m4a --style transcript --group people
$ mw transcribe meeting.m4a --format md --speaker-names --milliseconds

# Wrap long cues
$ mw transcribe meeting.m4a --format vtt --max-chars-per-line 42

Not every style fits every format (subtitle formats are always the `subtitles` style, for example). If a combination isn't valid, the error lists exactly which styles the format supports.

## 8\. Batch transcription

Pass multiple files, or whole folders, and every file is transcribed in turn:

$ mw transcribe monday.m4a tuesday.m4a wednesday.m4a

# Every supported file in the folder
$ mw transcribe ~/Recordings

# ...including subfolders
$ mw transcribe ~/Recordings --recursive

# Mix files and folders, collecting everything into one file
$ mw transcribe intro.m4a interviews/ outro.mp3 > all.txt

With `--output-dir`, each input gets its own transcript file, named after the input with the format's extension. Folder structure is mirrored, so recordings with the same name in different subfolders don't collide:

$ mw transcribe ~/Recordings --recursive --output-dir ~/Transcripts
==> monday.m4a <==
Transcribing monday.m4a...
Wrote /Users/you/Transcripts/monday.txt
...
Transcribed 4 files.

# A folder of .srt files
$ mw transcribe ~/Videos --output-dir ~/Subs --format srt

Failed files are reported and skipped — the run continues, a summary is printed at the end (e.g. `Transcribed 4 of 5 files, 1 failed: broken.m4a`), and the exit code is non-zero if anything failed. Existing files are never overwritten unless you pass `--overwrite`.

## 9\. Cool things to do with it

### Transcribe and copy to clipboard

mw transcribe meeting.m4a | pbcopy

### Turn a folder of recordings into a folder of transcripts

mw transcribe ~/Recordings --output-dir ~/Transcripts

### Subtitle every video in a folder

mw transcribe ~/Videos --output-dir ~/Subs --format srt

### Word count of a call

mw transcribe call.m4a | wc -w

### Find every mention of a name across a folder of recordings

for f in \*.m4a; do
    echo "=== $f ==="
    mw transcribe "$f" 2>/dev/null | grep -i "acme corp"
done

### Get a speaker-labeled interview transcript

mw transcribe interview.m4a --speakers -o interview.txt

### Extract timestamped lines from the structured JSON

mw transcribe interview.m4a --format json | jq -r '.segments\[\] | "\\(.start)\\t\\(.speaker // "")\\t\\(.text)"'

### Transcribe and summarise with a local LLM

mw transcribe standup.m4a --speakers | ollama run llama3 "Summarise the key points per speaker:"

### Live-pipe a long file into a note

Using `--stream`, you'll see transcript lines appear in the target file as they're produced:

mw transcribe --stream lecture.m4a | tee lecture.txt

### Save a proper entry into MacWhisper history from a script

mw transcribe --persist ~/Recordings/meeting.m4a > /dev/null

The transcription appears in the MacWhisper window like a normal import.

### Use it from an AI coding agent

The CLI is a natural fit for AI coding agents (Claude Code, Cursor, and friends): the agent can call `mw transcribe --format json` and get structured, word-timed transcripts to work with. Point your agent at `mw help transcribe` and it can figure out the rest.

## 10\. Troubleshooting

*   **`mw: command not found`** — the `/usr/local/bin` directory isn't on your `PATH`. Open a new Terminal window, or add `export PATH="/usr/local/bin:$PATH"` to your shell profile.
*   **"File not found"** — `mw transcribe` resolves `~` and relative paths against your current directory. Double-check the path, or drag the file into Terminal to paste its absolute path.
*   **CLI hangs or can't reach the app** — quit and relaunch MacWhisper, then try `mw version`. The CLI auto-launches MacWhisper if it's not running (5-second timeout).
*   **"Sandboxed process" connection error** — if `mw` is invoked by a sandboxed program (some AI coding agents run commands in a sandbox), the sandbox may block access to MacWhisper's socket. The error names the restriction; allow the command outside the sandbox, or run `mw` directly in Terminal.
*   **A model ID isn't recognised** — run `mw models list` to see the exact IDs you can use, and make sure the model has been downloaded from MacWhisper's UI first.
*   **A format fails with a Pro error** — `json`, `md`, `html` and `avid` exports require a MacWhisper Pro license; `txt`, `srt`, `vtt` and `csv` are available to everyone.
*   **Progress line clutters a log file** — add `2>/dev/null` to suppress it, or `2>&1` to capture it alongside stdout.

## 11\. Uninstalling

Open **MacWhisper → Settings → Advanced → Command-Line Tool** and click **Uninstall**. MacWhisper will remove the binary from `/usr/local/bin/mw`.