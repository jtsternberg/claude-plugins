# Routing: Which Skill For Which Input

This plugin ships two complementary skills. Pick based on what the user handed you.

## Local audio or video file → `macwhisper-cli`

An `.m4a`, `.wav`, `.mp3`, `.mp4`, etc. already on disk. Run `mw transcribe` — see [`../skills/macwhisper-cli/SKILL.md`](../skills/macwhisper-cli/SKILL.md).

## URL (YouTube / Vimeo / any yt-dlp-supported site) → `yt-dlp` first

Even when the user asks to "transcribe" the video, audio transcription is usually the heavyweight option. For most "TLDR / summarize / teach me about / what does this say about X" requests, the yt-dlp skill's **subs-first** workflow is enough:

1. `yt-dlp --skip-download --write-description --write-info-json --write-auto-sub --sub-lang en --sub-format vtt` pulls the creator's description, chapter markers, and auto-generated captions in one shot.
2. Description + chapters alone often covers a TLDR without reading the captions.
3. If that isn't enough, Read the `.vtt` caption file.

See [`../skills/yt-dlp/SKILL.md`](../skills/yt-dlp/SKILL.md).

### Fall back to audio transcription (hand off to `macwhisper-cli`) only when:

- No captions exist for the video (older uploads, creator disabled auto-subs).
- Captions are visibly low-quality (heavy accents, music, specialized jargon showing up as garbled words).
- The user explicitly asks for a high-accuracy transcript (research, legal, accessibility).
- The source is an audio-only URL with no caption metadata.

In the fallback case, the yt-dlp skill provides the audio-download commands. Once the audio lands at `/tmp/yt-<id>.m4a`, `macwhisper-cli` takes over.

## Direct audio/video URL (not a video-sharing site) → depends

If the URL serves a format MacWhisper accepts (`.m4a`, `.wav`), `curl` + `mw transcribe` is enough — no yt-dlp needed. The yt-dlp skill documents this direct-URL pattern too for completeness (and covers the `ffmpeg` conversion step when formats don't match).

## Composed flows

The canonical composed request is *"teach me about this video — I want the TLDR, then I want to ask questions."* That's one pipeline: yt-dlp pulls subs + description → agent writes the TLDR → follow-up turns Read the same files.

Both skills' outputs go to `/tmp/` following the [shared output conventions](output-conventions.md), so the agent can hand off between them by file path rather than piping text through context.
