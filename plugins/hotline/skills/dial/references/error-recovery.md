# Hotline Error Recovery

Common failure modes and how to recover from them.

## Session Fingerprint Failures

**"Could not find claude process in ancestry"**
- You're not running inside a Claude Code session, or the process tree is unusual.
- Recovery: Ask the user to provide their session ID manually, or skip session ID discovery and proceed without session caching.

**"Fingerprint not found in recent transcripts"**
- The fingerprint was planted but the transcript file wasn't written yet (both steps ran in the same tool call), or the transcript directory path doesn't match.
- Recovery: Make sure `session-init.sh` and `session-init.sh discover` run in **separate** tool calls. If it still fails, check that `~/.claude/projects/` contains transcript files for the current directory.

## Workspace Resolution Failures

**"No entry for '<id>'"**
- The dirmap ID doesn't exist in `~/.dirmap.json`.
- Recovery: Run `dirmap list` (or `dirmap-fallback.sh list`) to show available IDs. Ask the user which one they meant.

**"Path does not exist: <path>"**
- The resolved path doesn't exist on disk.
- Recovery: The project may have been moved or deleted. Ask the user for the correct path.

**Exit 1 with candidates JSON on stderr**
- Multiple fuzzy matches found, none confident enough to auto-select.
- Recovery: This is normal — present the candidates to the user and ask them to pick.

**"Could not resolve '<reference>'"**
- No dirmap entries, no identity matches, nothing.
- Recovery: Ask the user for an exact path or dirmap ID. Suggest they add the workspace to `~/.dirmap.json`.

## Headless Call Failures

**`{"error": "Claude CLI returned no output"}`**
- The `claude -p` command failed silently or timed out.
- Recovery: Check the stderr captured in the error message. Common causes: auth issues, rate limits, invalid workspace path. Retry once, then report to the user.

**`{"error": "No --cwd provided for first contact"}`**
- Bug in the dial flow — first contact requires `--cwd`.
- Recovery: Ensure `--cwd "$TARGET_PATH"` is passed on first contact. This shouldn't happen if the decision tree is followed correctly.

**Empty or malformed JSON response**
- The remote agent's response couldn't be parsed.
- Recovery: Check the raw `claude -p` output. The remote workspace may not have the hotline plugin installed. Ask the user to verify.

## Session Cache Issues

**Stale session — `--resume` fails**
- The cached session ID is from a previous Claude run and no longer valid.
- Recovery: Clear the session cache entry and start fresh:
  ```bash
  # The session-cache.sh set command will overwrite the stale entry
  bash "$HOTLINE_DIAL_SCRIPTS/session-cache.sh" set "$TARGET_PATH" \
    --caller-session "$MY_SESSION_ID" --session "$NEW_SESSION_ID" --mode "$MODE"
  ```

**Two agents in same directory colliding**
- Session fingerprint cache uses PID, so this shouldn't happen. If it does, the `/tmp/claude-session-<pid>` files may be stale.
- Recovery: Delete `/tmp/claude-session-*` files and re-run `session-init.sh`.

## CMUX Failures

**`cmux ping` fails**
- CMUX is installed but not running.
- Recovery: Fall back to headless silently. This is the expected behavior — CMUX is optional.

**"Failed to create CMUX workspace"**
- CMUX couldn't open a new workspace (maybe at workspace limit).
- Recovery: Fall back to headless for this call. Log the failure for debugging.

## Identity Cache Issues

**Stale identity — resolution picks wrong workspace**
- The cached identity is outdated (project changed significantly).
- Recovery: Run `hotline-pickup` with `--fresh` on the target workspace to regenerate:
  ```bash
  bash "$HOTLINE_DIAL_SCRIPTS/headless-call.sh" --cwd "$TARGET_PATH" \
    --prompt "/hotline-pickup --fresh"
  ```

## General Principles

1. **Retry once, then report.** Don't loop endlessly.
2. **Fall back gracefully.** CMUX → headless. Cached session → fresh session. Fuzzy match → ask user.
3. **Surface errors clearly.** Include the actual error message when reporting to the user.
4. **Don't guess.** If resolution is ambiguous, ask. If a session is stale, start fresh.
