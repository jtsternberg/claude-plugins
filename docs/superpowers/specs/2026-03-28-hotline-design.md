# Hotline: Cross-Workspace Claude Code Communication

**Date:** 2026-03-28
**Status:** Design approved, pending implementation
**Epic:** claude-plugins-wuw

## What We're Building

A Claude Code plugin that enables one running Claude instance (Agent A) to communicate with another Claude instance in a different workspace (Agent B). Think of it as a phone system for your Claude agents — one workspace can dial another to ask questions, delegate work, or collaborate in real-time.

### Use Cases

- **Quick call:** Agent A asks Agent B a factual question. "What's the company tagline?" Agent B answers, done.
- **Work order:** Agent A delegates a task. "Draft an about page based on the marketing site copy." Agent B works on it, reports back when finished.
- **Conference call:** Agent A and Agent B collaborate back-and-forth. "Let's refine this about page section by section." Multiple exchanges until the work is done.

## Plugin Structure

```
plugins/hotline/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   ├── dial/
│   │   ├── SKILL.md                    # Main skill — decision tree, orchestrates calls
│   │   ├── scripts/
│   │   │   ├── resolve-workspace.sh    # Dirmap lookup + identity scan
│   │   │   ├── check-cmux.sh           # CMUX availability detection
│   │   │   ├── headless-call.sh        # Wrapper for claude -p / --resume
│   │   │   ├── cmux-call.sh            # CMUX workspace spawn + send/read
│   │   │   └── session-cache.sh        # Read/write session ID cache
│   │   └── references/
│   │       └── dirmap-fallback.md      # Instructions for minimal dirmap/goto
│   ├── ringing/
│   │   └── SKILL.md                    # Receiver-side first contact; protocol + context (inline)
│   └── pickup/
│       ├── SKILL.md                    # "Who are you?" — introspection + caching
│       └── scripts/
│           └── identity-cache.sh       # Read/write identity JSON
├── scripts/
│   ├── session-fingerprint.sh          # Plant fingerprint / return cached session ID
│   ├── session-discover.sh             # Grep transcript, cache result
│   ├── dirmap-fallback.sh              # Minimal dirmap if not in PATH
│   └── goto-fallback.sh               # Minimal goto if not in PATH
└── README.md                           # Install guide, usage, session ID discovery promo
```

### Single Plugin, Install Everywhere

One plugin called `hotline`. Every workspace can both dial (initiate) and pick up (respond). No separate "receiver" package.

## The Three Skills

### `dial` — The Caller

The brain of the plugin. When an agent decides it needs to talk to another workspace, it invokes this skill. The skill guides the agent through a decision tree — the agent makes the calls silently, only asking the user when genuinely ambiguous.

#### Decision Tree

```
Agent decides it needs cross-workspace communication
│
├─ 1. RESOLVE TARGET WORKSPACE
│  ├─ Explicit path/session ID given? → Use directly
│  ├─ Name/fuzzy reference given? → resolve-workspace.sh
│  │   ├─ dirmap list → fuzzy match names
│  │   ├─ Read cached identities from candidates → match descriptions + tags
│  │   ├─ One clear winner? → Proceed
│  │   └─ Ambiguous? → Ask user to pick
│  └─ No target specified? → Ask user
│
├─ 2. DETERMINE MODE
│  ├─ Need a quick answer? → QUICK CALL
│  ├─ Need work done asynchronously? → WORK ORDER
│  ├─ Need back-and-forth collaboration? → CONFERENCE CALL
│  └─ Not sure? → Ask user
│
├─ 3. SELECT TRANSPORT (automatic, silent — no user prompts)
│  ├─ Quick call → Always headless
│  ├─ Work order → Always headless
│  └─ Conference call:
│     ├─ Estimate short (2-3 exchanges)? → Headless
│     ├─ Estimate deep? → CMUX if available, else headless
│     └─ [Adaptive] Started headless but growing past ~3 exchanges?
│        → Escalate to CMUX if available (same session ID, no context lost)
│        → Announce: "This conversation is getting lengthy. Opened a CMUX window to continue it."
│
├─ 4. DISCOVER OWN SESSION ID
│  ├─ Run session-fingerprint.sh → cache hit? Done.
│  └─ Cache miss? Plant fingerprint, then run session-discover.sh in next tool call.
│  (Needed to key the session cache — prevents collisions when multiple
│   Claude instances run in the same directory)
│
├─ 5. CHECK FOR EXISTING SESSION TO TARGET
│  ├─ Session cache has entry for this caller session → target? → Reuse via --resume
│  └─ No cache? → Spawn new session, cache the ID
│
└─ 6. EXECUTE
   ├─ QUICK CALL: claude -p "/hotline:ringing <prompt>" --cwd <target> --output-format json
   │   Parse response, cache session ID for potential follow-ups.
   │   Surface session ID on first response:
   │   "Connected to <workspace> (session: <id>). Here's what they said: ..."
   │   Return answer to caller.
   │
   ├─ WORK ORDER: Same first call, then poll/wait for completion.
   │
   └─ CONFERENCE CALL: Loop of exchanges.
       First: claude -p "/hotline:ringing <prompt>" --cwd <target> --output-format json
       Follow-ups: claude -p "<message>" --resume <session-id>
       Surface session ID on first response. User can Ctrl+C and take over anytime.
       Agent A relays back-and-forth, reports final result.
```

### `ringing` — The Receiver Handshake

Invoked on first contact via `/hotline:ringing <prompt>`. Primes Agent B with protocol context:

- "You're receiving a hotline call from another workspace"
- The mode (quick call / work order / conference call)
- What's expected (answer and done, do work and report back, or ongoing collaboration)
- The communication protocol (what to expect on follow-up `--resume` messages, how to signal completion)

Only used on the first message. Follow-up messages in the same session don't need it — session history carries the context.

### `pickup` — The Identity Card

Introspects the workspace and caches a concise identity. Used by `dial`'s resolution chain to match fuzzy workspace references.

#### Introspection Protocol

1. Read CLAUDE.md / AGENTS.md for project description
2. Read package.json, Gemfile, composer.json, etc. for tech stack signals
3. Check recent git log for what kind of work happens here
4. Read README or other project description files
5. Synthesize a concise identity

#### Identity Cache Schema

Stored in `~/.agents-hotline/identities/<workspace-path-hash>.json`:

```json
{
  "identity": {
    "name": "Acme Marketing Site",
    "description": "Company marketing website. Next.js app with landing pages, blog, and contact forms.",
    "tags": ["nextjs", "marketing", "copywriting"],
    "generated": 1743170400
  }
}
```

- **Description:** 1-2 sentences max. This is for quick matching, not a full dossier.
- **Tags:** Short keywords for fuzzy matching. Generated from project tech stack and purpose.
- **TTL:** Script compares `generated` timestamp against current time. Default 24 hours, hardcoded in script. Override per-workspace via `HOTLINE_IDENTITY_TTL_HOURS` env property in `~/.claude/settings.json`. `--fresh` flag forces re-introspection regardless of TTL.

#### Dial History

Stored as JSONL (append-only) at `~/.agents-hotline/identities/<workspace-path-hash>.dial_history.jsonl`:

```jsonl
{"session_id":"66aa358b-...","caller":"/home/user/projects/website","mode":"quick_call","timestamp":1743175800}
{"session_id":"77bb469c-...","caller":"/home/user/projects/blog","mode":"work_order","timestamp":1743177600}
```

Each incoming first contact (via `ringing`) appends a line. Capped at 100 entries — on each write, trim oldest lines if over the limit. Useful for context and debugging.

## Transport Layer

Two transports, auto-selected by the agent. Both use the same session ID scheme so escalation from headless to CMUX is seamless.

### Headless Transport

```bash
# First contact — no session yet
result=$(claude -p "/hotline:ringing <prompt>" --cwd "$TARGET" --output-format json)
session_id=$(echo "$result" | jq -r '.session_id')

# Follow-ups — resume existing session
claude -p "<message>" --resume "$session_id"
```

### CMUX Transport

Used for deep conference calls when CMUX is available.

```bash
# Open workspace in CMUX
cmux new-workspace --cwd "$TARGET"

# Start Claude with the existing session (if escalating from headless)
cmux send --workspace "$WS_ID" "claude --resume $SESSION_ID"

# Or start fresh
cmux send --workspace "$WS_ID" "claude"

# Monitor
cmux read-screen --workspace "$WS_ID"
```

### Adaptive Escalation

Agent A tracks exchange count during headless conference calls. If it crosses ~3 exchanges and CMUX is available:

1. Open CMUX workspace at the target path
2. Launch Claude with `--resume` using the existing session ID
3. Announce: "This conversation is getting lengthy. Opened a CMUX window to continue it."
4. Switch to CMUX transport for remaining exchanges

No context lost — same session ID carries the full history.

### Transport is an Implementation Detail

The agent never asks the user about transport. It picks the best available option silently. The user never needs to know or care whether headless or CMUX is being used.

## Workspace Resolution

### Resolution Chain (`resolve-workspace.sh`)

```
Input: user reference (e.g., "marketing workspace", "blog", "/home/user/projects/blog", session ID)
│
├─ Raw path? → Validate exists, done
├─ Session ID (UUID)? → Look up in ~/.agents-hotline/sessions/, done
├─ Dirmap ID? → `dirmap <id>` (or fallback script), done if found
├─ Fuzzy reference?
│   ├─ Run `dirmap list` → get all known projects
│   ├─ For each candidate, read identity cache from ~/.agents-hotline/identities/
│   ├─ Score match on: dirmap name, identity name, identity description, tags
│   ├─ One clear winner (high confidence)? → Use it
│   ├─ 2-3 close matches? → Ask user to pick
│   └─ No matches? → Ask user for path/ID
```

### Dirmap Integration

If `dirmap` is in PATH, use it. If not, fall back to `scripts/dirmap-fallback.sh` which reads/writes `~/.dirmap.json` directly — bare minimum read/list operations matching the same format as the full `dirmap` tool.

### Canonical Path Resolution

All workspace paths are resolved via `realpath` before being used as keys or hashed for filenames. This prevents duplicate entries when the same workspace is accessed via different symlink paths.

## Session Management

### Session Identity — The Fingerprint Method

A running Claude agent has no `CLAUDE_SESSION_ID` env var. The fingerprint method solves this without hooks:

1. **`session-fingerprint.sh`** — Walks the process tree to find the `claude` parent PID. Checks `/tmp/claude-session-<pid>` for a cached session ID. On **cache hit**: exits 0, writes session ID to stdout — done in one call. On **cache miss**: exits 1, writes fingerprint string (`SESSION_FINGERPRINT_<uuid>`) to stderr, prompting the caller to run `session-discover.sh` in a subsequent tool call. The exit code tells the caller whether discovery is needed — no output parsing required.

2. **`session-discover.sh <fingerprint>`** — Only needed on the first call per session (when exit code is 1). Greps the 5 most recent transcript files (newest first) for the fingerprint. The transcript filename IS the session ID. Caches the result to `/tmp/claude-session-<claude-pid>`, so all future `session-fingerprint.sh` calls return instantly (exit code 0).

**Why two steps (first time only):** The transcript is written after a tool call returns. Planting and grepping in the same invocation won't work — the fingerprint isn't in the transcript yet. This two-step dance only happens once per session; every subsequent call hits the PID-keyed cache and skips discovery entirely.

**Why this matters:** Two Claude sessions in the same directory get different `claude` parent PIDs, so their caches don't collide.

These scripts are a headline feature of the plugin — many in the Claude community have requested session ID access (anthropics/claude-code#25642, #13733, #17188). The README should promote them prominently with symlink instructions for global PATH access.

### Session Cache

Stored at `~/.agents-hotline/sessions/<caller-path-hash>.json`:

```json
{
  "caller": "/home/user/projects/website",
  "caller_session_id": "45baab39-...",
  "connections": {
    "/home/user/projects/marketing-site": {
      "session_id": "66aa358b-...",
      "started": 1743172200,
      "last_contact": 1743174720,
      "mode": "work_order",
      "exchange_count": 4
    }
  }
}
```

Keyed by Agent A's session ID (discovered via fingerprint) to prevent collisions when multiple Claude instances run in the same directory.

### Session Reuse

1. Check session cache for this caller session + target pair
2. Found and recent → reuse via `--resume`
3. Found but stale (configurable TTL) → spawn fresh, update cache
4. Not found → spawn fresh, create entry

### Takeover

On the very first response from Agent B, Agent A always outputs the session ID:

> "Connected to marketing workspace (session: `66aa358b-...`). Here's what they said: ..."

The user always has the keys. At any point they can Ctrl+C, run `claude --resume 66aa358b-...` in another terminal, work directly with Agent B, then come back to Agent A and say "done, reconnect." Agent A resumes the session to get the final state.

## Permissions

Agent B operates under the target workspace's own CLAUDE.md and permission settings — that's the ceiling. Agent A can request a scope when spawning (e.g., "I just need to read files" vs "this will require edits").

If Agent A is in yolo/auto-accept mode, it handles Agent B's permission prompts. If Agent A is in normal mode, safety gates stay in place. The skill inherits the caller's trust level.

## State Directory

All hotline state lives in `~/.agents-hotline/`:

```
~/.agents-hotline/
├── identities/
│   ├── <workspace-path-hash>.json           # Cached identity (JSON)
│   └── <workspace-path-hash>.dial_history.jsonl  # Incoming call log (JSONL)
├── sessions/
│   └── <caller-path-hash>.json              # Outgoing session map (JSON)
```

Avoids `~/.claude/` (Anthropic's namespace). Agent-agnostic naming (`agents-hotline`) allows future extension to non-Claude agents.

## File Format Decisions

| Data | Format | Rationale |
|------|--------|-----------|
| Identity cache | JSON | Single object, overwritten on refresh |
| Dial history | JSONL | Append-only log, no need to parse whole file to add entry |
| Session cache | JSON | Map read/updated in place |

## Key Design Decisions

1. **Three interaction modes** — Quick call, work order, conference call. Decision tree guides the agent, with "ask user" escape hatch.
2. **Headless-first transport** — `claude -p` with `--resume` for all modes. CMUX as visibility layer when available.
3. **CMUX used smartly** — Only for deep conference calls. Short collaborations stay headless. Adaptive escalation if a headless session grows past ~3 exchanges.
4. **Transport is invisible** — Agent auto-selects, never asks the user about it. Avoids decision fatigue.
5. **Spawn on demand** — Agent A launches sessions as needed, caches session IDs for reuse.
6. **Fingerprint method for self-identification** — No hooks, no env vars. Works in any terminal. Two-step on first use, cached thereafter.
7. **Workspace resolution via dirmap + cached identities** — Fuzzy matching on names, descriptions, and tags. Ships fallback dirmap/goto scripts.
8. **Canonical paths everywhere** — `realpath` before hashing/keying. Symlinks don't create duplicates.
9. **Single plugin** — Install everywhere. Every workspace can dial and pick up.
10. **`ringing` skill as handshake** — First contact uses `/hotline:ringing` to prime the receiver with protocol context.
11. **Always surface session ID** — On first Agent B response, user gets the session ID. Takeover available anytime.
12. **Permissions inherit caller trust level** — Yolo mode = Agent A handles prompts. Normal mode = safety gates intact.
13. **State in `~/.agents-hotline/`** — Out of Anthropic's namespace, agent-agnostic naming.

## Roadmap

- **Hybrid protocol (Approach 3):** Per-mode transport selection — quick calls always headless, work orders and conference calls prefer CMUX. Not needed now but documented for future optimization.
- **Non-Claude agent support:** The `agents-hotline` naming and protocol design allow future extension to other AI coding agents.

## Open Questions

None remaining — all questions resolved during brainstorming.
