---
name: gmail-read
description: "Search and read Gmail via gws — 'find the email about X', 'search my inbox for', read a message's full body as plain text."
when_to_use: |
  Also 'read the email from <sender>', 'show me the message where …', 'pull that email about X'.
argument-hint: '["<gmail search query>"] [--id <messageId>] [--limit N] [--body] [--account LABEL|EMAIL] [--pretty]'
allowed-tools: 'Bash(gws *) Bash(bash *) Bash(python3 *)'
---

# Gmail Read

Search Gmail with a query, or fetch a single message by id, and get structured
results back — subject, from, date, snippet, and optionally the full plain-text
body (HTML stripped).

This skill only reads. It never sends, modifies labels, marks as read, or
deletes. For composing, see the sibling `gmail-draft-from-markdown` skill.

## Prerequisites

```!
# Codex: replace the fallback with the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-<absolute path to this gws plugin directory>}"
bash "$PLUGIN_ROOT/scripts/auth-preflight.sh"
```

## Task

Run the entrypoint script, passing all arguments through:

```bash
# Codex: replace the fallback with the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR:-<absolute path to this gmail-read skill directory>}"
bash "$SKILL_DIR/scripts/read.sh" $ARGUMENTS
```

If no arguments were provided, ask the user what to search for (subject
keywords, sender, date range, etc.). Gmail search operators are supported
verbatim (e.g. `from:hello@ollama.com newer_than:7d`).

## Arguments

| Arg | Required | Notes |
|---|---|---|
| `"<query>"` | one of query or `--id` | Any Gmail search string. Use quotes. |
| `--id <messageId>` | one of query or `--id` | Fetch a single message directly. |
| `--limit N` | no | Max results in search mode (default 10). |
| `--body` | no | In search mode, also fetch each message's body. Slower — one extra API call per hit. |
| `--account LABEL\|EMAIL` | no | Override active gws account (accepts an account label or its email). Errors if no account matches. |
| `--pretty` | no | Human-readable output instead of JSON. |

## Behavior

### Search mode

1. `gws gmail users messages list` with the query and `maxResults=limit`.
2. For each message id, fetch headers + snippet (and body if `--body`).
3. Emit one JSON object per line (NDJSON) so downstream tools can stream.

Each JSON object has:
```json
{
  "id": "...",
  "threadId": "...",
  "subject": "...",
  "from": "...",
  "to": "...",
  "date": "...",
  "snippet": "...",
  "body": "..."          // only present with --body
}
```

With `--pretty`, prints a readable list instead (id, subject, from, date,
snippet, then body if fetched).

### Fetch mode (`--id`)

Emits a single JSON object with all fields including `body`, or a pretty
block with `--pretty`.

### Body extraction

- Walks the MIME tree, prefers `text/plain`.
- If only `text/html` is present, strips tags naively (Python `re`) and
  collapses whitespace. Not a full HTML→text renderer — good enough for
  quickly reading a marketing email or a plain formatted reply, not for
  reproducing complex layouts.
- Attachments are ignored.

## Examples

```bash
# Codex: replace the fallback with the directory containing this SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR:-<absolute path to this gmail-read skill directory>}"
# Find the Ollama 0.31 announcement
bash "$SKILL_DIR/scripts/read.sh" "Ollama 0.31 Gemma 4 MTP"

# Same, but also pull the body so you can quote it back
bash "$SKILL_DIR/scripts/read.sh" "Ollama 0.31" --body --pretty

# Fetch one specific message
bash "$SKILL_DIR/scripts/read.sh" --id 19f1c3e1f903f72f --pretty

# Standard Gmail operators work
bash "$SKILL_DIR/scripts/read.sh" "from:hello@ollama.com newer_than:60d" --limit 20

# Read from a specific account (not the active one)
bash "$SKILL_DIR/scripts/read.sh" "invoice" --account me@jtsternberg.com
```

## Troubleshooting

- **Auth expired (`invalid_grant`):** Re-authenticate that account. For the
  active account, run `gws auth login`; for a `--account` override, switch to
  it first via the `gws:account` skill, then re-auth.
- **Wrong account:** `gws auth status` shows the active account. Override
  per-call with `--account EMAIL`, or switch globally via the `gws:account`
  skill.
- **No results:** Try broader operators (`newer_than:1y`, drop the sender
  filter). Gmail search is exact-match on many operators.
- **Body looks like HTML soup:** The stripper is naive. For complex
  templates, pass `--id` and inspect specific parts, or fall back to `gws
  gmail users messages get --params '{"format":"raw",...}'` and decode
  manually.

## Why this skill exists

Reading a Gmail message via the raw API is 2–3 tool calls plus base64-
decoding and MIME walking. This skill collapses that to one invocation with
sensible defaults — search + summarize by default, or grab a single message
end-to-end with `--id --pretty`.
