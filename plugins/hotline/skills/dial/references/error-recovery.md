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

### Surface placement (side-by-side / `--window`)

**`open-side-surface.sh failed` / `open-window-surface.sh failed` in error.txt**
- The launcher couldn't open the side-by-side or windowed surface — usually `cmux identify` failed (you're outside cmux or the socket is unreachable), or `cmux tree` returned no panes.
- Recovery: the error.txt carries the opener's stderr. If cmux itself is fine, retry with `--detached` to use the new-workspace placement (which doesn't depend on `cmux identify`). If `cmux identify` consistently fails, fall back to headless (`--headless`).

**`surface <ref> PTY never became ready`**
- The new surface was created but its shell never echoed the readiness probe within the timeout (`surface-ready.sh` exited 3). Common causes: a very slow shell rc, a non-shell program in the surface, or the PTY backend never attaching.
- Recovery: the launcher already closed the surface (no orphan) and wrote the async error. Bump the budget with `HOTLINE_SURFACE_READY_TIMEOUT=<seconds>` (default 8) and retry, or use `--detached`.

**"Terminal surface not found" mid-call**
- The surface lost (or never attached) its PTY. The wait scripts re-`focus-pane` the surface's pane each poll in surface mode to recover, but a surface the user manually closed can't be recovered.
- Recovery: if the user closed the surface, the call is gone — re-dial. Otherwise retry; the readiness probe + focus-pane normally handles transient attach races.

**`--window <name>` keeps creating new windows**
- cmux windows are not directly name-addressable, so Hotline identifies a "named window" by a workspace titled `<name>` inside it. If that titled workspace was renamed or closed, the next `--window <name>` won't find it and will create a fresh window.
- Recovery: pass the explicit `window:<n>` ref instead of a name when you need to target a specific existing window, or accept that the name reseeds a new window + titled workspace.

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
