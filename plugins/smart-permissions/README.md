# smart-permissions

AI-powered permission hook for Claude Code that auto-approves safe operations and auto-denies dangerous ones, reducing manual permission prompts.

## Architecture

Two-layer system designed for speed and safety:

### Layer 1 — PreToolUse (fast, ~5ms)
Deterministic bash regex rules that run on every tool call. No LLM involved.
- **Always-allow**: Read-only tools (Read, Glob, Grep, etc.), safe bash commands (ls, git, npm test, etc.)
- **Always-deny**: Dangerous operations (rm -rf /, sudo, curl|bash, etc.)
- **Passthrough**: Anything ambiguous produces no output, falling through to Layer 2

### Layer 2 — PermissionRequest (slow, ~8-10s)
AI fallback using Claude Haiku. Only fires when Layer 1 didn't decide and a permission dialog would appear anyway.
- Loads `permission-policy.md` as the evaluation ruleset
- Fail-open: if anything breaks (missing deps, timeout, parse error), shows normal dialog
- Recursion-safe: guards against infinite loops via env checks

## Installation

```bash
claude plugins add ~/gits/bvdr/claude-plugins --path plugins/smart-permissions
```

## Requirements

- `jq` — JSON parsing (required for both layers)
- `claude` CLI — AI evaluation in Layer 2 (optional; Layer 1 works without it)

## What Gets Auto-Allowed (Layer 1)

**Tools**: Read, Glob, Grep, WebSearch, WebFetch, LS, ListDirectory, TodoRead, TaskList, TaskGet, TaskCreate, TaskUpdate, ToolSearch, AskUserQuestion

**Bash commands**:
- Read-only: `ls`, `cat`, `head`, `tail`, `wc`, `file`, `which`, `pwd`, `date`, `echo`, `stat`, `tree`, `du`, `df`
- Search: `grep`, `rg`, `find`, `fd`, `ag`
- Git: all `git` commands
- GitHub: all `gh` commands
- Testing: `npm test`, `pytest`, `jest`, `cargo test`, `go test`, `make test`
- Building: `npm run build`, `cargo build`, `go build`, `make`
- Linting: `eslint`, `prettier`, `black`, `rustfmt`
- Dev servers: `npm start`, `npm run dev`
- Docker read-only: `docker ps`, `docker images`, `docker logs`, `docker inspect`
- Version checks: `--version`, `-v`
- Compilers: `gcc`, `clang`, `tsc`, `rustc`, `javac`
- JSON: `jq`

## What Gets Auto-Denied (Layer 1)

- `rm -rf /`, `rm -rf ~`, or system paths
- `sudo` / `su`
- `curl | bash`, `wget | sh`
- `chmod 777`, recursive chmod on system paths
- `dd if=... of=/dev/`
- `mkfs`
- Fork bombs
- `networksetup`, `iptables`, `ufw`
- Modifying `~/.ssh/`, `~/.gnupg/`

## Customization

Edit `permission-policy.md` to adjust the AI evaluation rules for Layer 2. This file defines what the LLM considers GREEN (allow) and RED (deny) when evaluating ambiguous commands.

## Debug Logging

Layer 1 logging (high frequency — gated behind env var):
```bash
export SMART_PERMISSIONS_DEBUG=1
```

Layer 2 logging (low frequency — always on):
```bash
tail -f ~/.claude/hooks/smart-permissions.log
```

## Compatibility

Composes with `interactive-notifications`: smart-permissions runs first. If it decides (allow/deny), the event is resolved. If it passes through, interactive-notifications shows the macOS dialog as fallback.
