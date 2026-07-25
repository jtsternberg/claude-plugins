#!/usr/bin/env python3
"""Tests for the weekly-recap extractor.

Run: python3 -m unittest discover -s plugins/session-tools/skills/sessions-weekly-recap/tests

Stdlib unittest on purpose — pytest is not installed on this machine or on the CI
runner, and a test that cannot run is not a test.

What these pin: the recap must report what JT actually typed. It previously read
the JSONL itself with a generic strip-all-tags regex and no record filtering, so
harness-injected context, subagent prompts, and Claude's own compaction summaries
were all recorded as his messages. And `commits` keyed off a record type Claude
Code does not emit, so it was always empty.
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from extract_sessions import (  # noqa: E402
    extract_session_data,
    genuine_user_messages,
    session_commits,
)

BASE = {
    "sessionId": "aaaaaaaa-0000-4000-8000-000000000000",
    "cwd": "/tmp/recap-ws",
    "timestamp": "2026-07-25T10:00:00.000Z",
}


def user(content, **extra):
    return {**BASE, "type": "user", "message": {"role": "user", "content": content}, **extra}


def write_transcript(records) -> Path:
    tmp = tempfile.mkdtemp(prefix="recap-test-")
    path = Path(tmp) / f"{BASE['sessionId']}.jsonl"
    with open(path, "w") as fh:
        for r in records:
            fh.write(json.dumps(r) + "\n")
    return path


class GenuineUserMessages(unittest.TestCase):
    def test_keeps_real_prompts_and_drops_what_jt_did_not_type(self):
        path = write_transcript([
            user("build the practice page for next week please"),
            # Harness-injected context — not typed by JT.
            user("here is some injected repo context you should know about", isMeta=True),
            # A subagent's prompt — not typed by JT.
            {**BASE, "type": "user", "isSidechain": True,
             "message": {"role": "user", "content": "subagent: go read every file in src"}},
            # Claude's own recap of the conversation so far — not typed by JT.
            user("Summary: 1. Intent — the user asked for a practice page…", isCompactSummary=True),
            user("actually make the header smaller"),
        ])
        msgs = genuine_user_messages(path)

        self.assertIn("build the practice page for next week please", msgs)
        self.assertIn("actually make the header smaller", msgs)
        joined = " ".join(msgs)
        self.assertNotIn("injected repo context", joined, "isMeta context is not a user message")
        self.assertNotIn("subagent:", joined, "subagent prompts are not user messages")
        self.assertNotIn("Summary: 1. Intent", joined, "a compaction summary is not a user message")

    def test_strips_harness_noise_but_keeps_the_prose_around_it(self):
        path = write_transcript([
            user("<system-reminder>DO NOT SHOW THIS</system-reminder>ship the fix"),
        ])
        msgs = genuine_user_messages(path)
        self.assertEqual(len(msgs), 1)
        self.assertIn("ship the fix", msgs[0])
        self.assertNotIn("DO NOT SHOW THIS", msgs[0])
        self.assertNotIn("system-reminder", msgs[0])

    def test_nested_tags_inside_a_reminder_do_not_leak(self):
        # The old generic regex required the tag body to contain no '<', so a
        # reminder wrapping another tag survived in fragments.
        path = write_transcript([
            user("<system-reminder>context <command-name>/foo</command-name> more</system-reminder>real ask here"),
        ])
        msgs = genuine_user_messages(path)
        self.assertEqual(len(msgs), 1)
        for leak in ("command-name", "system-reminder", "context", "more"):
            self.assertNotIn(leak, msgs[0], leak)
        self.assertIn("real ask here", msgs[0])


class SessionCommits(unittest.TestCase):
    def test_finds_the_commit_line_in_tool_result_blocks(self):
        path = write_transcript([
            user("commit that"),
            {**BASE, "type": "user", "message": {"role": "user", "content": [{
                "type": "tool_result",
                "tool_use_id": "t0",
                "content": "[main 1a2b3c4] fix: the thing\n 2 files changed, 10 insertions(+)",
            }]}},
        ])
        commits = session_commits(path)
        self.assertEqual(len(commits), 1)
        self.assertIn("[main 1a2b3c4] fix: the thing", commits[0])

    def test_ignores_tool_output_that_is_not_a_commit(self):
        path = write_transcript([
            user("list the files"),
            {**BASE, "type": "user", "message": {"role": "user", "content": [{
                "type": "tool_result", "tool_use_id": "t0", "content": "file1\nfile2",
            }]}},
        ])
        self.assertEqual(session_commits(path), [])


class ExtractSessionData(unittest.TestCase):
    def test_returns_both_halves(self):
        path = write_transcript([
            user("do the work and commit it"),
            {**BASE, "type": "user", "message": {"role": "user", "content": [{
                "type": "tool_result", "tool_use_id": "t0",
                "content": "[main deadbee] chore: done\n 1 file changed, 2 insertions(+)",
            }]}},
        ])
        data = extract_session_data(path)
        self.assertEqual(data["user_messages"], ["do the work and commit it"])
        self.assertEqual(len(data["commits"]), 1)


if __name__ == "__main__":
    unittest.main()
