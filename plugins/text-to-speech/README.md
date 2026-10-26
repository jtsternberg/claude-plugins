# Text to Speech

Speak text aloud, or save it as audio, with local models. Ask in plain words ("read this in a cheery female British voice, a bit faster") and the skill picks the voice and speed.

- **[`ollama-talk`](skills/ollama-talk/SKILL.md)**: Ollama's [Phonon](https://ollama.com/library/phonon) model. It matches a description to a voice using the [Gradium voice catalog](https://huggingface.co/gradium/phonon-voices), which covers locale, gender, age and a prose description for each voice. It only offers voices the installed tag actually bundles. Speed is applied after generation with ffmpeg's pitch-preserving `atempo`, because Phonon has no speed control of its own.

For the reverse direction (audio to text), see the `work-with-media` plugin's `macwhisper-cli` skill.

## Installation

Run these in a terminal (not inside a Claude Code session):

```bash
claude plugin marketplace add jtsternberg/claude-plugins
claude plugin install text-to-speech@jtsternberg
```

## Prerequisites

- **[Ollama](https://ollama.com)** 0.40.9 or later, running.
- `ollama pull phonon`. This is the 31M English model (Apache 2.0) with 37 named voices plus `default`. The `:de`, `:es`, `:fr`, `:pt`, `:multilingual` and `:40m-en` tags are 40M models under CC BY-NC, so non-commercial use only. `phonon:en` carries only the `default` voice.
- `ffmpeg`, needed only for speed changes and MP3/M4A output: `brew install ffmpeg`.
- macOS `afplay` for playback. On other systems, write a file with `--out`.

## Usage

```bash
python3 skills/ollama-talk/scripts/phonon.py doctor
python3 skills/ollama-talk/scripts/phonon.py voices --gender female --locale british
python3 skills/ollama-talk/scripts/phonon.py say --voice "Imogen" --speed 1.25 "Hello there."
python3 skills/ollama-talk/scripts/phonon.py say --voice "The Snow Queen" --file story.txt --out story.mp3
```

Without `--out`, `say` plays the audio and keeps a copy at `/tmp/phonon-<epoch>.wav`.

## Structure

```
plugins/text-to-speech/
├── .claude-plugin/plugin.json
├── README.md
└── skills/
    └── ollama-talk/
        ├── SKILL.md
        ├── references/voices.jsonl   ← Gradium voice catalog (102 voices)
        ├── scripts/phonon.py          ← stdlib-only CLI over the Ollama API
        └── tests/test_phonon.py
```

To refresh the catalog: `curl -sL https://huggingface.co/gradium/phonon-voices/resolve/main/voices.jsonl -o skills/ollama-talk/references/voices.jsonl`.
