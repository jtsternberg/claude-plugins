---
name: hotline-add-contact
description: "Register a workspace in dirmap so other agents can find it via hotline-dial. Use when a workspace needs to be added to the directory map for cross-workspace communication."
---

# Hotline: Add Contact

Register a workspace in dirmap so it can be found by `hotline-dial` during workspace resolution.

## Arguments

- **$1** (slug): The short name/alias for this workspace (e.g., `blog`, `coaching`, `frontend`). If not provided, ask the user.
- **$2** (path): The workspace path to register. Defaults to the current working directory if not provided.

## Steps

### 1. Determine Slug and Path

```
SLUG="$1 or ask the user"
TARGET_PATH="$2 or $(pwd)"
```

If no slug was provided, ask the user:
> What slug should I register this workspace under? (e.g., "blog", "coaching", "frontend")

Resolve the path to its canonical form:
```bash
TARGET_PATH=$(realpath "$TARGET_PATH")
```

### 2. Check for Existing Entry

Before adding, check if this slug already exists:

```bash
dirmap get "$SLUG" 2>/dev/null || dirmap-fallback.sh get "$SLUG" 2>/dev/null
```

If it exists and points to a different path, confirm with the user:
> "$SLUG" is already registered at `/existing/path`. Overwrite with `$TARGET_PATH`?

### 3. Register the Workspace

```bash
if command -v dirmap >/dev/null 2>&1; then
  dirmap add "$SLUG" "$TARGET_PATH"
elif [[ ! -f "$HOME/.dirmap.json" ]]; then
  jq -n --arg slug "$SLUG" --arg path "$TARGET_PATH" \
    '{($slug): $path}' > "$HOME/.dirmap.json"
else
  jq --arg slug "$SLUG" --arg path "$TARGET_PATH" \
    '. + {($slug): $path}' "$HOME/.dirmap.json" > "$HOME/.dirmap.json.tmp" \
    && mv "$HOME/.dirmap.json.tmp" "$HOME/.dirmap.json"
fi
```

### 4. Confirm

> Registered **$SLUG** → `$TARGET_PATH`. Other agents can now find this workspace with `hotline-dial`.
