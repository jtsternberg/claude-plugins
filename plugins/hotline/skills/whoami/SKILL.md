---
name: hotline-whoami
description: "Identifies the current workspace's dirmap slug. Use when the agent needs caller ID for hotline calls, or to check if a workspace is registered in the directory map."
argument-hint: "[path]"
allowed-tools: Bash
---

# Hotline: Who Am I?

Find out what this workspace is called in dirmap — your caller ID on the hotline.

## Usage

Run with no arguments to identify the current workspace, or pass a path:

```bash
/hotline-whoami
/hotline-whoami /path/to/some/workspace
```

## Steps

### 1. Resolve the Path

```
TARGET_PATH="$1 or $(pwd)"
TARGET_PATH=$(realpath "$TARGET_PATH")
```

### 2. Look Up the Slug

**If `dirmap` is in PATH:**

```bash
dirmap identify "$TARGET_PATH"
```

**If `dirmap` is NOT in PATH**, use the fallback — search `~/.dirmap.json` for a matching path:

```bash
jq -r --arg path "$TARGET_PATH" 'to_entries[] | select(.value == $path) | .key' ~/.dirmap.json | head -1
```

### 3. Report

If found:
> This workspace is registered as **$SLUG** in dirmap.

If not found:
> This workspace isn't registered in dirmap. Use `/hotline-add-contact <slug>` to register it so other agents can find it.
