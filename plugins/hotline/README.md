# Hotline

**Cross-workspace communication for Claude Code agents.**

Your agents finally have a phone. And unlike your last phone upgrade, this one actually comes with useful new features.

Hotline lets one Claude Code workspace call another — ask a question, delegate a task, or collaborate in real-time. No copy-pasting between terminals. No "hey can you check the other project and tell me..." followed by you manually doing the checking. Just agent-to-agent communication, like nature intended.

---

## Bonus: Session ID Discovery

Hotline includes a standalone session ID discovery utility — a running Claude agent can discover its own session ID, something Claude Code doesn't expose natively. The community has been [asking for this](https://github.com/anthropics/claude-code/issues/25642) for a while.

**[Full docs and usage: SESSION-ID-DISCOVERY.md](SESSION-ID-DISCOVERY.md)**

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
