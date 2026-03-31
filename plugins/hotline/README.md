# Hotline

**Cross-workspace communication for Claude Code agents.**

Your agents finally have a phone. And unlike your last phone upgrade, this one actually comes with useful new features.

Hotline lets one Claude Code workspace call another — ask a question, delegate a task, or collaborate in real-time. No copy-pasting between terminals. No "hey can you check the other project and tell me..." followed by you manually doing the checking. Just agent-to-agent communication, like nature intended.

## Installation

```bash
# Add the marketplace (if not already added)
/plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
/plugin install hotline@jtsternberg
```

This registers the three Hotline skills (`hotline-dial`, `hotline-ringing`, `hotline-pickup`) as slash commands in Claude Code.

---

## Usage — The Three Call Modes

Hotline supports three ways to communicate with another workspace. Just tell your agent what you need:

### Quick Call

> "Ask my blog workspace what the site tagline is."

A quick question that gets a quick answer. One round trip, in and out.

### Work Order

> "Tell the marketing workspace to draft an about page based on the company info in their repo."

Delegate a task to another workspace and let it work autonomously. You'll get a report when it's done.

### Conference Call

> "I need you to work with the design workspace on the new landing page — coordinate the component structure and styles."

Back-and-forth collaboration between workspaces. Multiple exchanges, iterative refinement. If the conversation runs long, Hotline auto-escalates to a `cmux` window (if available) for better visibility.

---

## Workspace Resolution

When you say "call the blog workspace," Hotline needs to figure out where that workspace actually lives on disk. It uses a layered resolution strategy:

### 1. `dirmap` (preferred)

If you have the [`dirmap`](https://github.com/jtsternberg/Dot-Files/blob/master/bin/dirmap) CLI tool in your PATH, Hotline uses it directly. Your existing `~/.dirmap.json` entries just work — say "call the blog workspace" and Hotline resolves it through dirmap. (That `dirmap` is part of a larger dotfiles setup, but the concept is dead simple — point your Claude at that file and say "build me a standalone version with `add/list/remove` in TypeScript/Go/Cobol/cuneiform/etc." and you'll have one in minutes.)

### 2. Bundled Fallback (no dirmap installed)

Hotline includes `dirmap-fallback.sh`, a minimal reader that supports `get <id>` and `list` against `~/.dirmap.json`. But you'll have to create/maintain a `~/.dirmap.json` file manually:

```json
{
  "blog": "/Users/you/Code/my-blog",
  "marketing": "/Users/you/Code/marketing-site",
  "api": "/Users/you/Code/backend-api"
}
```

### 3. Fuzzy Matching via Cached Identities

Hotline also caches workspace identities (via the `hotline-pickup` skill) — name, description, and tags for each project. Even if you say "call the React frontend" and there's no dirmap entry called "react-frontend," resolution can match against cached identity metadata.

---

## `cmux` Integration

[cmux](https://cmux.com/) is an optional enhancement for conference calls. When available, Hotline uses it for deep collaboration sessions where headless CLI would be limiting.

- **Auto-detected**: Hotline checks for `cmux` availability automatically — no config needed.
- **Auto-escalation**: Conference calls start headless. If the back-and-forth goes past ~3 exchanges and `cmux` is available, Hotline upgrades the connection to a full `cmux` workspace session.
- **Manual override**: You can always ask for a `cmux` session explicitly.

`cmux` gives the remote agent a proper terminal, which is handy when the conversation involves running commands, reviewing output, or doing anything more complex than a Q&A.

---

## Configuration

### Identity Cache TTL

By default, workspace identities (cached by the `pickup` skill) are considered fresh for 24 hours. You can customize this by adding to your `~/.claude/settings.json`:

```json
{
  "env": {
    "HOTLINE_IDENTITY_TTL_HOURS": "48"
  }
}
```

Set it higher if your workspaces don't change much, lower if you're in rapid development across multiple projects.

---

## How It Works

### The Complete Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│  WORKSPACE A (Caller)                                               │
│                                                                     │
│  User: "Dial the blog workspace and ask what the tagline is"        │
│                          │                                          │
│                          ▼                                          │
│                 ┌─────────────────┐                                 │
│                 │  hotline-dial   │  (SKILL.md loaded)              │
│                 │    skill        │                                 │
│                 └────────┬────────┘                                 │
│                          │                                          │
│            ┌─────────────┼──────────────┐                           │
│            ▼             ▼              ▼                           │
│    ┌──────────────┐ ┌──────────┐ ┌────────────┐                    │
│    │ session-     │ │ resolve- │ │ session-   │                    │
│    │ init.sh      │ │workspace │ │ cache.sh   │                    │
│    │              │ │ .sh      │ │            │                    │
│    │ "Who am I?"  │ │ "Where?" │ │ "Talked    │                    │
│    │              │ │          │ │  before?"  │                    │
│    └──────┬───────┘ └────┬─────┘ └─────┬──────┘                    │
│           │              │             │                            │
│           │   ┌──────────┘             │                            │
│           │   │  Uses:                 │                            │
│           │   │  • dirmap get/list     │                            │
│           │   │  • identity-cache.sh   │                            │
│           │   │  • ~/.agents-hotline/  │                            │
│           ▼   ▼                        ▼                            │
│    MY_SESSION_ID    TARGET_PATH    EXISTING_SESSION?                │
│                          │                                          │
│                          ▼                                          │
│                 ┌─────────────────┐                                 │
│                 │ headless-call.sh│  (or cmux-call.sh for deep      │
│                 │                 │   conference calls)              │
│                 └────────┬────────┘                                 │
│                          │                                          │
└──────────────────────────┼──────────────────────────────────────────┘
                           │
              cd $TARGET && claude -p \
                "/hotline-ringing [MODE: ...] \
                 [CALLER: ...] [SESSION: ...] \
                 <the actual prompt>" \
                --output-format json
                           │
                           │  (first contact)
                           │  or: claude -p "..." --resume $ID
                           │  (follow-up)
                           │
┌──────────────────────────┼──────────────────────────────────────────┐
│  WORKSPACE B (Receiver)  ▼                                          │
│                                                                     │
│                 ┌─────────────────┐                                 │
│                 │ hotline-ringing │  (SKILL.md loaded via           │
│                 │    skill        │   /hotline-ringing in prompt)   │
│                 └────────┬────────┘                                 │
│                          │                                          │
│            Parses: MODE, CALLER, SESSION                            │
│            from the prompt metadata                                 │
│                          │                                          │
│                          ▼                                          │
│            ┌─────────────────────────┐                              │
│            │  Agent B does the work  │                              │
│            │  (reads files, answers  │                              │
│            │   questions, makes      │                              │
│            │   changes, etc.)        │                              │
│            └─────────────┬───────────┘                              │
│                          │                                          │
│                          ▼                                          │
│            ┌─────────────────────────┐                              │
│            │  dial-history.sh append │  (logs the call)             │
│            └─────────────┬───────────┘                              │
│                          │                                          │
│            Response + STATUS signal                                 │
│            (WORK_COMPLETE / WORK_IN_PROGRESS)                       │
│                          │                                          │
└──────────────────────────┼──────────────────────────────────────────┘
                           │
                           │  JSON response with session_id
                           │
┌──────────────────────────┼──────────────────────────────────────────┐
│  WORKSPACE A (back)      ▼                                          │
│                                                                     │
│            ┌─────────────────────────┐                              │
│            │  session-cache.sh set   │  (caches session for reuse)  │
│            └─────────────┬───────────┘                              │
│                          │                                          │
│                          ▼                                          │
│  Agent A reports to user:                                           │
│  "Connected to blog (session: abc123).                              │
│   Their response: [answer]"                                         │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Session ID Discovery (the "Know Thyself" step)

```
session-init.sh
      │
      ▼
session-fingerprint.sh ──► Cache hit? ──YES──► stdout: session ID (exit 0)
      │
      NO (exit 1)
      │
      ▼
stderr: SESSION_FINGERPRINT_<uuid>
      │
      │  (fingerprint gets written into transcript
      │   when this tool call completes)
      │
      ▼  [SEPARATE TOOL CALL]
      │
session-init.sh discover <fingerprint>
      │
      ▼
session-discover.sh
      │
      ▼
Grep recent .jsonl transcripts ──► Found? ──► Cache to /tmp, return ID
      │                              │
      NO                         (retries 3x
      │                          with 1s delay
      ▼                          for async flush)
Fallback: search 10 most
recent project dirs
```

### Workspace Resolution

```
resolve-workspace.sh "<user's words>"
      │
      ├── Starts with / or ~ ? ──► Validate path exists ──► Done
      │
      ├── Looks like a UUID? ──► Search session cache ──► Done
      │
      ├── dirmap get "<ref>" ──► Exact match? ──► Done
      │
      └── dirmap list --json ──► Enrich with identity caches
              │                   from ~/.agents-hotline/identities/
              ▼
          Candidates JSON on stderr (exit 1)
          Agent picks the best match or asks user
```

### The Three Skills

- **`hotline-dial`** — The caller side. Orchestrates the entire flow above: resolve target, discover session, select transport, make the call, relay the response.
- **`hotline-ringing`** — The receiver-side handshake. Loaded via the `/hotline-ringing` prefix in the prompt. Tells Agent B what's happening, how to respond, and how to signal completion.
- **`hotline-pickup`** — Workspace identity introspection. Runs `gather-workspace-info.sh` to examine CLAUDE.md, package files, git history, then caches a concise identity to `~/.agents-hotline/identities/`. Used by workspace resolution for fuzzy matching.

### State

All hotline state lives in `~/.agents-hotline/`:
- `identities/` — Cached workspace identity JSON files
- `identities/*.dial_history.jsonl` — Append-only call logs per workspace
- `sessions/` — Outgoing session maps (keyed by caller session ID)

---

## Roadmap

### Hybrid Protocol

Per-mode transport selection — using the best tool for each call type rather than defaulting to headless-with-optional-`cmux`-escalation. Think: different transport backends optimized for quick calls vs. deep collaboration.

### Non-Claude Agent Support

You may have noticed the state directory is `~/.agents-hotline/`, not `~/.claude-hotline/`. That naming was deliberate. The long-term vision is cross-agent communication — not just Claude-to-Claude, but any agent that speaks the protocol. Claude just happens to be the first tenant.

---

## Bonus: Session ID Discovery

Hotline includes a standalone session ID discovery utility — a running Claude agent can discover its own session ID, something Claude Code doesn't expose natively. The community has been [asking for this](https://github.com/anthropics/claude-code/issues/25642) for a while.

**[Full docs and usage: SESSION-ID-DISCOVERY.md](SESSION-ID-DISCOVERY.md)**

---
