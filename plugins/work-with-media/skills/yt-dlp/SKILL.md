---
name: yt-dlp
description: Extracts text, captions, descriptions, chapters, and audio from YouTube, Vimeo, and any yt-dlp-supported URL on macOS or Linux. Leads with a subs-first strategy (description + chapters + auto-captions in one yt-dlp call, no audio download), and falls back to audio download + the macwhisper-cli skill only when captions are missing or insufficient.
when_to_use: |
  Use for any URL-based text/transcript request — "transcribe this video",
  "transcribe this YouTube link", "TLDR of this video",
  "summarize this YouTube link", "teach me about this video",
  "what did [speaker] say in this video", "YouTube transcript",
  "captions of this video", "get the transcript of this link", or any
  request to extract text/info from a video URL.
allowed-tools: Bash(yt-dlp *) Bash(ffmpeg *) Bash(curl *) Bash(mw *) Bash(cat *) Bash(rm /tmp/*)
---

# yt-dlp

Extract text and audio from YouTube, Vimeo, and hundreds of other sites yt-dlp supports. The core move: **prefer captions and descriptions over audio transcription** — most "TLDR this video" requests don't need the audio at all.

## Prerequisites

```!
(command -v yt-dlp >/dev/null 2>&1 && yt-dlp --version 2>&1 | awk '{print "yt-dlp: " $0}') || echo "yt-dlp: NOT INSTALLED — see references/setup.md"
(command -v ffmpeg >/dev/null 2>&1 && ffmpeg -version 2>&1 | head -1 | awk '{print "ffmpeg: " $0}') || echo "ffmpeg: NOT INSTALLED — needed only for audio-transcription fallback; see references/setup.md"
```

If either tool is missing, read [references/setup.md](references/setup.md) for install options. `yt-dlp` is required for every workflow below; `ffmpeg` is needed only when falling back to audio transcription.

## Start cheap: captions + description in one call

For almost every "what does this video say / teach me about / TLDR" request, one yt-dlp invocation is enough. It pulls the creator's description, chapter markers, and auto-generated captions *without downloading the audio*:

```bash
yt-dlp --skip-download \
  --write-description --write-info-json \
  --write-auto-sub --sub-lang en --sub-format vtt \
  -o "/tmp/ytmeta-%(id)s" "<url>"
```

That writes (see [`../../shared/output-conventions.md`](../../shared/output-conventions.md) for the full `/tmp` naming table):

- `/tmp/ytmeta-<id>.description` — video description
- `/tmp/ytmeta-<id>.info.json` — title, chapters, duration, uploader, thumbnails
- `/tmp/ytmeta-<id>.en.vtt` — auto-captions (when available)

**URL-quoting gotcha:** use plain double quotes, no backslash escaping of `?` or `=` inside `"..."`. Zsh does not strip backslashes inside double quotes, so a URL like `"https://...watch\?v\=abc"` passes through with literal backslashes; yt-dlp falls back to its generic extractor, typically lands on YouTube's homepage, and downloads zero items.

**Non-English videos:** `--sub-lang en` only fetches English captions. For other languages, replace `en` with the appropriate ISO code (e.g. `es`, `de`, `ja`, `pt-BR`). If you're not sure what's available, list the options first:

```bash
yt-dlp --list-subs "<url>"
```

That prints two tables — "Available automatic captions" (auto-generated) and "Available subtitles" (creator-provided) — with language codes. Re-run the subs+description command above with the right `--sub-lang` code, or use `--sub-lang <code>,en` to try the native language with English as a fallback.

## Escalate only as needed

Stop at whichever step is sufficient:

1. **Description alone.** Read `/tmp/ytmeta-<id>.description`. Creators often write summaries + timestamps in the description — for tech tutorials, product reviews, and long-form talks, this alone can carry a TLDR.
2. **Info JSON for chapters.** Read `/tmp/ytmeta-<id>.info.json` — it has `title`, `chapters` (array of `{start_time, title}`), `duration`, and `uploader`. Chapters + title give you structure.
3. **Caption file.** Read `/tmp/ytmeta-<id>.en.vtt` when description/chapters aren't enough. Auto-subs are rough (no punctuation, occasional mishears) but fine for "what did they say about X" Q&A.
4. **Audio transcription fallback.** Only when captions are unavailable, visibly low-quality (heavy accents, music, specialized jargon garbled), or the user explicitly asks for a high-accuracy transcript. See the next section.

## Audio transcription fallback

Download the audio, then hand off to the [macwhisper-cli skill](../macwhisper-cli/SKILL.md):

```bash
yt-dlp -x --audio-format m4a -o "/tmp/yt-%(id)s.%(ext)s" "<url>"
```

yt-dlp pulls the best audio stream and uses ffmpeg internally (via `-x`) to produce `/tmp/yt-<id>.m4a`. From there, `mw transcribe /tmp/yt-<id>.m4a > /tmp/mw-yt-<id>.txt` — follow the [output conventions](../../shared/output-conventions.md).

## Direct audio/video URL (not a video-sharing site)

For direct URLs, pick a short `<slug>` (e.g., the URL's basename without extension, or `$(date +%s)` as a fallback) so multiple direct-URL downloads in one session don't clobber each other. See [`../../shared/output-conventions.md`](../../shared/output-conventions.md) for the naming table.

For a direct `.m4a`/`.wav` URL, yt-dlp isn't needed — `curl` is enough:

```bash
curl -sL "<url>" -o /tmp/dl-<slug>.m4a \
  && mw transcribe /tmp/dl-<slug>.m4a > /tmp/mw-dl-<slug>.txt
```

For a format MacWhisper doesn't accept (`.webm`, `.mkv`, raw video), download and let ffmpeg convert:

```bash
curl -sL "<url>" -o /tmp/dl-<slug>.webm \
  && ffmpeg -i /tmp/dl-<slug>.webm -vn -c:a aac /tmp/dl-<slug>.m4a \
  && mw transcribe /tmp/dl-<slug>.m4a > /tmp/mw-dl-<slug>.txt
```

## Handling composed requests

*"Teach me about this video — I want the TLDR, then I want to ask questions."* This is the canonical composed flow and it's a single pipeline:

1. Run the subs+description pull (subs-first route above).
2. Read description and/or captions to produce the TLDR.
3. Leave `/tmp/ytmeta-<id>.*` in place. Follow-up Q&A reads the same files without re-fetching.

See [`../../shared/output-conventions.md`](../../shared/output-conventions.md) for the Read-on-demand / path-back defaults.

## Important guidelines

1. **Subs-first, transcription as fallback.** Audio transcription is the expensive option; most URL requests never need it. See [`../../shared/routing.md`](../../shared/routing.md) for the full decision matrix.

2. **Use `%(id)s` in `-o` templates.** `/tmp/ytmeta-%(id)s` keeps multiple videos from clobbering each other and makes cleanup scriptable (`rm /tmp/ytmeta-abc123.*`).

3. **Quote URLs plainly.** Double quotes, no backslashes inside them. (See the gotcha under *Start cheap* above.)

4. **Check `yt-dlp --help`** for anything unusual — the surface is huge. Common power-tools: `--dateafter`, `--match-filter`, `--playlist-items`, `--cookies-from-browser`.

## Cleanup

```bash
rm /tmp/ytmeta-<id>.* /tmp/yt-<id>.m4a /tmp/mw-yt-<id>.txt
```

Or for everything this skill has produced in a session:

```bash
rm /tmp/ytmeta-* /tmp/yt-*.m4a /tmp/dl-* /tmp/mw-dl-*.txt
```

Explicit cleanup is optional (macOS cleans `/tmp` periodically), but worth running for sensitive content.

## Troubleshooting

- **"NOT INSTALLED" on yt-dlp or ffmpeg** — See [references/setup.md](references/setup.md).
- **yt-dlp downloads the wrong thing (homepage, playlists, zero items)** — URL-quoting gotcha: check the URL hasn't been passed with literal backslash-escaped `?` or `=` inside double quotes.
- **Captions are empty or missing** — Either the video has no auto-subs (creator disabled them) or they exist in a language other than English. Run `yt-dlp --list-subs "<url>"` to see what's available; if nothing shows up, fall back to audio transcription.
- **`yt-dlp -x` errors about ffmpeg** — ffmpeg isn't on PATH. Install it (see [references/setup.md](references/setup.md)) before retrying.
- **Very long download on a short video** — yt-dlp may be choosing a high-bitrate format. For audio-only transcription, `-x --audio-format m4a` keeps it small. For subs-only runs, `--skip-download` avoids audio entirely.
