---
name: pickup
description: "Introspect the current workspace and cache a concise identity. Used by hotline:dial for workspace resolution. Run with --fresh to force re-introspection."
---

# Hotline: Pickup — Workspace Identity

Generate a concise identity for this workspace so other agents can find and understand it.

## When This Runs

- Automatically during `hotline:dial` workspace resolution (if identity is stale or missing)
- Manually when a user or agent wants to refresh the workspace identity

## Script Paths

- `PICKUP_SCRIPTS` = the `scripts/` directory within this skill (`skills/pickup/scripts/`)

## Steps

### 1. Check Cache Freshness

Run:

```bash
bash "PICKUP_SCRIPTS/identity-cache.sh" is-stale
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

Write the identity JSON to the cache:

```bash
echo '{"identity":{"name":"<NAME>","description":"<DESCRIPTION>","tags":["tag1","tag2"],"generated":'$(date +%s)'}}' \
  | bash "PICKUP_SCRIPTS/identity-cache.sh" write
```

Replace `<NAME>`, `<DESCRIPTION>`, and tags with the synthesized values. Ensure the JSON is valid.

### 5. Return the Identity

Output the identity name and description so the caller knows what was cached.

Example output:
> Identity cached for **Acme Marketing Site**: "Company marketing website. Next.js app with landing pages, blog, and contact forms."
