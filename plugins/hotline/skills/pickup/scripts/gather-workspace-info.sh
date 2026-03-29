#!/usr/bin/env bash
# =============================================================================
# Gather Workspace Info: Collect project metadata for identity synthesis
#
# Examines CLAUDE.md, package files, README, and git history to produce
# structured JSON that the pickup skill uses to synthesize an identity.
#
# Usage:
#   gather-workspace-info.sh [--cwd /path]
#   gather-workspace-info.sh --help
#
# Output: JSON on stdout with collected workspace metadata
# =============================================================================
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: gather-workspace-info.sh [--cwd /path]"
  echo ""
  echo "Collects workspace metadata (CLAUDE.md, package files, README, git log)"
  echo "and outputs structured JSON for identity synthesis."
  exit 0
fi

CWD="$(pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="$2"; shift 2 ;;
    *) shift ;;
  esac
done

cd "$CWD"

# Helper: read first N lines of a file if it exists
read_file_head() {
  local file="$1"
  local lines="${2:-50}"
  if [[ -f "$file" ]]; then
    head -n "$lines" "$file" 2>/dev/null || true
  fi
}

# Collect CLAUDE.md / AGENTS.md
CLAUDE_MD=""
for f in CLAUDE.md AGENTS.md .claude/CLAUDE.md; do
  if [[ -f "$f" ]]; then
    CLAUDE_MD=$(read_file_head "$f" 80)
    break
  fi
done

# Collect package file info (name, description, tech stack signals)
PACKAGE_INFO=""
if [[ -f "package.json" ]]; then
  PACKAGE_INFO=$(jq -r '{name: .name, description: .description, deps: (.dependencies // {} | keys[:10]), devDeps: (.devDependencies // {} | keys[:10])}' package.json 2>/dev/null || true)
elif [[ -f "composer.json" ]]; then
  PACKAGE_INFO=$(jq -r '{name: .name, description: .description, type: .type}' composer.json 2>/dev/null || true)
elif [[ -f "Cargo.toml" ]]; then
  PACKAGE_INFO=$(grep -E '^(name|description|version)' Cargo.toml | head -5 || true)
elif [[ -f "pyproject.toml" ]]; then
  PACKAGE_INFO=$(grep -E '^(name|description|version)' pyproject.toml | head -5 || true)
elif [[ -f "go.mod" ]]; then
  PACKAGE_INFO=$(head -3 go.mod || true)
elif [[ -f "Gemfile" ]]; then
  PACKAGE_INFO=$(head -10 Gemfile || true)
fi

# Collect README excerpt
README=""
for f in README.md README.rst README.txt README; do
  if [[ -f "$f" ]]; then
    README=$(read_file_head "$f" 30)
    break
  fi
done

# Collect recent git log
GIT_LOG=""
if git rev-parse --is-inside-work-tree &>/dev/null; then
  GIT_LOG=$(git log --oneline -10 2>/dev/null || true)
fi

# Detect tech stack from file presence
TECH_SIGNALS=""
[[ -f "package.json" ]] && TECH_SIGNALS="${TECH_SIGNALS}node,"
[[ -f "tsconfig.json" ]] && TECH_SIGNALS="${TECH_SIGNALS}typescript,"
[[ -f "next.config.js" || -f "next.config.mjs" || -f "next.config.ts" ]] && TECH_SIGNALS="${TECH_SIGNALS}nextjs,"
[[ -f "vite.config.ts" || -f "vite.config.js" ]] && TECH_SIGNALS="${TECH_SIGNALS}vite,"
[[ -f "composer.json" ]] && TECH_SIGNALS="${TECH_SIGNALS}php,"
[[ -f "wp-config.php" || -f "style.css" && -f "functions.php" ]] && TECH_SIGNALS="${TECH_SIGNALS}wordpress,"
[[ -f "Gemfile" ]] && TECH_SIGNALS="${TECH_SIGNALS}ruby,"
[[ -f "Cargo.toml" ]] && TECH_SIGNALS="${TECH_SIGNALS}rust,"
[[ -f "go.mod" ]] && TECH_SIGNALS="${TECH_SIGNALS}go,"
[[ -f "pyproject.toml" || -f "setup.py" || -f "requirements.txt" ]] && TECH_SIGNALS="${TECH_SIGNALS}python,"
[[ -f "Dockerfile" || -f "docker-compose.yml" ]] && TECH_SIGNALS="${TECH_SIGNALS}docker,"
[[ -f ".claude/settings.json" || -f "CLAUDE.md" ]] && TECH_SIGNALS="${TECH_SIGNALS}claude-code,"
TECH_SIGNALS="${TECH_SIGNALS%,}"  # trim trailing comma

# Build output JSON
jq -n \
  --arg claude_md "$CLAUDE_MD" \
  --arg package_info "$PACKAGE_INFO" \
  --arg readme "$README" \
  --arg git_log "$GIT_LOG" \
  --arg tech "$TECH_SIGNALS" \
  --arg cwd "$CWD" \
  '{
    workspace: $cwd,
    claude_md: $claude_md,
    package_info: $package_info,
    readme: $readme,
    recent_git_log: $git_log,
    tech_signals: ($tech | split(",") | map(select(. != "")))
  }'
