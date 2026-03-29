# Hotline Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Claude Code plugin enabling cross-workspace communication between Claude instances via headless CLI with optional CMUX visibility.

**Architecture:** Single plugin (`hotline`) with three skills (`dial`, `ringing`, `pickup`) and shared bash scripts. Headless `claude -p` + `--resume` as core transport, CMUX for deep conference calls. State stored in `~/.agents-hotline/`. Session identity via transcript fingerprinting.

**Tech Stack:** Bash scripts, Claude Code plugin system (SKILL.md + plugin.json), `jq` for JSON, `claude` CLI headless mode, optional CMUX integration.

**Spec:** `docs/superpowers/specs/2026-03-28-hotline-design.md`

---

### Task 1: Plugin Scaffold

Create the plugin directory structure, metadata, and register in marketplace.

**Files:**
- Create: `plugins/hotline/.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Create plugin.json**

```json
{
  "name": "hotline",
  "description": "Cross-workspace Claude Code communication. Dial another workspace to ask questions, delegate work, or collaborate in real-time.",
  "version": "0.1.0",
  "author": {
    "name": "JT Sternberg",
    "url": "https://github.com/jtsternberg"
  }
}
```

Write to `plugins/hotline/.claude-plugin/plugin.json`.

- [ ] **Step 2: Register in marketplace.json**

Add to the `plugins` array in `.claude-plugin/marketplace.json`:

```json
{ "name": "hotline", "source": "./plugins/hotline" }
```

- [ ] **Step 3: Create empty directory structure**

```bash
mkdir -p plugins/hotline/skills/dial/scripts
mkdir -p plugins/hotline/skills/dial/references
mkdir -p plugins/hotline/skills/ringing
mkdir -p plugins/hotline/skills/pickup/scripts
mkdir -p plugins/hotline/scripts
# Note: no goto-fallback.sh — nothing uses it. Add later if needed.
```

- [ ] **Step 4: Commit**

```bash
git add plugins/hotline/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "feat(hotline): scaffold plugin structure and register in marketplace"
```

---

### Task 2: Session Fingerprint Scripts

Adapt the tested `bin/session-fingerprint` and `bin/session-discover` scripts into the plugin's `scripts/` directory. Update `session-fingerprint.sh` to use exit codes + stderr per the spec (exit 0 + stdout = cache hit, exit 1 + stderr = cache miss).

**Files:**
- Create: `plugins/hotline/scripts/session-fingerprint.sh`
- Create: `plugins/hotline/scripts/session-discover.sh`
- Reference: `bin/session-fingerprint` (existing, tested)
- Reference: `bin/session-discover` (existing, tested)

- [ ] **Step 1: Create session-fingerprint.sh**

Adapt from `bin/session-fingerprint` with these changes:
- Add `set -euo pipefail`
- On cache hit: exit 0, write session ID to stdout
- On cache miss: exit 1, write fingerprint to stderr (not stdout)
- Remove `--raw` flag (no longer needed — stdout/stderr separation handles it)
- Keep the PID walking logic and `/tmp/claude-session-<pid>` cache

```bash
#!/usr/bin/env bash
# =============================================================================
# Session Fingerprint: Discover your own Claude Code session ID
#
# Cache hit:  exits 0, writes session ID to stdout
# Cache miss: exits 1, writes fingerprint to stderr
#             (caller must run session-discover.sh in a subsequent tool call)
#
# Cache is keyed by the claude parent PID, stored in /tmp/claude-session-<pid>.
#
# Usage:
#   session-fingerprint.sh          # Returns session ID or plants fingerprint
# =============================================================================
set -euo pipefail

# Find the claude process in our ancestry
CLAUDE_PID=""
pid=$$
while [[ "$pid" != "1" && -n "$pid" ]]; do
  comm=$(ps -o comm= -p "$pid" 2>/dev/null | xargs)
  if [[ "$comm" == "claude" ]]; then
    CLAUDE_PID="$pid"
    break
  fi
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
done

if [[ -z "$CLAUDE_PID" ]]; then
  echo "Error: Could not find claude process in ancestry" >&2
  exit 2
fi

CACHE_FILE="/tmp/claude-session-${CLAUDE_PID}"

# Cache hit — return session ID on stdout, exit 0
if [[ -f "$CACHE_FILE" ]]; then
  cat "$CACHE_FILE"
  exit 0
fi

# Cache miss — plant fingerprint on stderr, exit 1
FINGERPRINT="SESSION_FINGERPRINT_$(uuidgen)"
echo "$FINGERPRINT" >&2
exit 1
```

- [ ] **Step 2: Create session-discover.sh**

Adapt from `bin/session-discover` with these changes:
- Add `set -euo pipefail`
- On success: write session ID to stdout, exit 0
- Remove `--raw` flag
- Keep the PID walking + cache write logic

```bash
#!/usr/bin/env bash
# =============================================================================
# Session Discover: Find session ID by grepping for a planted fingerprint
#
# Searches the 5 most recent transcript files (newest first) for the given
# fingerprint. The transcript filename IS the session ID. Caches result so
# future session-fingerprint.sh calls return instantly.
#
# Usage:
#   session-discover.sh SESSION_FINGERPRINT_XXXXXXXX
# =============================================================================
set -euo pipefail

FINGERPRINT="${1:-}"

if [[ -z "$FINGERPRINT" ]]; then
  echo "Usage: session-discover.sh <fingerprint>" >&2
  exit 1
fi

PROJECT_DIR="$HOME/.claude/projects/$(pwd | sed 's|/|-|g')"

if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "Error: No transcript directory found at $PROJECT_DIR" >&2
  exit 1
fi

TRANSCRIPT=""
for f in $(ls -t "$PROJECT_DIR"/*.jsonl 2>/dev/null | head -5); do
  if grep -q "$FINGERPRINT" "$f"; then
    TRANSCRIPT="$f"
    break
  fi
done

if [[ -z "$TRANSCRIPT" ]]; then
  echo "Error: Fingerprint not found in recent transcripts" >&2
  exit 1
fi

SESSION_ID=$(basename "$TRANSCRIPT" .jsonl)

# Cache for future session-fingerprint.sh calls
CLAUDE_PID=""
pid=$$
while [[ "$pid" != "1" && -n "$pid" ]]; do
  comm=$(ps -o comm= -p "$pid" 2>/dev/null | xargs)
  if [[ "$comm" == "claude" ]]; then
    CLAUDE_PID="$pid"
    break
  fi
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
done

if [[ -n "$CLAUDE_PID" ]]; then
  echo "$SESSION_ID" > "/tmp/claude-session-${CLAUDE_PID}"
fi

echo "$SESSION_ID"
```

- [ ] **Step 3: Make scripts executable**

```bash
chmod +x plugins/hotline/scripts/session-fingerprint.sh
chmod +x plugins/hotline/scripts/session-discover.sh
```

- [ ] **Step 4: Test session-fingerprint.sh manually**

Run from within a Claude Code session:

```bash
bash plugins/hotline/scripts/session-fingerprint.sh
echo "Exit code: $?"
```

Expected first run: exit 1, fingerprint on stderr.

Then in a second tool call:

```bash
bash plugins/hotline/scripts/session-discover.sh <fingerprint-from-stderr>
echo "Exit code: $?"
```

Expected: exit 0, session ID on stdout.

Then verify cache:

```bash
bash plugins/hotline/scripts/session-fingerprint.sh
echo "Exit code: $?"
```

Expected: exit 0, session ID on stdout (cached).

- [ ] **Step 5: Commit**

```bash
git add plugins/hotline/scripts/session-fingerprint.sh plugins/hotline/scripts/session-discover.sh
git commit -m "feat(hotline): add session fingerprint discovery scripts

Two-step session ID discovery: plant fingerprint, grep transcripts.
Cache hit: exit 0 + stdout. Cache miss: exit 1 + stderr.
Solves claude-code#25642, #13733, #17188."
```

---

### Task 3: Dirmap Fallback Scripts

Create minimal `dirmap` and `goto` fallback scripts that read/write `~/.dirmap.json`. These are only used when the user's full `dirmap` command isn't in PATH.

**Files:**
- Create: `plugins/hotline/scripts/dirmap-fallback.sh`
- Reference: `~/.dirmap.json` (simple `{"key": "/path"}` JSON)

- [ ] **Step 1: Create dirmap-fallback.sh**

Supports: `get <id>`, `list` (JSON output). Reads `~/.dirmap.json`.

```bash
#!/usr/bin/env bash
# =============================================================================
# Minimal dirmap fallback — used when full dirmap is not in PATH
#
# Only supports: get <id>, list
# Reads from ~/.dirmap.json (same format as full dirmap tool)
#
# Usage:
#   dirmap-fallback.sh get <id>    # Print path for project ID
#   dirmap-fallback.sh list        # Print all entries as JSON
# =============================================================================
set -euo pipefail

DIRMAP_FILE="$HOME/.dirmap.json"

if [[ ! -f "$DIRMAP_FILE" ]]; then
  echo "Error: $DIRMAP_FILE not found" >&2
  exit 1
fi

CMD="${1:-}"
case "$CMD" in
  get)
    ID="${2:-}"
    if [[ -z "$ID" ]]; then
      echo "Usage: dirmap-fallback.sh get <id>" >&2
      exit 1
    fi
    RESULT=$(jq -r --arg id "$ID" '.[$id] // empty' "$DIRMAP_FILE")
    if [[ -z "$RESULT" ]]; then
      echo "Error: No entry for '$ID'" >&2
      exit 1
    fi
    echo "$RESULT"
    ;;
  list)
    jq -r '.' "$DIRMAP_FILE"
    ;;
  *)
    echo "Usage: dirmap-fallback.sh <get|list> [id]" >&2
    exit 1
    ;;
esac
```

- [ ] **Step 2: Make executable and test**

```bash
chmod +x plugins/hotline/scripts/dirmap-fallback.sh
bash plugins/hotline/scripts/dirmap-fallback.sh list | head -5
bash plugins/hotline/scripts/dirmap-fallback.sh get dotfiles
```

- [ ] **Step 3: Commit**

```bash
git add plugins/hotline/scripts/dirmap-fallback.sh
git commit -m "feat(hotline): add dirmap fallback script for users without full dirmap"
```

---

### Task 4: Identity Cache Scripts (pickup support)

Create `identity-cache.sh` for the `pickup` skill — reads, writes, and checks TTL of workspace identity JSON files in `~/.agents-hotline/identities/`.

**Files:**
- Create: `plugins/hotline/skills/pickup/scripts/identity-cache.sh`

- [ ] **Step 1: Create identity-cache.sh**

Supports: `read`, `write`, `is-stale`, `path`. Uses workspace path hash as filename. Resolves canonical paths via `realpath`.

```bash
#!/usr/bin/env bash
# =============================================================================
# Identity Cache: Read/write workspace identity JSON
#
# Stores identities in ~/.agents-hotline/identities/<path-hash>.json
# TTL default: 24 hours. Override with HOTLINE_IDENTITY_TTL_HOURS env var.
#
# Usage:
#   identity-cache.sh read [--cwd /path]        # Read cached identity (stdout)
#   identity-cache.sh write [--cwd /path]        # Write identity from stdin
#   identity-cache.sh is-stale [--cwd /path]     # Exit 0 if stale/missing, 1 if fresh
#   identity-cache.sh path [--cwd /path]          # Print cache file path
# =============================================================================
set -euo pipefail

IDENTITIES_DIR="$HOME/.agents-hotline/identities"
TTL_HOURS="${HOTLINE_IDENTITY_TTL_HOURS:-24}"
TTL_SECONDS=$((TTL_HOURS * 3600))

# Parse --cwd flag, default to current directory
CWD="$(pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    read|write|is-stale|path) CMD="$1"; shift ;;
    *) shift ;;
  esac
done

# Canonical path — resolve symlinks
CANONICAL=$(realpath "$CWD" 2>/dev/null || echo "$CWD")

# Hash the canonical path for the filename
PATH_HASH=$(echo -n "$CANONICAL" | shasum -a 256 | cut -c1-16)
CACHE_FILE="${IDENTITIES_DIR}/${PATH_HASH}.json"

mkdir -p "$IDENTITIES_DIR"

case "${CMD:-}" in
  read)
    if [[ -f "$CACHE_FILE" ]]; then
      cat "$CACHE_FILE"
    else
      echo "{}"
    fi
    ;;
  write)
    cat > "$CACHE_FILE"
    ;;
  is-stale)
    if [[ ! -f "$CACHE_FILE" ]]; then
      exit 0  # Missing = stale
    fi
    GENERATED=$(jq -r '.identity.generated // 0' "$CACHE_FILE")
    NOW=$(date +%s)
    AGE=$((NOW - GENERATED))
    if [[ $AGE -ge $TTL_SECONDS ]]; then
      exit 0  # Stale
    fi
    exit 1    # Fresh
    ;;
  path)
    echo "$CACHE_FILE"
    ;;
  *)
    echo "Usage: identity-cache.sh <read|write|is-stale|path> [--cwd /path]" >&2
    exit 1
    ;;
esac
```

- [ ] **Step 2: Make executable and test**

```bash
chmod +x plugins/hotline/skills/pickup/scripts/identity-cache.sh

# Test write
echo '{"identity":{"name":"Test","description":"A test workspace","tags":["test"],"generated":'$(date +%s)'}}' \
  | bash plugins/hotline/skills/pickup/scripts/identity-cache.sh write --cwd /tmp/test-workspace

# Test read
bash plugins/hotline/skills/pickup/scripts/identity-cache.sh read --cwd /tmp/test-workspace

# Test is-stale (should be fresh = exit 1)
bash plugins/hotline/skills/pickup/scripts/identity-cache.sh is-stale --cwd /tmp/test-workspace
echo "Exit: $?"  # Expected: 1

# Test path
bash plugins/hotline/skills/pickup/scripts/identity-cache.sh path --cwd /tmp/test-workspace
```

- [ ] **Step 3: Commit**

```bash
git add plugins/hotline/skills/pickup/scripts/identity-cache.sh
git commit -m "feat(hotline): add identity cache script with TTL and canonical path hashing"
```

---

### Task 5: Session Cache Script

Create `session-cache.sh` for tracking Agent A's outgoing connections to other workspaces.

**Files:**
- Create: `plugins/hotline/skills/dial/scripts/session-cache.sh`

- [ ] **Step 1: Create session-cache.sh**

Supports: `get <target-path>`, `set <target-path>`, `list`. Keyed by caller's canonical path hash.

```bash
#!/usr/bin/env bash
# =============================================================================
# Session Cache: Track Agent A's outgoing connections
#
# Stores session maps in ~/.agents-hotline/sessions/<caller-hash>.json
# Keyed by Agent A's session ID to prevent collisions.
#
# Usage:
#   session-cache.sh get <target-path> --caller-session <id>
#   session-cache.sh set <target-path> --caller-session <id> --session <id> --mode <mode>
#   session-cache.sh update <target-path> --caller-session <id>
#   session-cache.sh list --caller-session <id>
# =============================================================================
set -euo pipefail

SESSIONS_DIR="$HOME/.agents-hotline/sessions"
mkdir -p "$SESSIONS_DIR"

CMD="${1:-}"
shift || true

# Parse flags
TARGET=""
CALLER_SESSION=""
SESSION_ID=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --caller-session) CALLER_SESSION="$2"; shift 2 ;;
    --session) SESSION_ID="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    *) [[ -z "$TARGET" ]] && TARGET="$1"; shift ;;
  esac
done

if [[ -z "$CALLER_SESSION" ]]; then
  echo "Error: --caller-session required" >&2
  exit 1
fi

# Use caller session ID as cache filename (unique per agent instance)
CACHE_FILE="${SESSIONS_DIR}/${CALLER_SESSION}.json"

# Resolve target to canonical path
if [[ -n "$TARGET" ]]; then
  TARGET=$(realpath "$TARGET" 2>/dev/null || echo "$TARGET")
fi

case "$CMD" in
  get)
    if [[ -z "$TARGET" ]]; then
      echo "Usage: session-cache.sh get <target-path> --caller-session <id>" >&2
      exit 1
    fi
    if [[ ! -f "$CACHE_FILE" ]]; then
      exit 1  # No cache
    fi
    RESULT=$(jq -r --arg t "$TARGET" '.connections[$t] // empty' "$CACHE_FILE")
    if [[ -z "$RESULT" ]]; then
      exit 1  # No entry for this target
    fi
    echo "$RESULT"
    ;;
  set)
    if [[ -z "$TARGET" || -z "$SESSION_ID" || -z "$MODE" ]]; then
      echo "Usage: session-cache.sh set <target> --caller-session <id> --session <id> --mode <mode>" >&2
      exit 1
    fi
    NOW=$(date +%s)
    CALLER_CWD=$(realpath "$(pwd)" 2>/dev/null || pwd)
    # Create or update the cache file
    if [[ -f "$CACHE_FILE" ]]; then
      jq --arg t "$TARGET" --arg s "$SESSION_ID" --arg m "$MODE" --argjson now "$NOW" \
        '.connections[$t] = {session_id: $s, started: $now, last_contact: $now, mode: $m, exchange_count: 1}' \
        "$CACHE_FILE" > "${CACHE_FILE}.tmp" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
    else
      jq -n --arg caller "$CALLER_CWD" --arg cs "$CALLER_SESSION" \
        --arg t "$TARGET" --arg s "$SESSION_ID" --arg m "$MODE" --argjson now "$NOW" \
        '{caller: $caller, caller_session_id: $cs, connections: {($t): {session_id: $s, started: $now, last_contact: $now, mode: $m, exchange_count: 1}}}' \
        > "$CACHE_FILE"
    fi
    ;;
  update)
    if [[ -z "$TARGET" || ! -f "$CACHE_FILE" ]]; then
      exit 1
    fi
    NOW=$(date +%s)
    jq --arg t "$TARGET" --argjson now "$NOW" \
      '.connections[$t].last_contact = $now | .connections[$t].exchange_count += 1' \
      "$CACHE_FILE" > "${CACHE_FILE}.tmp" && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
    ;;
  list)
    if [[ -f "$CACHE_FILE" ]]; then
      cat "$CACHE_FILE"
    else
      echo "{}"
    fi
    ;;
  *)
    echo "Usage: session-cache.sh <get|set|update|list> [target] --caller-session <id>" >&2
    exit 1
    ;;
esac
```

- [ ] **Step 2: Make executable and test**

```bash
chmod +x plugins/hotline/skills/dial/scripts/session-cache.sh

# Test set
bash plugins/hotline/skills/dial/scripts/session-cache.sh set /tmp/target-workspace \
  --caller-session test-session-123 --session remote-session-456 --mode quick_call

# Test get
bash plugins/hotline/skills/dial/scripts/session-cache.sh get /tmp/target-workspace \
  --caller-session test-session-123

# Test update
bash plugins/hotline/skills/dial/scripts/session-cache.sh update /tmp/target-workspace \
  --caller-session test-session-123

# Test list
bash plugins/hotline/skills/dial/scripts/session-cache.sh list --caller-session test-session-123

# Cleanup
rm -f ~/.agents-hotline/sessions/test-session-123.json
```

- [ ] **Step 3: Commit**

```bash
git add plugins/hotline/skills/dial/scripts/session-cache.sh
git commit -m "feat(hotline): add session cache script for tracking outgoing connections"
```

---

### Task 6: Workspace Resolution Script

Create `resolve-workspace.sh` — the resolution chain from spec: raw path -> session ID -> dirmap ID -> fuzzy match -> ask user.

**Files:**
- Create: `plugins/hotline/skills/dial/scripts/resolve-workspace.sh`

- [ ] **Step 1: Create resolve-workspace.sh**

Outputs the resolved canonical workspace path to stdout. Exits 1 if unresolvable (caller should ask user).

```bash
#!/usr/bin/env bash
# =============================================================================
# Resolve Workspace: Turn a fuzzy reference into a canonical workspace path
#
# Resolution chain:
#   1. Raw path (starts with / or ~) → validate exists
#   2. UUID → look up in session cache
#   3. Dirmap ID → dirmap get <id>
#   4. Fuzzy match → dirmap list + identity scan
#
# Exits 0 with path on stdout, or exits 1 with candidates on stderr.
#
# Usage:
#   resolve-workspace.sh <reference> [--caller-session <id>]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_SCRIPTS="$(cd "$SCRIPT_DIR/../../.." && pwd)/scripts"

REFERENCE="${1:-}"
shift || true

CALLER_SESSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --caller-session) CALLER_SESSION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$REFERENCE" ]]; then
  echo "Error: No workspace reference provided" >&2
  exit 1
fi

# Helper: resolve and validate a path
resolve_path() {
  local p="$1"
  # Expand tilde
  p="${p/#\~/$HOME}"
  local canonical
  canonical=$(realpath "$p" 2>/dev/null || echo "")
  if [[ -n "$canonical" && -d "$canonical" ]]; then
    echo "$canonical"
    return 0
  fi
  return 1
}

# 1. Raw path?
if [[ "$REFERENCE" == /* || "$REFERENCE" == ~* ]]; then
  if resolve_path "$REFERENCE"; then
    exit 0
  fi
  echo "Error: Path does not exist: $REFERENCE" >&2
  exit 1
fi

# 2. UUID? (session ID lookup)
UUID_REGEX='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
if [[ "$REFERENCE" =~ $UUID_REGEX && -n "$CALLER_SESSION" ]]; then
  # Search session cache for this session ID as a target
  SESSIONS_DIR="$HOME/.agents-hotline/sessions"
  if [[ -f "${SESSIONS_DIR}/${CALLER_SESSION}.json" ]]; then
    MATCH=$(jq -r --arg sid "$REFERENCE" \
      '[.connections | to_entries[] | select(.value.session_id == $sid) | .key] | first // empty' \
      "${SESSIONS_DIR}/${CALLER_SESSION}.json")
    if [[ -n "$MATCH" ]]; then
      echo "$MATCH"
      exit 0
    fi
  fi
fi

# 3. Dirmap ID?
DIRMAP_CMD=""
if command -v dirmap &>/dev/null; then
  DIRMAP_CMD="dirmap"
elif [[ -x "$PLUGIN_SCRIPTS/dirmap-fallback.sh" ]]; then
  DIRMAP_CMD="$PLUGIN_SCRIPTS/dirmap-fallback.sh"
fi

if [[ -n "$DIRMAP_CMD" ]]; then
  DIRMAP_RESULT=$($DIRMAP_CMD get "$REFERENCE" 2>/dev/null || true)
  if [[ -n "$DIRMAP_RESULT" ]]; then
    if resolve_path "$DIRMAP_RESULT"; then
      exit 0
    fi
  fi
fi

# 4. Fuzzy match — dump dirmap entries + identities as JSON for the agent to pick
# The calling agent (Claude) is much better at fuzzy matching than bash regex.
# We just provide the structured data and let the agent decide.
if [[ -n "$DIRMAP_CMD" ]]; then
  IDENTITIES_DIR="$HOME/.agents-hotline/identities"
  DIRMAP_JSON=$($DIRMAP_CMD list 2>/dev/null || echo "{}")

  # Build an enriched candidates list: dirmap name, path, + identity if cached
  echo "$DIRMAP_JSON" | jq -r --arg idir "$IDENTITIES_DIR" '
    to_entries | map({
      id: .key,
      path: .value,
      identity: (
        (.value | gsub("/"; "-") | ltrimstr("-")) as $hash_input |
        ($hash_input | @base64) as $_ |
        null  # identity lookup happens below
      )
    })
  ' > /dev/null 2>&1  # jq can't do file I/O, so we do it in bash

  # Build candidates JSON with identity enrichment
  CANDIDATES="[]"
  while IFS=$'\t' read -r name path; do
    CANONICAL=$(realpath "$path" 2>/dev/null || echo "$path")
    PATH_HASH=$(echo -n "$CANONICAL" | shasum -a 256 | cut -c1-16)
    IDENTITY_FILE="${IDENTITIES_DIR}/${PATH_HASH}.json"
    IDENTITY="{}"
    if [[ -f "$IDENTITY_FILE" ]]; then
      IDENTITY=$(jq '.identity // {}' "$IDENTITY_FILE")
    fi
    CANDIDATES=$(echo "$CANDIDATES" | jq --arg n "$name" --arg p "$path" --argjson id "$IDENTITY" \
      '. + [{id: $n, path: $p, identity: $id}]')
  done < <(echo "$DIRMAP_JSON" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')

  if [[ $(echo "$CANDIDATES" | jq 'length') -gt 0 ]]; then
    echo "$CANDIDATES" >&2
    exit 1  # Caller (agent) picks the best match from candidates
  fi
fi

# Nothing matched
echo "Error: Could not resolve '$REFERENCE'" >&2
exit 1
```

- [ ] **Step 2: Make executable and test**

```bash
chmod +x plugins/hotline/skills/dial/scripts/resolve-workspace.sh

# Test raw path
bash plugins/hotline/skills/dial/scripts/resolve-workspace.sh /tmp

# Test dirmap ID
bash plugins/hotline/skills/dial/scripts/resolve-workspace.sh dotfiles

# Test fuzzy (should work if dirmap has entries)
bash plugins/hotline/skills/dial/scripts/resolve-workspace.sh coaching
```

- [ ] **Step 3: Commit**

```bash
git add plugins/hotline/skills/dial/scripts/resolve-workspace.sh
git commit -m "feat(hotline): add workspace resolution with dirmap + identity fuzzy matching"
```

---

### Task 7: CMUX Detection and Transport Scripts

Create `check-cmux.sh` for detecting CMUX availability and `cmux-call.sh` for the CMUX transport.

**Files:**
- Create: `plugins/hotline/skills/dial/scripts/check-cmux.sh`
- Create: `plugins/hotline/skills/dial/scripts/cmux-call.sh`
- Create: `plugins/hotline/skills/dial/scripts/headless-call.sh`

- [ ] **Step 1: Create check-cmux.sh**

```bash
#!/usr/bin/env bash
# =============================================================================
# Check CMUX: Detect if CMUX is available
#
# Exits 0 if cmux is available and responsive, 1 otherwise.
# =============================================================================
set -euo pipefail

if ! command -v cmux &>/dev/null; then
  exit 1
fi

# Verify cmux is actually running (not just installed)
cmux ping &>/dev/null || exit 1
exit 0
```

- [ ] **Step 2: Create headless-call.sh**

Wrapper for `claude -p` that handles first contact (no session) vs follow-up (with `--resume`). Extracts session ID from JSON output.

```bash
#!/usr/bin/env bash
# =============================================================================
# Headless Call: Send a prompt to a workspace via claude -p
#
# Usage:
#   headless-call.sh --cwd <path> --prompt <text> [--resume <session-id>]
#
# First contact: uses claude -p with --output-format json, extracts session_id
# Follow-up: uses --resume with existing session ID
#
# Outputs JSON: {"session_id": "...", "response": "..."}
# =============================================================================
set -euo pipefail

CWD=""
PROMPT=""
RESUME_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --resume) RESUME_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$PROMPT" ]]; then
  echo '{"error": "No prompt provided"}' >&2
  exit 1
fi

STDERR_FILE=$(mktemp)
trap "rm -f $STDERR_FILE" EXIT

if [[ -n "$RESUME_ID" ]]; then
  # Follow-up call — resume existing session
  RESULT=$(claude -p "$PROMPT" --resume "$RESUME_ID" --output-format json 2>"$STDERR_FILE") || true
else
  # First contact — new session
  if [[ -z "$CWD" ]]; then
    echo '{"error": "No --cwd provided for first contact"}' >&2
    exit 1
  fi
  RESULT=$(claude -p "$PROMPT" --cwd "$CWD" --output-format json 2>"$STDERR_FILE") || true
fi

if [[ -z "$RESULT" ]]; then
  STDERR_MSG=$(cat "$STDERR_FILE")
  jq -n --arg err "${STDERR_MSG:-Claude CLI returned no output}" '{error: $err}'
  exit 1
fi

# Extract session_id and response text
SESSION_ID=$(echo "$RESULT" | jq -r '.session_id // empty')
RESPONSE=$(echo "$RESULT" | jq -r '.result // empty')

jq -n --arg sid "$SESSION_ID" --arg resp "$RESPONSE" \
  '{session_id: $sid, response: $resp}'
```

- [ ] **Step 3: Create cmux-call.sh**

CMUX transport for opening a visible workspace and launching Claude with session resume.

```bash
#!/usr/bin/env bash
# =============================================================================
# CMUX Call: Open a workspace in CMUX and launch Claude
#
# Usage:
#   cmux-call.sh --cwd <path> [--resume <session-id>]
#
# Opens a new CMUX workspace at the target path and starts Claude.
# Outputs: {"workspace_id": "...", "message": "..."}
# =============================================================================
set -euo pipefail

CWD=""
RESUME_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --resume) RESUME_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ -z "$CWD" ]]; then
  echo '{"error": "No --cwd provided"}' >&2
  exit 1
fi

# Open workspace in CMUX
WS_OUTPUT=$(cmux new-workspace --cwd "$CWD" 2>/dev/null)
WS_ID=$(echo "$WS_OUTPUT" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || true)

if [[ -z "$WS_ID" ]]; then
  echo '{"error": "Failed to create CMUX workspace"}' >&2
  exit 1
fi

# Launch Claude in the workspace
if [[ -n "$RESUME_ID" ]]; then
  cmux send --workspace "$WS_ID" "claude --resume $RESUME_ID"
else
  cmux send --workspace "$WS_ID" "claude"
fi

jq -n --arg ws "$WS_ID" --arg cwd "$CWD" --arg sid "${RESUME_ID:-new}" \
  '{workspace_id: $ws, cwd: $cwd, session_id: $sid, message: "CMUX workspace opened with Claude session"}'
```

- [ ] **Step 4: Make all executable**

```bash
chmod +x plugins/hotline/skills/dial/scripts/check-cmux.sh
chmod +x plugins/hotline/skills/dial/scripts/headless-call.sh
chmod +x plugins/hotline/skills/dial/scripts/cmux-call.sh
```

- [ ] **Step 5: Commit**

```bash
git add plugins/hotline/skills/dial/scripts/check-cmux.sh \
  plugins/hotline/skills/dial/scripts/headless-call.sh \
  plugins/hotline/skills/dial/scripts/cmux-call.sh
git commit -m "feat(hotline): add transport scripts — headless, CMUX, and detection"
```

---

### Task 8: Dial History Script

Create a script for appending to and reading the dial history JSONL, with the 100-entry cap.

**Files:**
- Create: `plugins/hotline/scripts/dial-history.sh`

- [ ] **Step 1: Create dial-history.sh**

```bash
#!/usr/bin/env bash
# =============================================================================
# Dial History: Append-only log of incoming calls per workspace
#
# Stored as JSONL at ~/.agents-hotline/identities/<hash>.dial_history.jsonl
# Capped at 100 entries — trims oldest on each write.
#
# Usage:
#   dial-history.sh append --cwd <path> --session <id> --caller <path> --mode <mode>
#   dial-history.sh read [--cwd <path>]
# =============================================================================
set -euo pipefail

IDENTITIES_DIR="$HOME/.agents-hotline/identities"
MAX_ENTRIES=100

CMD="${1:-}"
shift || true

CWD="$(pwd)"
SESSION_ID=""
CALLER=""
MODE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    --session) SESSION_ID="$2"; shift 2 ;;
    --caller) CALLER="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

CANONICAL=$(realpath "$CWD" 2>/dev/null || echo "$CWD")
PATH_HASH=$(echo -n "$CANONICAL" | shasum -a 256 | cut -c1-16)
HISTORY_FILE="${IDENTITIES_DIR}/${PATH_HASH}.dial_history.jsonl"

mkdir -p "$IDENTITIES_DIR"

case "$CMD" in
  append)
    if [[ -z "$SESSION_ID" || -z "$CALLER" || -z "$MODE" ]]; then
      echo "Usage: dial-history.sh append --session <id> --caller <path> --mode <mode>" >&2
      exit 1
    fi
    NOW=$(date +%s)
    ENTRY=$(jq -n --arg s "$SESSION_ID" --arg c "$CALLER" --arg m "$MODE" --argjson t "$NOW" \
      '{session_id: $s, caller: $c, mode: $m, timestamp: $t}')
    echo "$ENTRY" >> "$HISTORY_FILE"

    # Trim to MAX_ENTRIES
    LINE_COUNT=$(wc -l < "$HISTORY_FILE" | tr -d ' ')
    if [[ "$LINE_COUNT" -gt "$MAX_ENTRIES" ]]; then
      tail -n "$MAX_ENTRIES" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp"
      mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    fi
    ;;
  read)
    if [[ -f "$HISTORY_FILE" ]]; then
      cat "$HISTORY_FILE"
    fi
    ;;
  *)
    echo "Usage: dial-history.sh <append|read> [options]" >&2
    exit 1
    ;;
esac
```

- [ ] **Step 2: Make executable and commit**

```bash
chmod +x plugins/hotline/scripts/dial-history.sh
git add plugins/hotline/scripts/dial-history.sh
git commit -m "feat(hotline): add dial history JSONL with 100-entry cap"
```

---

### Task 9: The `pickup` Skill (SKILL.md)

Create the SKILL.md that guides Claude through workspace introspection and identity caching.

**Files:**
- Create: `plugins/hotline/skills/pickup/SKILL.md`

- [ ] **Step 1: Write pickup SKILL.md**

```markdown
---
name: pickup
description: Introspect the current workspace and cache a concise identity. Used by hotline:dial for workspace resolution. Run manually with --fresh to force re-introspection.
---

# Hotline: Pickup — Workspace Identity

Generate a concise identity for this workspace so other agents can find and understand it.

## When This Runs

- Automatically during `hotline:dial` workspace resolution (if identity is stale or missing)
- Manually when a user or agent wants to refresh the workspace identity

## Steps

### 1. Check Cache Freshness

`PICKUP_SCRIPTS` refers to the `scripts/` directory within this skill (`skills/pickup/scripts/`).

Run:
```bash
bash "PICKUP_SCRIPTS/identity-cache.sh" is-stale
```

- Exit 0 (stale/missing): proceed to introspection
- Exit 1 (fresh): read and return the cached identity, skip introspection

To force refresh regardless of TTL, the caller passes `--fresh`.

### 2. Introspect the Workspace

Gather information from these sources (skip any that don't exist):

1. **CLAUDE.md / AGENTS.md** — Project description, purpose, key directories
2. **Package files** — `package.json`, `Gemfile`, `composer.json`, `Cargo.toml`, `go.mod`, `pyproject.toml` — for tech stack and project name
3. **README.md** — Project overview
4. **Recent git log** — `git log --oneline -10` — what kind of work happens here

### 3. Synthesize Identity

From the gathered information, create:

- **name**: A short, recognizable project name (e.g., "Acme Marketing Site")
- **description**: 1-2 sentences max. What this workspace IS and what it DOES. This is for quick matching, not a dossier.
- **tags**: 3-8 short keywords covering tech stack, domain, and purpose (e.g., `["nextjs", "marketing", "blog", "typescript"]`)

### 4. Write Cache

Write the identity JSON to the cache:

```bash
echo '{"identity":{"name":"<name>","description":"<description>","tags":<tags>,"generated":'$(date +%s)'}}' \
  | bash "PICKUP_SCRIPTS/identity-cache.sh" write
```

### 5. Return the Identity

Output the identity name and description so the caller knows what was cached.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/hotline/skills/pickup/SKILL.md
git commit -m "feat(hotline): add pickup skill for workspace identity introspection"
```

---

### Task 10: The `ringing` Skill (SKILL.md)

Create the receiver-side handshake skill that primes Agent B with protocol context on first contact.

**Files:**
- Create: `plugins/hotline/skills/ringing/SKILL.md`

- [ ] **Step 1: Write ringing SKILL.md**

```markdown
---
name: ringing
description: "Receiver-side handshake for incoming hotline calls. Primes the agent with communication protocol context. Invoked as /hotline:ringing on first contact from another workspace."
---

# Hotline: Ringing — Incoming Call Protocol

You are receiving a **hotline call** from another Claude Code agent running in a different workspace. This is a cross-workspace communication initiated by the `hotline:dial` skill.

## What's Happening

Another agent (the "caller") needs your help. They've connected to your workspace because you have knowledge, files, or capabilities they need. Your job is to be a helpful collaborator.

## Communication Protocol

### Call Modes

The caller's prompt will indicate the mode. Respond accordingly:

**Quick Call** — The caller needs a quick answer. Read their question, provide a concise response, and you're done. Think phone call, not meeting.

**Work Order** — The caller is delegating a task to you. Acknowledge it, do the work in your workspace, and report back with results. You have full autonomy to read files, run commands, and make changes as needed.

**Conference Call** — The caller wants to collaborate back-and-forth. Expect multiple exchanges. Each follow-up arrives via `--resume` on the same session. Work together iteratively until the task is complete.

### Response Guidelines

- Be concise. The caller is another agent, not a human — skip pleasantries.
- If you're working on a work order, provide a clear status: what you did, what the result was, whether it's complete.
- If you need clarification, ask in your response. The caller will relay to the user if needed.
- If the task is outside your workspace's scope, say so — the caller may have dialed the wrong workspace.

### Completion Signals

- **Quick call**: Your first response completes the call.
- **Work order**: End your response with "WORK COMPLETE" when the delegated task is done, or "WORK IN PROGRESS" if you need another exchange.
- **Conference call**: The caller manages the flow. Just respond to each exchange naturally.

## Logging

After handling the call, log it to the dial history:

```bash
bash "PLUGIN_SCRIPTS/dial-history.sh" append \
  --session "<session-id-from-caller>" \
  --caller "<caller-workspace-path>" \
  --mode "<quick_call|work_order|conference_call>"
```

`PLUGIN_SCRIPTS` refers to the `scripts/` directory at the root of this plugin (sibling to `skills/`).

Extract the caller info from the prompt metadata. If not available, skip logging — it's not critical.

## Now Handle the Call

The caller's prompt follows. Read it, determine the mode, and respond.
```

- [ ] **Step 2: Commit**

```bash
git add plugins/hotline/skills/ringing/SKILL.md
git commit -m "feat(hotline): add ringing skill — receiver-side handshake protocol"
```

---

### Task 11: The `dial` Skill (SKILL.md)

The main orchestration skill. This is the brain of the plugin — the decision tree, transport selection, session management, and execution flow.

**Files:**
- Create: `plugins/hotline/skills/dial/SKILL.md`
- Create: `plugins/hotline/skills/dial/references/dirmap-fallback.md`

- [ ] **Step 1: Write dirmap-fallback.md reference**

```markdown
# Dirmap Fallback

If `dirmap` is not in PATH, use the bundled fallback scripts:

```bash
# List all projects
bash "PLUGIN_DIR/scripts/dirmap-fallback.sh" list

# Get path for a project ID
bash "PLUGIN_DIR/scripts/dirmap-fallback.sh" get <id>
```

These read from `~/.dirmap.json`. To set up dirmap for the first time, create `~/.dirmap.json`:

```json
{
  "my-project": "/path/to/project",
  "another-project": "/path/to/other"
}
```

For the full `dirmap` tool with add/remove/search: https://github.com/jtsternberg/dotfiles
```

- [ ] **Step 2: Write dial SKILL.md**

This is the longest file. It contains the full decision tree and orchestration logic.

```markdown
---
name: dial
description: "Initiate cross-workspace communication with another Claude Code instance. Supports quick calls (Q&A), work orders (delegation), and conference calls (collaboration). Auto-selects transport between headless CLI and CMUX."
---

# Hotline: Dial — Cross-Workspace Communication

Dial another workspace to ask questions, delegate work, or collaborate with another Claude Code instance.

## Prerequisites

Before your first dial in this session, discover your own session ID:

```bash
bash "PLUGIN_SCRIPTS/session-fingerprint.sh"
```

- **Exit 0** (stdout = session ID): You're ready. Store this as `MY_SESSION_ID`.
- **Exit 1** (stderr = fingerprint): Run the discover step in a **separate tool call**:

```bash
bash "PLUGIN_SCRIPTS/session-discover.sh" <fingerprint-from-stderr>
```

This returns your session ID on stdout. Now you're ready to dial.

`PLUGIN_SCRIPTS` refers to the `scripts/` directory at the root of this plugin (sibling to `skills/`).
`DIAL_SCRIPTS` refers to `skills/dial/scripts/` within this plugin.

## Decision Tree

Follow these steps in order. Make decisions silently — only ask the user when genuinely ambiguous.

### Step 1: Resolve Target Workspace

Determine which workspace to call.

**If the user gave a path** (starts with `/` or `~`):
```bash
bash "DIAL_SCRIPTS/resolve-workspace.sh" "/path/to/workspace"
```

**If the user gave a name or fuzzy reference** (e.g., "coaching workspace", "blog"):
```bash
bash "DIAL_SCRIPTS/resolve-workspace.sh" "coaching" --caller-session "$MY_SESSION_ID"
```

- Exit 0 + stdout = resolved canonical path. Proceed.
- Exit 1 + stderr = candidates or error. Present candidates to user and ask them to pick.

**If the user gave a session ID** (UUID):
```bash
bash "DIAL_SCRIPTS/resolve-workspace.sh" "66aa358b-..." --caller-session "$MY_SESSION_ID"
```

### Step 2: Determine Mode

Based on what you need from the other workspace:

| Need | Mode | Behavior |
|------|------|----------|
| A quick answer to a question | **Quick Call** | Single exchange, headless |
| Work done asynchronously | **Work Order** | Delegate, poll for completion |
| Back-and-forth collaboration | **Conference Call** | Multiple exchanges |

If you're not sure which mode fits, ask the user:
> "Should I just ask them a quick question, delegate this as a work order, or set up a back-and-forth collaboration?"

### Step 3: Select Transport (Automatic)

**Do not ask the user about transport. Decide silently.**

- Quick call → **Headless** (always)
- Work order → **Headless** (always)
- Conference call:
  - Estimate 2-3 exchanges → **Headless**
  - Estimate deep collaboration →
    ```bash
    bash "DIAL_SCRIPTS/check-cmux.sh"
    ```
    - Exit 0 → **CMUX**
    - Exit 1 → **Headless**

### Step 4: Check for Existing Session

```bash
bash "DIAL_SCRIPTS/session-cache.sh" get "$TARGET_PATH" --caller-session "$MY_SESSION_ID"
```

- Exit 0 + stdout = existing session JSON. Extract `session_id` and use `--resume`.
- Exit 1 = no existing session. Will create new on first contact.

### Step 5: Execute the Call

#### First Contact (No Existing Session)

**Headless:**
```bash
bash "DIAL_SCRIPTS/headless-call.sh" --cwd "$TARGET_PATH" \
  --prompt "/hotline:ringing [MODE: quick_call|work_order|conference_call] $YOUR_PROMPT"
```

Parse the JSON response to get `session_id` and `response`.

Cache the session:
```bash
bash "DIAL_SCRIPTS/session-cache.sh" set "$TARGET_PATH" \
  --caller-session "$MY_SESSION_ID" \
  --session "$REMOTE_SESSION_ID" \
  --mode "$MODE"
```

**CMUX (conference call only):**
```bash
bash "DIAL_SCRIPTS/cmux-call.sh" --cwd "$TARGET_PATH"
```

Then interact via `cmux send` and `cmux read-screen`.

#### Follow-Up (Existing Session)

**Headless:**
```bash
bash "DIAL_SCRIPTS/headless-call.sh" --prompt "$YOUR_MESSAGE" --resume "$REMOTE_SESSION_ID"
```

Update the session cache:
```bash
bash "DIAL_SCRIPTS/session-cache.sh" update "$TARGET_PATH" --caller-session "$MY_SESSION_ID"
```

### Step 6: Report to User

**Always surface the session ID on first response from the target:**

> Connected to **[workspace name]** (session: `[session-id]`).
>
> If you want to take over this conversation at any point, let me know and I'll give you the command to resume it in another terminal.
>
> **Their response:** [response text]

On subsequent exchanges, just relay the response without repeating the session ID.

### Step 7: Adaptive Escalation (Conference Calls)

If you started a conference call in headless mode and the exchange count grows past 3:

1. Check CMUX availability: `bash "DIAL_SCRIPTS/check-cmux.sh"`
2. If available:
   ```bash
   bash "DIAL_SCRIPTS/cmux-call.sh" --cwd "$TARGET_PATH" --resume "$REMOTE_SESSION_ID"
   ```
3. Announce: "This conversation is getting lengthy. I've opened a CMUX window to continue it."
4. Switch to CMUX transport for remaining exchanges.

### Takeover

If the user asks to take over the conversation:

> Run this in another terminal to take over:
> ```
> claude --resume [session-id]
> ```
> Let me know when you're done and I'll reconnect to see what happened.

When they come back, resume the session to read the final state:
```bash
bash "DIAL_SCRIPTS/headless-call.sh" --prompt "Summarize what happened in this session since I last checked in." \
  --resume "$REMOTE_SESSION_ID"
```

## Identity Resolution

If the target workspace's identity cache is stale or missing during resolution, trigger the pickup skill:

```bash
# Check if identity is stale
bash "PICKUP_SCRIPTS/identity-cache.sh" is-stale --cwd "$TARGET_PATH"
```

If stale (exit 0), you'll need to run a quick headless call to trigger pickup:
```bash
bash "DIAL_SCRIPTS/headless-call.sh" --cwd "$TARGET_PATH" \
  --prompt "/hotline:pickup"
```

This populates the identity cache for future resolution.
```

- [ ] **Step 3: Commit**

```bash
git add plugins/hotline/skills/dial/SKILL.md plugins/hotline/skills/dial/references/dirmap-fallback.md
git commit -m "feat(hotline): add dial skill — the main orchestration brain

Decision tree, transport selection, session management, takeover flow.
The core of the hotline plugin."
```

---

### Task 12: README

Write the plugin README with install instructions, usage, session ID discovery promotion, and roadmap.

**Files:**
- Create: `plugins/hotline/README.md`

- [ ] **Step 1: Write README.md**

Cover these sections:
1. **Headline** — What hotline does, one paragraph
2. **Session ID Discovery** — Promoted prominently as a standalone feature. Explain the problem (no `CLAUDE_SESSION_ID` env var), the solution (fingerprint method), and symlink instructions for global use
3. **Installation** — `claude plugins add /path/to/plugins/hotline`
4. **Usage** — Examples of quick call, work order, and conference call from the user's perspective
5. **Dirmap Setup** — How to create `~/.dirmap.json` for workspace resolution, link to full dirmap tool
6. **CMUX Integration** — Optional, auto-detected, what it adds
7. **Configuration** — `HOTLINE_IDENTITY_TTL_HOURS` env var
8. **How It Works** — Brief architecture overview
9. **Roadmap** — Hybrid protocol (Approach 3), non-Claude agent support

- [ ] **Step 2: Commit**

```bash
git add plugins/hotline/README.md
git commit -m "feat(hotline): add README with session ID discovery promo and usage docs"
```

---

### Task 13: Version Bump and Final Polish

Bump version, verify plugin installs, clean up.

**Files:**
- Modify: `plugins/hotline/.claude-plugin/plugin.json` (version bump if needed)

- [ ] **Step 1: Verify plugin structure**

```bash
find plugins/hotline -type f | sort
```

Confirm all files are present per the spec's plugin structure.

- [ ] **Step 2: Test plugin install**

```bash
claude plugins add /Users/JT/Code/claude-plugins/plugins/hotline
```

Verify it installs without errors.

- [ ] **Step 3: Test a quick call end-to-end**

In a Claude session with the plugin installed:
1. Say "dial my dotfiles workspace and ask what shell config it manages"
2. Verify the decision tree runs, workspace resolves, headless call executes
3. Verify session ID is surfaced on first response

- [ ] **Step 4: Final commit**

```bash
git add -A plugins/hotline/
git commit -m "feat(hotline): v0.1.0 — cross-workspace Claude Code communication

Dial another workspace to ask questions, delegate work, or collaborate.
Three skills: dial (caller), ringing (receiver handshake), pickup (identity).
Headless-first transport with CMUX visibility for deep collaboration.
Session fingerprint discovery solves claude-code#25642, #13733, #17188."
```
