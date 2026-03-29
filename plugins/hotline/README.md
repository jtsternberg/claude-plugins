# Hotline

**Cross-workspace communication for Claude Code agents.**

Your agents finally have a phone. And unlike your last phone upgrade, this one actually comes with useful new features.

Hotline lets one Claude Code workspace call another — ask a question, delegate a task, or collaborate in real-time. No copy-pasting between terminals. No "hey can you check the other project and tell me..." followed by you manually doing the checking. Just agent-to-agent communication, like nature intended.

---

## Session ID Discovery

> **This is a standalone utility.** You don't need the rest of Hotline to use it.

### The Problem

There's no `CLAUDE_SESSION_ID` environment variable. Claude Code doesn't expose its session ID to hooks, scripts, or tools — and the community has been [asking](https://github.com/anthropics/claude-code/issues/25642) [for](https://github.com/anthropics/claude-code/issues/13733) [it](https://github.com/anthropics/claude-code/issues/17188) for a while.

Without a session ID, you can't:
- Correlate hook executions back to a specific conversation
- Build tooling that talks to a known session via `--resume`
- Log which session triggered which action
- Do pretty much anything that requires self-awareness (the machines are getting philosophical)

### The Solution: Fingerprinting

Hotline ships two scripts that solve this with a clever two-step fingerprint method:

1. **`session-fingerprint.sh`** — Checks for a cached session ID. If found (exit 0), it writes the ID to stdout and you're done. If not found (exit 1), it generates a unique fingerprint string and writes it to stderr.

2. **`session-discover.sh`** — Takes that fingerprint string, greps the recent transcript files for it, and extracts the session ID from the matching filename. Caches the result so all future calls are instant.

The trick: the fingerprint string gets emitted into stderr during a Bash tool call, which means it appears in the conversation transcript. The discover script then finds which transcript file contains it. Transcript filename minus `.jsonl` = session ID. Boom.

### Usage

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

### Exit Codes

| Script | Exit 0 | Exit 1 | Exit 2 |
|--------|--------|--------|--------|
| `session-fingerprint.sh` | Cache hit — session ID on stdout | Cache miss — fingerprint on stderr | No `claude` process in ancestry |
| `session-discover.sh` | Found — session ID on stdout | Fingerprint not found in transcripts | — |

### Global PATH Access

For convenience, symlink the scripts so they're available everywhere:

```bash
ln -s /path/to/plugins/hotline/scripts/session-fingerprint.sh ~/bin/session-fingerprint
ln -s /path/to/plugins/hotline/scripts/session-discover.sh ~/bin/session-discover
```

Now any hook or script can call `session-fingerprint` without knowing where the plugin lives.

---

## Installation

```bash
claude plugins add /path/to/claude-plugins/plugins/hotline
```

This registers the three Hotline skills (`dial`, `ringing`, `pickup`) as slash commands in Claude Code.

---

## Usage — The Three Call Modes

Hotline supports three ways to communicate with another workspace. Just tell your agent what you need:

### Quick Call

> "Ask my blog workspace what the site tagline is."

A quick question that gets a quick answer. One round trip, in and out, like a phone call to your mom that somehow *doesn't* turn into an hour-long update about the neighbors.

### Work Order

> "Tell the marketing workspace to draft an about page based on the company info in their repo."

Delegate a task to another workspace and let it work autonomously. You'll get a report when it's done. Think less "collaboration" and more "that one coworker who actually follows through on Slack messages."

### Conference Call

> "I need you to work with the design workspace on the new landing page — coordinate the component structure and styles."

Back-and-forth collaboration between workspaces. Multiple exchanges, iterative problem-solving. If headless mode starts feeling cramped after a few rounds, Hotline auto-escalates to CMUX (if available) so the conversation can breathe.

---

## Workspace Resolution

When you say "call the blog workspace," Hotline needs to figure out where that workspace actually lives on disk. It uses a layered resolution strategy:

### 1. `dirmap` (preferred)

If you have the [`dirmap`](https://github.com/jtsternberg/dirmap) CLI tool in your PATH, Hotline uses it for project lookups. Dirmap maintains a registry of your project directories with IDs.

### 2. Bundled Fallback

No `dirmap` binary? No problem. Hotline includes `dirmap-fallback.sh`, a minimal reader that supports `get <id>` and `list` against the same `~/.dirmap.json` format.

### 3. Setting Up `~/.dirmap.json`

Create a JSON file mapping project IDs to paths:

```json
{
  "blog": "/Users/you/Code/my-blog",
  "marketing": "/Users/you/Code/marketing-site",
  "api": "/Users/you/Code/backend-api",
  "design-system": "/Users/you/Code/design-system"
}
```

IDs are whatever makes sense to you — project names, abbreviations, nicknames. When you say "call the blog workspace," Hotline matches against these.

### 4. Fuzzy Matching via Cached Identities

Hotline also caches workspace identities (via the `pickup` skill) — name, description, and tags for each project. So even if you say "call the React frontend" and there's no dirmap entry called "react-frontend," resolution can match against cached identity metadata. Fuzzy, forgiving, and surprisingly good at understanding what you mean.

---

## CMUX Integration

[CMUX](https://github.com/jtsternberg/cmux) is an optional enhancement for conference calls. When available, Hotline uses it for deep collaboration sessions where headless CLI would be limiting.

- **Auto-detected**: Hotline checks for CMUX availability automatically — no config needed.
- **Auto-escalation**: Conference calls start headless. If the back-and-forth goes past ~3 exchanges and CMUX is available, Hotline upgrades the connection to a full CMUX workspace session.
- **Manual override**: You can always ask for a CMUX session explicitly.

CMUX gives the remote agent a proper terminal, which is handy when the conversation involves running commands, reviewing output, or doing anything more complex than a Q&A.

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

A brief peek under the hood for the curious (and the PRs-welcome crowd):

### The Three Skills

- **`dial`** — The caller side. Resolves the target workspace, picks a transport, manages the session, and relays responses. The switchboard operator.
- **`ringing`** — The receiver-side handshake. Primes the remote agent with protocol context so it knows it's on a call, not just getting a weird prompt out of nowhere.
- **`pickup`** — Workspace identity introspection. Examines the local project (CLAUDE.md, package files, git history) and caches a concise identity JSON for resolution purposes.

### Transport

The core transport is headless `claude -p` (for initial contact) and `claude --resume` (for follow-ups). This means cross-workspace communication works without any additional infrastructure — just Claude Code itself.

### Session Fingerprinting

Agents identify themselves using the [session fingerprint method](#session-id-discovery) described above. This is how the caller knows its own session ID, which gets passed to the receiver for logging and session management.

### State

All hotline state lives in `~/.agents-hotline/`:
- `identities/` — Cached workspace identity JSON files
- `identities/*.dial_history.jsonl` — Append-only call logs per workspace

---

## Roadmap

### Hybrid Protocol (Approach 3)

Per-mode transport selection — using the best tool for each call type rather than defaulting to headless-with-optional-CMUX-escalation. Think: different transport backends optimized for quick calls vs. deep collaboration.

### Non-Claude Agent Support

You may have noticed the state directory is `~/.agents-hotline/`, not `~/.claude-hotline/`. That naming was deliberate. The long-term vision is cross-agent communication — not just Claude-to-Claude, but any agent that speaks the protocol. The hotline is open for business; Claude just happens to be the first tenant.

---

## Credits

Built by [JT Sternberg](https://github.com/jtsternberg) because alt-tabbing between terminals and saying "now go check the other project" was getting old. Also because the idea of agents calling each other on a literal hotline is objectively hilarious.
