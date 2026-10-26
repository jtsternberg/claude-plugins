#!/usr/bin/env python3
"""Local text-to-speech through Ollama's Phonon model.

  phonon.py doctor
  phonon.py voices [--tag T] [--gender G] [--locale L] [--all] [--json]
  phonon.py say [TEXT | -] [--file F] [--voice V] [--speed R] [--tag T] [--out PATH] [--play]

Everything goes through the Ollama HTTP API (the same server `ollama run` talks to).
Phonon has no native speed control — the API rejects any speed but 1 — so speed is
applied afterwards with ffmpeg's pitch-preserving atempo filter.

Exit codes: 1 usage/runtime error, 2 Ollama or the Phonon model unavailable,
3 voice not in the installed tag, 4 ffmpeg/afplay missing.
"""

import argparse
import difflib
import json
import os
import shutil
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
CATALOG = HERE.parent / "references" / "voices.jsonl"
FAMILY = "phonon"

# Friendly words people use for a locale, mapped to the catalog's locale codes.
LOCALE_ALIASES = {
    "british": "en-gb", "uk": "en-gb", "gb": "en-gb", "england": "en-gb", "english": "en",
    "american": "en-us", "us": "en-us", "usa": "en-us",
    "french": "fr-fr", "france": "fr-fr",
    "german": "de-de", "germany": "de-de",
    "spanish": "es-es", "spain": "es-es", "castilian": "es-es",
    "mexican": "es-mx", "mexico": "es-mx", "latam": "es-mx",
    "brazilian": "pt-br", "portuguese": "pt-br", "brazil": "pt-br",
    "character": "characters",
}
GENDER_ALIASES = {
    "female": "female", "woman": "female", "women": "female", "f": "female", "girl": "female",
    "male": "male", "man": "male", "men": "male", "m": "male", "boy": "male",
}


class Fail(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def base_url():
    host = os.environ.get("OLLAMA_HOST", "").strip() or "http://localhost:11434"
    if "://" not in host:
        host = "http://" + host
    # `ollama serve` accepts 0.0.0.0 as a bind address; it is not a reachable client target.
    host = host.replace("://0.0.0.0", "://localhost")
    if host.count(":") < 2:
        host += ":11434"
    return host.rstrip("/")


def api(path, payload=None, raw=False, timeout=120):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(base_url() + path, data=data,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace").strip()
        raise Fail(f"Ollama API {path} returned {e.code}: {detail}")
    except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
        if not shutil.which("ollama"):
            raise Fail("Ollama is not installed. Install it from https://ollama.com, "
                       "then run: ollama pull phonon", 2)
        raise Fail(f"Ollama server not reachable at {base_url()} ({e}). "
                   "Start the Ollama app or run `ollama serve`.", 2)
    return body if raw else json.loads(body)


def normalize_tag(tag):
    if not tag:
        return None
    if ":" not in tag:
        tag = f"{FAMILY}:latest" if tag == FAMILY else f"{FAMILY}:{tag}"
    return tag


def installed_tags():
    models = api("/api/tags").get("models", [])
    names = [m.get("name") or m.get("model", "") for m in models]
    return sorted(n for n in names if n.split(":")[0] == FAMILY)


def resolve_tag(requested=None, installed=None):
    installed = installed_tags() if installed is None else installed
    tag = normalize_tag(requested)
    if tag:
        if tag not in installed:
            have = ", ".join(installed) or "none"
            raise Fail(f"{tag} is not installed (installed Phonon tags: {have}). "
                       f"Run: ollama pull {tag}", 2)
        return tag
    if not installed:
        raise Fail("No Phonon model installed. Run: ollama pull phonon", 2)
    default = f"{FAMILY}:latest"
    return default if default in installed else installed[0]


def tag_voices(tag):
    return list(api("/api/show", {"model": tag}).get("voices") or [])


def load_catalog(path=CATALOG):
    rows = {}
    with open(path) as fh:
        for line in fh:
            if line.strip():
                row = json.loads(line)
                rows[row["name"].casefold()] = row
    return rows


def joined_voices(names, catalog):
    """Installed voice names joined to catalog metadata; unknown voices keep blanks."""
    out = []
    for name in names:
        meta = catalog.get(name.casefold(), {})
        out.append({
            "name": name,
            "locale": meta.get("locale") or "",
            "gender": meta.get("gender") or "",
            "age": meta.get("age") or "",
            "description": meta.get("description") or "",
        })
    return out


def norm_locale(value):
    v = value.strip().lower().replace("_", "-")
    return LOCALE_ALIASES.get(v, v)


def norm_gender(value):
    v = value.strip().lower()
    return GENDER_ALIASES.get(v, v)


def filter_voices(voices, gender=None, locale=None):
    out = voices
    if gender:
        g = norm_gender(gender)
        out = [v for v in out if v["gender"] == g]
    if locale:
        loc = norm_locale(locale)
        # "en" matches en-us and en-gb; a full code matches exactly.
        out = [v for v in out if v["locale"] == loc or v["locale"].split("-")[0] == loc]
    return out


def match_voice(requested, available):
    if requested is None:
        return "default" if "default" in available else available[0]
    for name in available:
        if name.casefold() == requested.strip().casefold():
            return name
    close = difflib.get_close_matches(requested, available, n=3, cutoff=0.5)
    hint = f" Did you mean: {', '.join(close)}?" if close else ""
    raise Fail(f"Voice {requested!r} is not in this tag.{hint} "
               "List the installed voices with: phonon.py voices", 3)


def atempo_chain(rate):
    """atempo takes 0.5–2.0 per filter, so larger changes chain several."""
    if rate <= 0:
        raise Fail("--speed must be positive")
    factors = []
    while rate > 2.0:
        factors.append(2.0)
        rate /= 2.0
    while rate < 0.5:
        factors.append(0.5)
        rate /= 0.5
    factors.append(rate)
    return ",".join(f"atempo={f:g}" for f in factors)


def fix_streaming_wav(audio):
    """The speech endpoint streams, so its WAV header carries 0xFFFFFFFF placeholder
    sizes; most readers then report a ~24-hour duration. Patch in the real sizes."""
    placeholder = b"\xff\xff\xff\xff"
    if (len(audio) >= 44 and audio[:4] == b"RIFF" and audio[36:40] == b"data"
            and placeholder in (audio[4:8], audio[40:44])):
        audio = (audio[:4] + struct.pack("<I", len(audio) - 8) + audio[8:40]
                 + struct.pack("<I", len(audio) - 44) + audio[44:])
    return audio


def wav_seconds(path):
    with wave.open(str(path)) as w:
        return w.getnframes() / float(w.getframerate())


def default_out():
    return Path("/tmp") / f"phonon-{int(time.time())}.wav"


def ffmpeg_cmd(src, dst, speed):
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(src)]
    if speed != 1:
        cmd += ["-filter:a", atempo_chain(speed)]
    return cmd + [str(dst)]


def read_text(args):
    if args.file:
        return Path(args.file).read_text()
    if args.text in (None, "-"):
        if sys.stdin.isatty():
            raise Fail("No text given: pass TEXT, --file, or pipe it on stdin")
        return sys.stdin.read()
    return args.text


def cmd_doctor(args):
    report = {"ollama_url": base_url(), "ffmpeg": shutil.which("ffmpeg"),
              "afplay": shutil.which("afplay")}
    tags = installed_tags()
    report["installed_tags"] = tags
    report["tag"] = resolve_tag(args.tag, tags)
    report["voices"] = len(tag_voices(report["tag"]))
    print(json.dumps(report, indent=2))


def cmd_voices(args):
    tag = resolve_tag(args.tag)
    names = tag_voices(tag)
    catalog = load_catalog()
    if args.all:
        installed = {n.casefold() for n in names}
        voices = joined_voices([r["name"] for r in catalog.values()], catalog)
        for v in voices:
            v["installed"] = v["name"].casefold() in installed
    else:
        voices = joined_voices(names, catalog)
    voices = filter_voices(voices, args.gender, args.locale)
    if args.json:
        print(json.dumps({"tag": tag, "voices": voices}, indent=2))
        return
    print(f"# {tag}: {len(voices)} voice(s)")
    for v in voices:
        flag = "" if v.get("installed", True) else " [not in this tag]"
        meta = " / ".join(x for x in (v["locale"], v["gender"], v["age"]) if x) or "no metadata"
        print(f"{v['name']}{flag} — {meta}" + (f": {v['description']}" if v["description"] else ""))


def cmd_say(args):
    text = read_text(args).strip()
    if not text:
        raise Fail("Text is empty")
    tag = resolve_tag(args.tag)
    voice = match_voice(args.voice, tag_voices(tag))
    out = Path(args.out).expanduser() if args.out else default_out()
    play = args.play or not args.out
    needs_ffmpeg = args.speed != 1 or out.suffix.lower() != ".wav"
    if needs_ffmpeg and not shutil.which("ffmpeg"):
        raise Fail("ffmpeg is required for --speed or non-WAV output: brew install ffmpeg", 4)
    if play and not shutil.which("afplay"):
        raise Fail("afplay not found (macOS only); pass --out to write a file instead", 4)

    started = time.monotonic()
    audio = api("/v1/audio/speech", {"model": tag, "input": text, "voice": voice},
                raw=True, timeout=600)
    audio = fix_streaming_wav(audio)
    gen_seconds = time.monotonic() - started
    out.parent.mkdir(parents=True, exist_ok=True)
    if needs_ffmpeg:
        raw_path = out.with_name(out.stem + ".raw.wav")
        raw_path.write_bytes(audio)
        try:
            subprocess.run(ffmpeg_cmd(raw_path, out, args.speed), check=True)
        finally:
            raw_path.unlink(missing_ok=True)
    else:
        out.write_bytes(audio)

    result = {"path": str(out), "tag": tag, "voice": voice, "speed": args.speed,
              "generate_seconds": round(gen_seconds, 2)}
    if out.suffix.lower() == ".wav":
        result["duration_seconds"] = round(wav_seconds(out), 2)
    print(json.dumps(result))
    if play:
        subprocess.run(["afplay", str(out)], check=True)


def build_parser():
    p = argparse.ArgumentParser(description="Local TTS with Ollama Phonon")
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("doctor", help="Check Ollama, the Phonon tag, ffmpeg, afplay")
    d.add_argument("--tag")
    d.set_defaults(func=cmd_doctor)

    v = sub.add_parser("voices", help="List voices the installed tag actually has")
    v.add_argument("--tag")
    v.add_argument("--gender", help="female|male (aliases: woman, man, ...)")
    v.add_argument("--locale", help="en-gb, en-us, fr-fr, ... or british, american, ...")
    v.add_argument("--all", action="store_true",
                   help="Show every catalog voice, flagging ones this tag lacks")
    v.add_argument("--json", action="store_true")
    v.set_defaults(func=cmd_voices)

    s = sub.add_parser("say", help="Speak text; plays unless --out is given without --play")
    s.add_argument("text", nargs="?", help="Text to speak, or - for stdin")
    s.add_argument("--file", help="Read text from a file")
    s.add_argument("--voice", help="Exact voice name (case-insensitive)")
    s.add_argument("--speed", type=float, default=1.0, help="Playback rate, e.g. 1.25")
    s.add_argument("--tag", help="Ollama tag: phonon, phonon:de, de, multilingual, ...")
    s.add_argument("--out", help="Output file (.wav, or .mp3/.m4a via ffmpeg)")
    s.add_argument("--play", action="store_true", help="Also play when --out is given")
    s.set_defaults(func=cmd_say)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        args.func(args)
    except Fail as e:
        print(f"error: {e}", file=sys.stderr)
        return e.code
    except subprocess.CalledProcessError as e:
        print(f"error: {e.cmd[0]} failed with exit {e.returncode}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
