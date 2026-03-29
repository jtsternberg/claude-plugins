---
name: hotline-pickup
description: "Introspect the current workspace and cache a concise identity. Used by hotline-dial for workspace resolution. Run with --fresh to force re-introspection."
---

# Hotline: Pickup — Workspace Identity

Generate a concise identity for this workspace so other agents can find and understand it.

## When This Runs

- Automatically during `hotline-dial` workspace resolution (if identity is stale or missing)
- Manually when a user or agent wants to refresh the workspace identity

## Script Paths

Resolve plugin paths first:

```bash
eval "$(bash scripts/paths.sh)"
```

This sets `HOTLINE_PICKUP_SCRIPTS` (and others). Use `$HOTLINE_PICKUP_SCRIPTS` in all script references below.

## Steps

### 1. Check Cache Freshness

Run:

```bash
bash "$HOTLINE_PICKUP_SCRIPTS/identity-cache.sh" is-stale
```

- Exit 0 (stale or missing): proceed to introspection (Step 2)
- Exit 1 (fresh): read and return the cached identity, skip to Step 5

If the caller passed `--fresh`, skip this check and always proceed to Step 2.

### 2. Introspect the Workspace

Gather information from these sources (skip any that don't exist):

1. **CLAUDE.md / AGENTS.md** — Project description, purpose, key directories
2. **Package files** — `package.json`, `Gemfile`, `composer.json`, `Cargo.toml`, `go.mod`, `pyproject.toml` — for tech stack and project name
3. **README.md** — Project overview (first ~50 lines is enough)
4. **Recent git log** — `git log --oneline -10` — what kind of work happens here

### 3. Synthesize Identity

From the gathered information, create:

- **name**: A short, recognizable project name (e.g., "Acme Marketing Site")
- **description**: 1-2 sentences max. What this workspace IS and what it DOES. Keep it concise — this is for quick matching, not a full dossier.
- **tags**: 3-8 short keywords covering tech stack, domain, and purpose (e.g., `["nextjs", "marketing", "blog", "typescript"]`)

### 4. Write Cache

Build the identity JSON with `jq` (safe for descriptions containing quotes or special characters):

```bash
jq -n \
  --arg name "<NAME>" \
  --arg desc "<DESCRIPTION>" \
  --argjson tags '["tag1","tag2","tag3"]' \
  --argjson gen "$(date +%s)" \
  '{identity: {name: $name, description: $desc, tags: $tags, generated: $gen}}' \
  | bash "$HOTLINE_PICKUP_SCRIPTS/identity-cache.sh" write
```

Then validate the write succeeded:

```bash
bash "$HOTLINE_PICKUP_SCRIPTS/identity-cache.sh" read | jq -e '.identity.name and .identity.description' > /dev/null
```

If validation fails, rewrite with corrected values.

### 5. Return the Identity

Output the identity name and description so the caller knows what was cached.

Example output:
> Identity cached for **Acme Marketing Site**: "Company marketing website. Next.js app with landing pages, blog, and contact forms."
