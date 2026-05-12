---
name: gws-youtube
description: This skill should be used when the user asks to "clean up my youtube playlists", "list my youtube playlists", "dedupe my playlists", "remove video from playlist", "add video to playlist", "youtube cleanup", "youtube channel playlists", "merge playlists", "find duplicate playlists", or mentions YouTube playlist management. Manages YouTube playlists (list, dedupe analysis, add/remove items) via the gws plugin's bash primitives, reusing the active gws account's OAuth client. Reach for this instead of constructing raw YouTube Data API calls or writing one-off Python scripts.
when_to_use: |
  Use whenever the user wants to inspect or modify YouTube playlists they
  own — listing playlists, listing items, adding a video, removing an item,
  or building a higher-level cleanup workflow (dedupe by name, find
  cross-playlist overlap, consolidate singletons, delete empties). Respects
  the active gws account set by the gws-account skill.
argument-hint: <login|logout|playlists|items|add|remove> [flags]
allowed-tools: 'Bash(bash *) Bash(jq *) Bash(curl *) Bash(python3 *)'
---

# YouTube (gws)

Manage the authenticated user's YouTube playlists via bash primitives in
`plugins/gws/scripts/youtube-*.sh`. All operations resolve the active gws
account via `account-common.sh` and read `client_secret.json` from that
account's config dir. Tokens persist as `<account-dir>/youtube_credentials.json`
mode 0600 (plaintext, matching the gws plugin's bash-script convention).

## Prerequisites

Confirm the user is authenticated for YouTube on the active account:

```bash
test -f "$(jq -r '.' <(bash ${CLAUDE_SKILL_DIR}/../../scripts/account-current.sh --json) 2>/dev/null | jq -r '.config_dir // empty')/youtube_credentials.json" \
  && echo "youtube credentials present" \
  || echo "NOT AUTHENTICATED — run: bash ${CLAUDE_SKILL_DIR}/../../scripts/youtube-login.sh"
```

If not authenticated, run `youtube-login.sh` first (PKCE + loopback flow,
opens a browser tab on macOS/Linux).

## GCP API Enable (one-time, gnarly)

The OAuth flow succeeds before this matters, but the FIRST data-API call
will fail with HTTP 403 `accessNotConfigured` until YouTube Data API v3 is
enabled on the GCP project tied to the gws OAuth client. The error
message contains the project number and a direct enable URL. Extract it
and show it to the user verbatim:

```
https://console.developers.google.com/apis/api/youtube.googleapis.com/overview?project=<PROJECT_NUMBER>
```

After the user clicks "Enable" and waits ~30 seconds, retry the call.
This is a one-time setup per GCP project, not per account.

## Primitives

All scripts share the same flag conventions:

- `--account=LABEL` — override the active gws account
- `--json` — machine-readable output (default: human table)
- `--force-refresh` — refresh access token before the API call (testing aid)
- `--help` — usage text

Mutating scripts (`add`, `remove`) additionally support:

- `--yes` / `-y` — skip the interactive `[y/N]` confirmation prompt
- `--dry-run` — print the plan; make no destructive API call

### Auth lifecycle

```bash
# Authenticate (writes <account-dir>/youtube_credentials.json mode 0600)
bash ${CLAUDE_SKILL_DIR}/../../scripts/youtube-login.sh \
  [--account=LABEL] [--force] [--json] [--no-browser]

# Clear credentials when done with YouTube ops (idempotent)
bash ${CLAUDE_SKILL_DIR}/../../scripts/youtube-logout.sh \
  [--account=LABEL | --all-accounts] [--json]
```

The cleanup advisory is important: **after a session of playlist ops,
run `youtube-logout.sh` to remove the persisted refresh token.** Always
suggest this when wrapping up a multi-step workflow.

### Read primitives

```bash
# List playlists owned by the authenticated user
bash ${CLAUDE_SKILL_DIR}/../../scripts/youtube-list-playlists.sh \
  [--account=LABEL] [--json] [--max=N] [--force-refresh]
# Returns: id, title, itemCount, privacyStatus, publishedAt

# List items in a playlist
bash ${CLAUDE_SKILL_DIR}/../../scripts/youtube-list-items.sh <playlist-id> \
  [--account=LABEL] [--json] [--max=N] [--force-refresh]
# Returns: playlistItemId, videoId, title, position, publishedAt
```

`itemCount` from `playlists.list` is authoritative — use it to verify
pagination correctness when listing items.

### Mutating primitives

```bash
# Add a video to a playlist (dedupe-aware by default)
bash ${CLAUDE_SKILL_DIR}/../../scripts/youtube-add-item.sh \
  <playlist-id> <video-id> \
  [--yes] [--dry-run] [--allow-duplicate] [--json]
# Returns status: "added" | "skipped_duplicate" | "dry_run"
# On "added": JSON includes playlistItemId (capture for later removal)

# Remove an item from a playlist by playlistItemId (NOT videoId)
bash ${CLAUDE_SKILL_DIR}/../../scripts/youtube-remove-item.sh \
  <playlist-item-id> \
  [--yes] [--dry-run] [--json]
# Returns status: "deleted" | "already_absent" | "dry_run"
# Idempotent: missing items are treated as success, no error
```

**Footgun:** `playlistItemId` and `videoId` are different. Each appearance
of the same video in any playlist has a distinct `playlistItemId`. Always
capture the `playlistItemId` from `add-item` output if a later remove
might be needed.

## Workflows

### Inventory + dedupe analysis (read-only first)

Before suggesting any destructive operation, build a complete picture in
JSON. This costs one quota unit per playlist plus one per page of items:

```bash
# 1. Snapshot all playlists
bash ${CLAUDE_SKILL_DIR}/../../scripts/youtube-list-playlists.sh --json > /tmp/yt_playlists.json

# 2. Snapshot items for each playlist (loop in jq + bash)
jq -r '.[].id' /tmp/yt_playlists.json | while read -r pid; do
  bash ${CLAUDE_SKILL_DIR}/../../scripts/youtube-list-items.sh "$pid" --json \
    | jq --arg pid "$pid" 'map(. + {playlistId: $pid})'
done | jq -s 'add' > /tmp/yt_items.json
```

From those two files, surface (using jq, not new API calls):

- **Duplicate-name groups**: `jq 'group_by(.title) | map(select(length>1))'`
- **Empty playlists**: `jq 'map(select(.itemCount==0))'`
- **Within-playlist video dupes**: `jq 'group_by(.playlistId, .videoId) | map(select(length>1))'`
- **Cross-playlist overlap**: a video appearing in multiple playlists

**Never propose deletes until the user has reviewed the analysis output.**

### Acting on the analysis (mutating, paired)

For merges (move videos from playlist A → playlist B before deleting A):

```bash
# For each video in source not in destination, add it. Capture results.
# Always use --dry-run first to print the plan, then re-run with --yes.
bash youtube-add-item.sh "$DST" "$VID" --dry-run
bash youtube-add-item.sh "$DST" "$VID" --yes --json
```

For removing within-playlist duplicates, use the second occurrence's
`playlistItemId` from the items snapshot — keep the first instance.

### Idempotency notes

- `add-item` is dedupe-aware: re-running on an already-present video
  exits 0 with `status:"skipped_duplicate"`. Safe to retry.
- `remove-item` is idempotent: removing an already-absent item exits 0
  with `status:"already_absent"`. Safe to retry.
- Both surface API errors clearly with `--json` for programmatic chaining.

## Token refresh

Access tokens expire after ~1 hour. `youtube-common.sh` handles 401 →
refresh → retry transparently for `yt_authorized_curl` callers. The
mutating scripts replicate this pattern for POST/DELETE. Force a refresh
manually with `--force-refresh` (useful when debugging token issues; it
will overwrite `expires_at` in the credentials file with a fresh value).

## Common error patterns

| HTTP | reason | meaning |
|---|---|---|
| 401 | `unauthorized` | token expired; auto-refresh fires once |
| 403 | `accessNotConfigured` | YouTube Data API v3 not enabled on GCP project |
| 403 | `quotaExceeded` | daily quota (10k units) exhausted |
| 404 | `playlistNotFound` | playlist private/deleted or wrong account |
| 404 | `videoNotFound` | video private/deleted (or typo in id) |
| 404 | `playlistItemNotFound` | the item id is wrong, or another caller deleted it |
| 400 | `Invalid Value` | malformed id (wrong length/charset) |

When surfacing API errors to the user, quote the `error.message` field
verbatim from the JSON response — Google's text is precise and links to
their docs.

## When to escalate

- **User wants to manage YouTube channels they don't own** — not supported
  by these primitives (all use `mine=true` or `id=<owned-item>`).
- **User wants to upload, edit, or transcribe videos** — out of scope; that's
  a different API surface (videos, captions). File a beads task.
- **User wants unattended automation** — current design re-prompts via
  `--yes` in non-TTY contexts and persists a plaintext refresh token.
  For unattended runs, escalate the encryption decision before proceeding.

## File map

```
plugins/gws/scripts/
├── youtube-common.sh           # sourced helper (auth, refresh, curl wrapper)
├── youtube-login.sh            # OAuth 2.0 + PKCE loopback flow
├── youtube-logout.sh           # remove persisted credentials (idempotent)
├── youtube-list-playlists.sh   # read-only: list owned playlists
├── youtube-list-items.sh       # read-only: list items in a playlist
├── youtube-add-item.sh         # MUTATING: add video (dedupe-aware)
└── youtube-remove-item.sh      # DESTRUCTIVE: remove item by playlistItemId
```
