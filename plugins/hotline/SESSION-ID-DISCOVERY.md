# Session ID Discovery

> **This is a standalone utility.** You don't need the rest of Hotline to use it.

## The Problem

There's no `CLAUDE_SESSION_ID` environment variable. Hooks receive the session ID in their stdin payload, but the *running agent itself* has no way to know its own identity — and the community has been [asking](https://github.com/anthropics/claude-code/issues/25642) [for](https://github.com/anthropics/claude-code/issues/13733) [it](https://github.com/anthropics/claude-code/issues/17188) for a while.

Without self-awareness of its own session ID, an agent can't do things like build tooling that reconnects to itself via `--resume`, key per-session state without collisions, or — you know — call another agent and keep track of the conversation. Which is kind of the whole point of Hotline.

## The Solution: Fingerprinting

Hotline ships two scripts that solve this with a clever two-step fingerprint method:

1. **`session-fingerprint.sh`** — Checks for a cached session ID. If found (exit 0), it writes the ID to stdout and you're done. If not found (exit 1), it generates a unique fingerprint string and writes it to stderr.

2. **`session-discover.sh`** — Takes that fingerprint string, greps the recent transcript files for it, and extracts the session ID from the matching filename. Caches the result so all future calls are instant.

The trick: the fingerprint string gets emitted into stderr during a Bash tool call, which means it appears in the conversation transcript. The discover script then finds which transcript file contains it. Transcript filename minus `.jsonl` = session ID. Boom.

## Usage

**First call (two-step):**

```bash
# Step 1: Check cache / generate fingerprint
bash /path/to/plugins/hotline/scripts/session-fingerprint.sh

# Exit 0 → stdout has your session ID. Done!
# Exit 1 → stderr has a fingerprint like SESSION_FINGERPRINT_<uuid>

# Step 2: Discover session from fingerprint (must be a separate tool call —
#          the transcript needs to be written first)
bash /path/to/plugins/hotline/scripts/session-discover.sh "SESSION_FINGERPRINT_<uuid>"

# Exit 0 → stdout has your session ID, now cached for future calls
```

**Subsequent calls (cached):**

```bash
bash /path/to/plugins/hotline/scripts/session-fingerprint.sh
# Exit 0, stdout = session ID. Instant.
```

## Exit Codes

| Script | Exit 0 | Exit 1 | Exit 2 |
|--------|--------|--------|--------|
| `session-fingerprint.sh` | Cache hit — session ID on stdout | Cache miss — fingerprint on stderr | No `claude` process in ancestry |
| `session-discover.sh` | Found — session ID on stdout | Fingerprint not found in transcripts | — |

## Global PATH Access

For convenience, symlink the scripts so they're available everywhere:

```bash
ln -s /path/to/plugins/hotline/scripts/session-fingerprint.sh ~/bin/session-fingerprint
ln -s /path/to/plugins/hotline/scripts/session-discover.sh ~/bin/session-discover
```

Now any hook or script can call `session-fingerprint` without knowing where the plugin lives.

## How It Works Under the Hood

1. `session-fingerprint.sh` walks the process tree (`$$` → `$PPID` → ...) to find the `claude` parent PID
2. Checks `/tmp/claude-session-<pid>` for a cached session ID
3. On cache miss, generates `SESSION_FINGERPRINT_<uuid>` — a unique string that will appear in the transcript
4. `session-discover.sh` greps the 5 most recent `.jsonl` transcript files for that fingerprint
5. The transcript filename IS the session ID (e.g., `609dc906-c675-440a-b694-25f828519f3f.jsonl`)
6. Caches the result to `/tmp/claude-session-<pid>` so all future calls skip discovery

Two Claude sessions in the same directory get different `claude` parent PIDs, so their caches never collide.
