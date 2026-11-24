---
name: sessions-find
description: "Find the past Claude Code session where something happened — 'find the session where we X', 'which session did we clone/build/fix Y in', 'where did we do those PRs'. Returns session id, date, cwd, and a resume command."
---

# Find a past session

Transcripts live at `<config-dir>/projects/<cwd-slug>/<session-id>.jsonl`, where the config dirs are `$CLAUDE_CONFIG_DIR` (default `~/.claude`) and each dir in `AGENT_CLAUDE_CONFIG_DIRS` (colon-separated, e.g. a second account). Grep them directly — semantic search (mempalace) misses exact events like a clone or PR.

1. List files that mention the key term, then count evidence per file (clone command, `gh pr create`, PR URLs, etc.):
   ```bash
   { printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; printf '%s\n' "${AGENT_CLAUDE_CONFIG_DIRS:-}" | tr ':' '\n'; } \
     | while IFS= read -r d; do [ -n "$d" ] && [ -d "$d/projects" ] && (cd -P "$d/projects" && pwd -P); done \
     | awk '!seen[$0]++' \
     | while IFS= read -r root; do grep -rl --include='*.jsonl' -i '<term>' "$root"; done \
     > "${TMPDIR:-/tmp}/sessions-find-hits.txt"
   ```
   Roots are resolved first so a `projects/` symlinked to another account's is searched once.
   If `graveyard` is on PATH, also run `graveyard search '<term>' --full-text --json` (hits: `sessions[]` plus `workspaces[].sessions[]` with `matched: true`). It covers buried sessions, often ones whose JSONL is gone; resume those with `graveyard resurrect <session_id>`. "No session transport is reachable" means skipped, not zero hits.
2. For each hit, get its first `"timestamp"` and its `"cwd"`, and grep for the specific event.
3. List every real hit, best match first: session id, date, cwd, what happened there, how it differs from the others (e.g. a fork/resume copy with identical evidence, or a later session that only mentions it), and `cd <cwd> && claude --resume <id>` (prefix `CLAUDE_CONFIG_DIR=<dir>` when the hit came only from a non-default config dir).
4. Nothing found? If `mempalace` is on PATH, try `mempalace search '<what happened>'` and report what it recalls as context. A `Source: <session-id>.jsonl` hit resumes with `claude --resume` if that JSONL still exists, or `graveyard resurrect <session-id>` if it's buried.

Gotchas:
- Project folders start with `-` (`-Users-<name>-…`). Pass paths as `./-Users-…` or grep reads them as flags and silently matches nothing.
- The session's cwd is often NOT the repo it touched. Search all projects, not just the repo's slug.
- Your own session (and a hotline caller's) will match. Drop them.
- grep here is ugrep: long bounded classes like `[^"]{0,150}` fail with "exceeds complexity limits". Keep them ≤ ~80.
- Transcripts don't say who authored a PR. Confirm with `gh pr list --state all` in the repo.
