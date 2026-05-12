#!/usr/bin/env bash
# Remove an item from a YouTube playlist by playlistItemId.
#
# DESTRUCTIVE. Pre-flights with playlistItems.list to confirm the item exists
# and to surface what's about to be deleted (title + playlistId) in the
# confirmation prompt.
#
# Usage:
#   youtube-remove-item.sh <playlist-item-id>
#   youtube-remove-item.sh <playlist-item-id> --yes        # skip TTY confirm
#   youtube-remove-item.sh <playlist-item-id> --dry-run    # print plan, no call
#   youtube-remove-item.sh <playlist-item-id> --json
#   youtube-remove-item.sh <playlist-item-id> --account=LABEL
#   youtube-remove-item.sh <playlist-item-id> --force-refresh
#
# Note: playlistItemId is the **item** id (returned by list-items / add-item),
# NOT the video id. The same video can appear in many playlists; each has a
# distinct playlistItemId.
#
# Exit codes:
#   0  success (deleted, or already absent)
#   1  API/network/auth failure
#   2  bad usage / cancelled at prompt
#
# JSON output shape:
#   {"status":"deleted", "playlistItemId":"...", "wasIn":{"playlistId":"...","title":"..."}}
#   {"status":"already_absent", "playlistItemId":"..."}
#   {"status":"dry_run", "plan":{...}}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=youtube-common.sh
source "$SCRIPT_DIR/youtube-common.sh"

YT_ACCOUNT_OVERRIDE=""
JSON=0
YES=0
DRY=0
FORCE_REFRESH=0
ITEM_ID=""
for arg in "$@"; do
  case "$arg" in
    --account=*)     YT_ACCOUNT_OVERRIDE="${arg#--account=}";;
    --json)          JSON=1;;
    --yes|-y)        YES=1;;
    --dry-run)       DRY=1;;
    --force-refresh) FORCE_REFRESH=1;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0;;
    --*)
      echo "youtube-remove-item.sh: unknown flag '$arg'" >&2; exit 2;;
    *)
      if [[ -n "$ITEM_ID" ]]; then
        echo "youtube-remove-item.sh: extra positional arg '$arg'" >&2; exit 2
      fi
      ITEM_ID="$arg";;
  esac
done
export YT_ACCOUNT_OVERRIDE

if [[ -z "$ITEM_ID" ]]; then
  echo "youtube-remove-item.sh: usage: <playlist-item-id> [flags]" >&2
  echo "  Get a playlistItemId from youtube-list-items.sh or youtube-add-item.sh." >&2
  exit 2
fi

yt_require_jq

if [[ $FORCE_REFRESH -eq 1 ]]; then
  yt_refresh_access_token >&2 || exit 1
  echo "(refreshed access token)" >&2
fi

# --- Pre-flight: confirm item exists + capture context for confirmation -----
IID_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$ITEM_ID")"
CHECK_URL="https://www.googleapis.com/youtube/v3/playlistItems?part=snippet&id=$IID_ENC&maxResults=1"
CHECK_RESP="$(yt_authorized_curl "$CHECK_URL")" || {
  echo "youtube-remove-item.sh: pre-flight lookup failed:" >&2
  echo "$CHECK_RESP" >&2
  exit 1
}
CHECK_ERR="$(echo "$CHECK_RESP" | jq -r '.error.message // empty')"
if [[ -n "$CHECK_ERR" ]]; then
  echo "youtube-remove-item.sh: API error during pre-flight: $CHECK_ERR" >&2
  echo "$CHECK_RESP" | jq . >&2
  exit 1
fi

FOUND_TITLE="$(echo "$CHECK_RESP" | jq -r '.items[0].snippet.title // empty')"
FOUND_PLAYLIST="$(echo "$CHECK_RESP" | jq -r '.items[0].snippet.playlistId // empty')"

if [[ -z "$FOUND_PLAYLIST" ]]; then
  # Item not found — treat as idempotent noop (matches gws auth logout semantics).
  if [[ $JSON -eq 1 ]]; then
    jq -n --arg id "$ITEM_ID" '{status:"already_absent", playlistItemId:$id}'
  else
    echo "Already absent: playlistItem $ITEM_ID not found (no-op)."
  fi
  exit 0
fi

# --- Plan + confirmation ----------------------------------------------------
plan_json() {
  jq -n --arg id "$ITEM_ID" --arg pid "$FOUND_PLAYLIST" --arg t "$FOUND_TITLE" \
    '{action:"remove", playlistItemId:$id, playlistId:$pid, title:$t}'
}

if [[ $DRY -eq 1 ]]; then
  if [[ $JSON -eq 1 ]]; then
    jq -n --argjson p "$(plan_json)" '{status:"dry_run", plan:$p}'
  else
    echo "DRY RUN — would remove playlistItem $ITEM_ID"
    echo "  Playlist: $FOUND_PLAYLIST"
    echo "  Title:    $FOUND_TITLE"
  fi
  exit 0
fi

if [[ $YES -eq 0 && -t 0 ]]; then
  echo "Remove '$FOUND_TITLE' from playlist $FOUND_PLAYLIST? [y/N] " >&2
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "Cancelled." >&2; exit 2;;
  esac
fi
if [[ $YES -eq 0 && ! -t 0 ]]; then
  echo "youtube-remove-item.sh: non-interactive context — pass --yes to confirm" >&2
  exit 2
fi

# --- Delete ------------------------------------------------------------------
DELETE_URL="https://www.googleapis.com/youtube/v3/playlistItems?id=$IID_ENC"
TOK="$(yt_access_token)"
RESP_FILE="$(mktemp)"
HTTP="$(curl -sS -o "$RESP_FILE" -w '%{http_code}' \
  -X DELETE "$DELETE_URL" \
  -H "Authorization: Bearer $TOK" \
  -H "Accept: application/json")" || {
    echo "youtube-remove-item.sh: delete request failed (network)" >&2
    cat "$RESP_FILE" >&2
    rm -f "$RESP_FILE"
    exit 1
  }

if [[ "$HTTP" == "401" ]]; then
  yt_refresh_access_token >&2 || { rm -f "$RESP_FILE"; exit 1; }
  TOK="$(jq -r '.access_token' "$(yt_credentials_path)")"
  HTTP="$(curl -sS -o "$RESP_FILE" -w '%{http_code}' \
    -X DELETE "$DELETE_URL" \
    -H "Authorization: Bearer $TOK" \
    -H "Accept: application/json")"
fi

RESP="$(cat "$RESP_FILE")"
rm -f "$RESP_FILE"

# DELETE returns 204 No Content on success.
if [[ "$HTTP" == "204" ]]; then
  if [[ $JSON -eq 1 ]]; then
    jq -n --arg id "$ITEM_ID" --arg pid "$FOUND_PLAYLIST" --arg t "$FOUND_TITLE" \
      '{status:"deleted", playlistItemId:$id, wasIn:{playlistId:$pid, title:$t}}'
  else
    echo "Deleted: playlistItem $ITEM_ID"
    echo "  Playlist: $FOUND_PLAYLIST"
    echo "  Title:    $FOUND_TITLE"
  fi
  exit 0
fi

# 404 after a successful pre-flight means a race / external deletion: treat
# as already_absent rather than erroring.
if [[ "$HTTP" == "404" ]]; then
  if [[ $JSON -eq 1 ]]; then
    jq -n --arg id "$ITEM_ID" '{status:"already_absent", playlistItemId:$id}'
  else
    echo "Already absent: playlistItem $ITEM_ID was deleted by another caller (no-op)."
  fi
  exit 0
fi

echo "youtube-remove-item.sh: delete failed (HTTP $HTTP)" >&2
echo "$RESP" | jq . >&2 2>/dev/null || echo "$RESP" >&2
exit 1
