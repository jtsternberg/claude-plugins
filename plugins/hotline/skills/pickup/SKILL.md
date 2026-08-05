---
name: hotline-pickup
description: "Generate and cache this workspace's identity for hotline-dial resolution."
disable-model-invocation: true
argument-hint: "[--fresh]"
allowed-tools: Bash
---

# Hotline: Pickup — Workspace Identity

Generate a concise identity for this workspace so other agents can find and understand it.

## When This Runs

- Automatically during `hotline-dial` workspace resolution (if identity is stale or missing)
- Manually when a user or agent wants to refresh the workspace identity

## Script Paths

Every independent shell block below resolves the Hotline plugin path and loads
`HOTLINE_PICKUP_SCRIPTS` in that same shell. Shell state does not persist across
tool calls. Under Codex, replace `${CLAUDE_PLUGIN_ROOT}` with the Hotline plugin
directory before running a block.

## Steps

### 1. Check Cache Freshness

Run:

```bash
# Codex: replace ${CLAUDE_PLUGIN_ROOT} below with the Hotline plugin directory.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
eval "$(bash "$PLUGIN_ROOT/scripts/paths.sh")"
bash "$HOTLINE_PICKUP_SCRIPTS/identity-cache.sh" is-stale
```

- Exit 0 (stale or missing): proceed to introspection (Step 2)
- Exit 1 (fresh): read and return the cached identity, skip to Step 5

If the caller passed `--fresh`, skip this check and always proceed to Step 2.

### 2. Introspect the Workspace

Run the introspection script to gather project metadata:

```bash
# Codex: replace ${CLAUDE_PLUGIN_ROOT} below with the Hotline plugin directory.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
eval "$(bash "$PLUGIN_ROOT/scripts/paths.sh")"
bash "$HOTLINE_PICKUP_SCRIPTS/gather-workspace-info.sh"
```

This collects CLAUDE.md, package files, README excerpt, recent git log, and tech stack signals, returning structured JSON. Use this data to synthesize the identity in Step 3.

### 3. Synthesize Identity

From the gathered information, create:

- **name**: A short, recognizable project name (e.g., "Acme Marketing Site")
- **description**: 1-2 sentences max. What this workspace IS and what it DOES. Keep it concise — this is for quick matching, not a full dossier.
- **tags**: 3-8 short keywords covering tech stack, domain, and purpose (e.g., `["nextjs", "marketing", "blog", "typescript"]`)

### 4. Write Cache

Build the identity JSON with `jq` (safe for descriptions containing quotes or special characters):

```bash
# Codex: replace ${CLAUDE_PLUGIN_ROOT} below with the Hotline plugin directory.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
eval "$(bash "$PLUGIN_ROOT/scripts/paths.sh")"
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
# Codex: replace ${CLAUDE_PLUGIN_ROOT} below with the Hotline plugin directory.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
eval "$(bash "$PLUGIN_ROOT/scripts/paths.sh")"
bash "$HOTLINE_PICKUP_SCRIPTS/identity-cache.sh" read | jq -e '.identity.name and .identity.description' > /dev/null
```

If validation fails, rewrite with corrected values.

### 5. Return the Identity

Output the identity name and description so the caller knows what was cached.

Example output:
> Identity cached for **Acme Marketing Site**: "Company marketing website. Next.js app with landing pages, blog, and contact forms."
