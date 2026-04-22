# Work With Media

Turn audio and video into text on macOS. Two complementary skills:

- **[`macwhisper-cli`](skills/macwhisper-cli/SKILL.md)** — wraps the MacWhisper `mw` CLI for local-file transcription. whisper-cpp, WhisperKit, Parakeet, and Apple's on-device Speech framework — all running locally.
- **[`yt-dlp`](skills/yt-dlp/SKILL.md)** — pulls captions, descriptions, chapters, and audio from YouTube, Vimeo, and hundreds of other sites. Leads with a subs-first strategy (no audio download) so a TLDR doesn't require a full transcription.

The skills compose: for a YouTube URL, the yt-dlp skill usually finishes the job from captions alone; when a video has no captions or the user needs high accuracy, yt-dlp downloads the audio and hands off to macwhisper-cli for transcription.

## Installation

Run these in a terminal (not inside a Claude Code session):

```bash
claude plugin marketplace add jtsternberg/claude-plugins
claude plugin install work-with-media@jtsternberg
```

## Prerequisites

### macwhisper-cli skill

- **[MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper)** (macOS only) — installed with the CLI enabled (Settings → Advanced → **Install** under Command-Line Tool). This drops `/usr/local/bin/mw`.
- At least one transcription model downloaded from MacWhisper's Models tab.

### yt-dlp skill

- `yt-dlp` on PATH. Required for every URL workflow.
- `ffmpeg` on PATH. Required only for the audio-transcription fallback path.

```bash
brew install yt-dlp ffmpeg
```

Non-Homebrew install options: [yt-dlp](https://github.com/yt-dlp/yt-dlp) · [ffmpeg](https://ffmpeg.org/download.html).

## Why MacWhisper?

[MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper) is the speech-to-text tool I reach for on macOS. It's positioned as a file-transcription app, but ships a first-class system-wide dictation mode and a full model catalog in the same package — for a single one-time payment, with everything running on-device.

- **One-time purchase, no subscription.** The speech-to-text space on Mac is crowded — [Superwhisper](https://superwhisper.com), [Wispr Flow](https://wisprflow.ai), [Voibe](https://getvoibe.com), [Speakmac](https://speakmac.app), Aiko, WhisperClip, and others — and most are billed yearly or monthly. MacWhisper is pay-once-own-forever.
- **File transcription *and* dictation in one app.** Drag in audio/video for transcription (what this plugin wraps), or hit a hotkey anywhere in macOS to dictate straight into the active text field. Superwhisper, Wispr Flow, and Voibe are primarily dictation tools — file transcription is a separate problem they don't really solve. MacWhisper handles both workflows natively.
- **On-device, using the best open models.** Whisper (whisper-cpp, WhisperKit), Parakeet, and Apple's Speech framework (macOS 26+) all run locally — audio never leaves your machine. No cloud upload, no per-minute API bill, no data-retention worries. You pick the accuracy/speed tradeoff that fits each job.

If you don't own MacWhisper yet: **<https://goodsnooze.gumroad.com/l/macwhisper>**. The macwhisper-cli skill wraps MacWhisper's built-in `mw` CLI, so the app itself is required.

See more about MacWhisper [in this video](https://www.youtube.com/watch?v=giNWPfAen8g).

_Note: I am not affiliated, just a fan._

## Structure

```
plugins/work-with-media/
├── .claude-plugin/plugin.json
├── README.md
├── shared/
│   ├── output-conventions.md     ← how both skills manage /tmp files + Read-on-demand
│   └── routing.md                ← decision matrix for which skill handles which input
└── skills/
    ├── macwhisper-cli/           ← local-file transcription
    │   ├── SKILL.md
    │   └── references/
    │       └── choosing-a-model.md
    └── yt-dlp/                   ← URL text/audio extraction
        ├── SKILL.md
        └── references/
            └── setup.md
```

Both skills link to the files under `shared/` rather than inlining the conventions, so the two skills can't drift apart on temp-file naming, Read-on-demand defaults, or the subs-first-vs-transcription decision.

## Additional Documentation

- [skills/macwhisper-cli/SKILL.md](skills/macwhisper-cli/SKILL.md) — MacWhisper CLI wrapper: live CLI reference, local-file workflows, troubleshooting.
- [skills/macwhisper-cli/references/choosing-a-model.md](skills/macwhisper-cli/references/choosing-a-model.md) — engine-by-engine guidance and how to change the default model.
- [skills/yt-dlp/SKILL.md](skills/yt-dlp/SKILL.md) — yt-dlp workflows: subs-first TLDRs, audio-transcription fallback, direct-URL handling.
- [skills/yt-dlp/references/setup.md](skills/yt-dlp/references/setup.md) — install yt-dlp + ffmpeg.
- [shared/output-conventions.md](shared/output-conventions.md) — `/tmp/` naming + Read-on-demand defaults for both skills.
- [shared/routing.md](shared/routing.md) — which skill handles which input.
- [MacWhisper CLI docs](https://macwhisper.helpscoutdocs.com/article/57-macwhisper-command-line-tool) — upstream reference.
