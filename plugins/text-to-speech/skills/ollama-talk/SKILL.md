---
name: ollama-talk
description: "Read text aloud or save it as audio on this Mac with Ollama's local Phonon text-to-speech model — picks a voice from a description ('cheery female British'), sets speed ('a bit faster', 1.25x), plays it or writes a WAV/MP3. Use for 'read this aloud', 'say this', 'text to speech', 'TTS', 'make an audio file of this', 'phonon'."
when_to_use: |
  Use when the user wants text spoken or turned into audio locally: "read this in a
  cheery female British voice, a bit faster", "say this out loud", "read me this
  paragraph", "make an mp3 of this text", "text to speech", "TTS", "narrate this",
  "which voices does phonon have", "ollama run phonon". Not for transcription
  (audio → text); that is the work-with-media plugin's macwhisper-cli skill.
---

# Ollama Talk

Local text-to-speech through Ollama's Phonon model. The bundled `phonon.py` does
everything through the Ollama API: it finds the installed Phonon tag, checks the voice
is really in that tag, generates the WAV, applies speed with ffmpeg, and plays or saves.

Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"
python3 "$SKILL_DIR/scripts/phonon.py" doctor
```

Run `doctor` once per session before the first `say`. Exit 2 means Ollama or the
model is missing; relay the message's fix (`ollama pull phonon`, start Ollama) to the
user rather than working around it.

## 1. Pick the voice

Split the request into structured filters and a vibe. Gender and accent go to flags;
words like "cheery", "calm", "gravelly" you judge yourself from the descriptions.

Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"
python3 "$SKILL_DIR/scripts/phonon.py" voices --gender female --locale british
```

`--locale` takes `en-gb`, `en-us`, `en` (both), `fr-fr`, `de-de`, `es-es`, `es-mx`,
`pt-br`, `characters`, or plain words (`british`, `american`, `mexican`, ...). The list
only contains voices the installed tag actually has, joined to the bundled Gradium
voice catalog; `--all` shows the whole catalog and flags voices
this tag lacks. Never pass a voice that is not in the plain (non-`--all`) list.

Choose the one voice whose description best fits the vibe, and tell the user which
voice you picked and why in a few words. If nothing fits well, say so and name the
closest. The English tag also carries character voices (`--locale characters`:
"Captain Silas Blackwater", "The Snow Queen", ...) for storytelling requests; they
have no gender or age in the catalog, so a `--gender` filter drops them. Names can
contain spaces, so always quote `--voice`.

No voice asked for → `default`.

## 2. Speak

Codex: this path resolves under Claude Code; substitute the directory containing this SKILL.md.

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"
python3 "$SKILL_DIR/scripts/phonon.py" say --voice "Maeve" --speed 1.25 "Text to read."
```

- **Playback vs. file.** Without `--out` it plays and keeps `/tmp/phonon-<epoch>-<pid>.wav`
  (copies older than a day are cleaned up on the next run).
  With `--out path.wav|.mp3|.m4a` it only writes; add `--play` to do both.
- **Speed.** Phonon has no speed control of its own, so `--speed` re-times the WAV with
  ffmpeg's `atempo` (pitch preserved). Map words to numbers: "a bit faster" 1.15–1.25,
  "faster" 1.3–1.5, "a bit slower" 0.85–0.9, "slower" 0.75. Past 0.5–2x the filter is chained
  automatically.
- **Long text.** Use `--file notes.md` or pipe it (`... say -`) rather than a huge argument.
- **Language / tag.** `--tag` picks the model: `phonon` (31M English, Apache 2.0, the
  one with named voices), or `de`, `es`, `fr`, `pt`, `multilingual`, `40m-en` (40M
  models, CC BY-NC — non-commercial). `phonon:en` carries only `default`. A tag that
  isn't installed fails with the exact `ollama pull` command; run `voices --tag <t>`
  before choosing a voice for a non-default tag, since its voice list differs.

`say` prints one JSON line (`path`, `tag`, `voice`, `speed`, `duration_seconds`). Report
the voice and the path; don't paste the JSON.

## Exit codes

1 usage/runtime error · 2 Ollama or model unavailable · 3 voice not in the tag (message
suggests close names) · 4 ffmpeg or afplay missing (`brew install ffmpeg`; afplay is
macOS-only, so use `--out` elsewhere).
