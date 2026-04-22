# yt-dlp + ffmpeg Setup

This skill wraps two CLI tools:

- **`yt-dlp`** — downloads audio/video and extracts subtitles, descriptions, and metadata from YouTube, Vimeo, and hundreds of other sites. Required for every workflow in this skill.
- **`ffmpeg`** — converts downloaded formats. Required **only** for the audio-transcription fallback path (`yt-dlp -x` invokes it internally, and direct-URL workflows use it to convert `.webm`/`.mkv` to `.m4a`).

Both should end up on `$PATH`.

## Install with Homebrew (recommended on macOS)

```bash
brew install yt-dlp ffmpeg
```

Homebrew places both on PATH automatically (`/opt/homebrew/bin` on Apple Silicon, `/usr/local/bin` on Intel).

## Verify

```bash
command -v yt-dlp && yt-dlp --version
command -v ffmpeg && ffmpeg -version | head -1
```

Both should print a path and a version.

## Alternative install options

If the user doesn't use Homebrew, or wants a pinned version:

- **yt-dlp** — <https://github.com/yt-dlp/yt-dlp> (prebuilt binaries, pipx, conda, and many package managers)
- **ffmpeg** — <https://ffmpeg.org/download.html> (official static builds for macOS, Linux, Windows)

Whichever install path the user takes, the only requirement is that both binaries end up on `$PATH`. The verification step above is the final confirmation.
