---
name: hotline-send
description: Send a direct message to an already-running Claude Code, Codex, or T3 thread across harnesses without opening a pane.
argument-hint: "<session-id|name|pid|thread_id> <message>"
---

# Hotline: Send

Send one message to a running session. Resolve the target from the user's supplied ID, name, or PID. Pass the message as one argument; do not send without a known sender ID. The script finds the sender ID from `T3CODE_THREAD_ID`, `CLAUDE_CODE_SESSION_ID`, or `CODEX_THREAD_ID`. If the shell lacks it, pass the current session's known ID with `--sender-id`. Set `--sender-name` to your name or role. Claude arguments are $ARGUMENTS; in Codex use the user's request.

Codex: this path resolves under Claude Code; substitute the directory containing this `SKILL.md`.

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"
python3 "$SKILL_DIR/scripts/send.py" <target> <message> --sender-name <name>
```

T3-hosted sessions use T3 even when addressed by their native ID. Native Claude uses its inbox socket; native Codex uses the target account's `codex queue`. Ambiguous or missing matches refuse. A T3 schema error prevents native routing because ownership cannot be established. Each message includes a reply address and unique ID. Output is one JSON object: `delivered` means receiver transcript evidence, `held` means Claude reported a held peer message, `unconfirmed` means no proof appeared within the default 20 seconds, and `sent` means T3 accepted the request. Do not describe acceptance as delivery.

Claude receivers bypassing permissions may hold unidentified peer messages unless launched with `--settings '{"crossSessionInbound":"accept"}'`; changing settings after launch does not release them. Do not automatically retry an unconfirmed message.

A sender can explicitly assert its permission class with `--attest-mode bypass` or `--attest-mode prompting` for a Claude socket target. A live test found that `bypass` was still held as unattested, so do not rely on this flag to bypass the hold. Use the truthful class only when the sender intends this trust assertion. Any process running as the same user can claim either class, so this is not strong authentication. The default sends no assertion.
