#!/usr/bin/env python3
"""Tests for phonon.py. The Ollama API is stubbed via phonon.api; nothing reaches a
real server, ffmpeg, or afplay.

  python3 -m unittest discover -s tests
"""

import contextlib
import importlib.util
import io
import json
import struct
import unittest
import wave
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "scripts" / "phonon.py"

spec = importlib.util.spec_from_file_location("phonon", SCRIPT)
ph = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ph)


def wav_bytes(seconds=1.0, rate=24000):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack("<h", 0) * int(seconds * rate))
    return buf.getvalue()


class FakeOllama:
    def __init__(self, tags=("phonon:latest",), voices=("default", "Maeve", "Zoey", "The Snow Queen")):
        self.tags = list(tags)
        self.voices = list(voices)
        self.speech_payloads = []

    def __call__(self, path, payload=None, raw=False, timeout=120):
        if path == "/api/tags":
            return {"models": [{"name": t} for t in self.tags + ["llama3:8b"]]}
        if path == "/api/show":
            return {"voices": self.voices}
        if path == "/v1/audio/speech":
            self.speech_payloads.append(payload)
            return wav_bytes()
        raise AssertionError(path)


def run(argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = ph.main(argv)
    return code, out.getvalue(), err.getvalue()


class TagResolution(unittest.TestCase):
    def test_prefers_latest(self):
        self.assertEqual(ph.resolve_tag(None, ["phonon:de", "phonon:latest"]), "phonon:latest")

    def test_falls_back_to_any_installed_tag(self):
        self.assertEqual(ph.resolve_tag(None, ["phonon:de"]), "phonon:de")

    def test_short_tag_names_normalize(self):
        self.assertEqual(ph.resolve_tag("de", ["phonon:de"]), "phonon:de")
        self.assertEqual(ph.resolve_tag("phonon", ["phonon:latest"]), "phonon:latest")

    def test_missing_model_says_pull(self):
        with self.assertRaises(ph.Fail) as cm:
            ph.resolve_tag(None, [])
        self.assertEqual(cm.exception.code, 2)
        self.assertIn("ollama pull phonon", str(cm.exception))

    def test_missing_requested_tag_names_exact_pull(self):
        with self.assertRaises(ph.Fail) as cm:
            ph.resolve_tag("fr", ["phonon:latest"])
        self.assertIn("ollama pull phonon:fr", str(cm.exception))

    def test_installed_tags_ignores_other_models(self):
        with mock.patch.object(ph, "api", FakeOllama(tags=["phonon:latest", "phonon:de"])):
            self.assertEqual(ph.installed_tags(), ["phonon:de", "phonon:latest"])


class Voices(unittest.TestCase):
    def setUp(self):
        self.catalog = ph.load_catalog()

    def test_catalog_ships_and_parses(self):
        self.assertGreaterEqual(len(self.catalog), 100)
        self.assertEqual(self.catalog["maeve"]["locale"], "en-gb")

    def test_join_keeps_installed_voices_without_metadata(self):
        joined = ph.joined_voices(["default", "Maeve"], self.catalog)
        self.assertEqual(joined[0]["locale"], "")
        self.assertEqual(joined[1]["gender"], "female")

    def test_filter_by_aliases(self):
        joined = ph.joined_voices(["Maeve", "Zoey", "Hugh"], self.catalog)
        names = [v["name"] for v in ph.filter_voices(joined, gender="woman", locale="british")]
        self.assertEqual(names, ["Maeve"])

    def test_language_prefix_matches_both_english_locales(self):
        joined = ph.joined_voices(["Maeve", "Zoey"], self.catalog)
        self.assertEqual(len(ph.filter_voices(joined, locale="english")), 2)

    def test_voices_lists_only_installed(self):
        with mock.patch.object(ph, "api", FakeOllama()):
            code, out, _ = run(["voices", "--json", "--gender", "female"])
        self.assertEqual(code, 0)
        names = {v["name"] for v in json.loads(out)["voices"]}
        # Character voices carry no gender in the catalog, so a gender filter drops them.
        self.assertEqual(names, {"Maeve", "Zoey"})

    def test_voices_all_flags_missing(self):
        with mock.patch.object(ph, "api", FakeOllama()):
            _, out, _ = run(["voices", "--json", "--all", "--locale", "en-gb"])
        rows = {v["name"]: v["installed"] for v in json.loads(out)["voices"]}
        self.assertTrue(rows["Maeve"])
        self.assertFalse(rows["Freya"])


class MatchVoice(unittest.TestCase):
    def test_case_insensitive(self):
        self.assertEqual(ph.match_voice("the snow queen", ["The Snow Queen"]), "The Snow Queen")

    def test_unknown_voice_suggests(self):
        with self.assertRaises(ph.Fail) as cm:
            ph.match_voice("Maev", ["Maeve", "default"])
        self.assertEqual(cm.exception.code, 3)
        self.assertIn("Maeve", str(cm.exception))

    def test_default_when_unspecified(self):
        self.assertEqual(ph.match_voice(None, ["Maeve", "default"]), "default")


class Speed(unittest.TestCase):
    def test_single_filter_in_range(self):
        self.assertEqual(ph.atempo_chain(1.25), "atempo=1.25")

    def test_chains_above_two(self):
        self.assertEqual(ph.atempo_chain(3.0), "atempo=2,atempo=1.5")

    def test_chains_below_half(self):
        self.assertEqual(ph.atempo_chain(0.25), "atempo=0.5,atempo=0.5")

    def test_rejects_nonpositive(self):
        with self.assertRaises(ph.Fail):
            ph.atempo_chain(0)


class StreamingWav(unittest.TestCase):
    def test_patches_placeholder_sizes(self):
        good = wav_bytes(0.5)
        streamed = good[:4] + b"\xff" * 4 + good[8:40] + b"\xff" * 4 + good[44:]
        self.assertEqual(ph.fix_streaming_wav(streamed), good)

    def test_leaves_valid_wav_alone(self):
        good = wav_bytes(0.5)
        self.assertEqual(ph.fix_streaming_wav(good), good)


class Say(unittest.TestCase):
    def test_writes_wav_without_ffmpeg_or_playback(self):
        fake = FakeOllama()
        with TemporaryDirectory() as tmp, mock.patch.object(ph, "api", fake), \
                mock.patch.object(ph.subprocess, "run") as sp:
            out = Path(tmp) / "a.wav"
            code, stdout, _ = run(["say", "--voice", "maeve", "--out", str(out), "Hello"])
            self.assertEqual(code, 0)
            self.assertTrue(out.exists())
            sp.assert_not_called()
        result = json.loads(stdout)
        self.assertEqual(result["voice"], "Maeve")
        self.assertEqual(result["duration_seconds"], 1.0)
        self.assertEqual(fake.speech_payloads[0],
                         {"model": "phonon:latest", "input": "Hello", "voice": "Maeve"})

    def test_speed_runs_ffmpeg_and_cleans_raw(self):
        def fake_run(cmd, check):
            if cmd[0] == "ffmpeg":
                self.assertIn("atempo=1.25", cmd)
                Path(cmd[-1]).write_bytes(wav_bytes(0.8))
        with TemporaryDirectory() as tmp, mock.patch.object(ph, "api", FakeOllama()), \
                mock.patch.object(ph.shutil, "which", return_value="/bin/x"), \
                mock.patch.object(ph.subprocess, "run", side_effect=fake_run) as sp:
            out = Path(tmp) / "fast.wav"
            code, stdout, _ = run(["say", "--speed", "1.25", "--out", str(out), "Hi"])
            self.assertEqual(code, 0)
            self.assertEqual([c.args[0][0] for c in sp.call_args_list], ["ffmpeg"])
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()), ["fast.wav"])
        self.assertEqual(json.loads(stdout)["duration_seconds"], 0.8)

    def test_no_out_plays(self):
        with TemporaryDirectory() as tmp, mock.patch.object(ph, "api", FakeOllama()), \
                mock.patch.object(ph, "default_out", return_value=Path(tmp) / "p.wav"), \
                mock.patch.object(ph.shutil, "which", return_value="/usr/bin/afplay"), \
                mock.patch.object(ph.subprocess, "run") as sp:
            code, _, _ = run(["say", "Hi"])
        self.assertEqual(code, 0)
        self.assertEqual(sp.call_args.args[0][0], "afplay")

    def test_missing_ffmpeg_fails_before_generating(self):
        fake = FakeOllama()
        with mock.patch.object(ph, "api", fake), \
                mock.patch.object(ph.shutil, "which", return_value=None):
            code, _, err = run(["say", "--speed", "1.5", "--out", "/tmp/x.wav", "Hi"])
        self.assertEqual(code, 4)
        self.assertIn("ffmpeg", err)
        self.assertEqual(fake.speech_payloads, [])

    def test_unknown_voice_exit_3(self):
        with mock.patch.object(ph, "api", FakeOllama()):
            code, _, err = run(["say", "--voice", "Nobody", "--out", "/tmp/x.wav", "Hi"])
        self.assertEqual(code, 3)


class BaseUrl(unittest.TestCase):
    def test_host_forms(self):
        cases = {"": "http://localhost:11434", "0.0.0.0": "http://localhost:11434",
                 "127.0.0.1:9999": "http://127.0.0.1:9999",
                 "https://box.local:443": "https://box.local:443"}
        for env, want in cases.items():
            with mock.patch.dict(ph.os.environ, {"OLLAMA_HOST": env}):
                self.assertEqual(ph.base_url(), want, env)


if __name__ == "__main__":
    unittest.main()
