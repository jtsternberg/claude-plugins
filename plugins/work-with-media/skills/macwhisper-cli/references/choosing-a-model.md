# Choosing a Model

Read this file when the user wants to change models, ask which model to use, or when the active model looks wrong for the file at hand (wrong language, too slow, too inaccurate). For everyday transcription, ignore this file — the default model is fine.

## See what's installed

Run this first to see what's installed and which one is active. (Reference files don't run `!`-injection the way SKILL.md does, so you do need to invoke it yourself.)

```bash
mw models list
```

The `▸` marker on the left flags the currently active model. The first column of every row is the model ID in `<engine>:<model-id>` form — that's the value you pass to `--model` or `mw models select`.

If no model is marked active, select one before transcribing:

```bash
mw models select whisperkit:openai_whisper-small
```

## Engines at a glance

Engine IDs seen in `mw models list`:

- **`whisper-cpp`** — local Whisper implementation using ggml model files (e.g. `ggml-tiny.en`, `ggml-base.en`).
- **`whisperkit`** — local engine. Per the CLI docs, one of the engines that supports `--stream`.
- **`parakeet-pro`** — local engine. IDs in this namespace map to what the CLI docs call "ParakeetKit"; one of the engines that supports `--stream`.
- **`apple`** — macOS on-device Speech framework. Per the docs, macOS 26+ only; shown with `-` size in `mw models list` because the OS manages storage. Supports `--stream`.

MacWhisper can also use cloud engines (OpenAI, Groq, Deepgram, ElevenLabs, MacWhisper AI) if configured. Those return one final result and don't stream.

## Picking a model

Rough heuristics — these are starting points, not rules:

- **Short clips, English-only, speed first** → a small `whisper-cpp` model like `ggml-tiny.en` or `ggml-base.en`, or `parakeet-pro`.
- **Multilingual or higher accuracy needed** → a WhisperKit small/medium, or a `whisper-cpp` non-`.en` model.
- **Long recordings (hour+)** → stick with the active model (`▸` in `mw models list`) if it fits the language/accuracy requirements — switching to a cold model on a long clip means eating the first-load cost before real transcription starts.
- **Streaming output required** (`--stream`) → use a local engine. Per the CLI docs, these stream: WhisperKit, ParakeetKit, Apple speech. Cloud engines (OpenAI, Groq, Deepgram, ElevenLabs, MacWhisper AI) return one final result regardless of `--stream`.

## Changing the default vs. one-off override

Set the default once with `mw models select <id>` — then every subsequent `mw transcribe` uses it. This is the right move when the user has a stable preference.

Use `--model <engine>:<model-id>` on a single `mw transcribe` call when the default is wrong for this specific file (e.g., default is English-only but the clip is multilingual). It doesn't change the persistent default.

```bash
# One-off, doesn't touch the default:
mw transcribe --model whisperkit:openai_whisper-small quick-note.m4a

# Change the default for future runs:
mw models select whisperkit:openai_whisper-small
```

## When a model isn't installed

If `mw models list` doesn't include the model the user asks for, don't try to fetch weights manually — MacWhisper manages the catalog. Point the user to MacWhisper's UI to download the model there first, then re-run `mw models list`.
