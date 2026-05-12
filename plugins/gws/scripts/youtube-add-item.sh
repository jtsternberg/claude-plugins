#!/usr/bin/env bash
# Add a video to a YouTube playlist.
#
# MUTATING. Default behavior is dedupe-aware: if the video is already in the
# playlist, this script skips the insert and reports "already present".
# Pass --allow-duplicate to insert anyway (YouTube permits duplicates).
#
# Usage:
#   youtube-add-item.sh <playlist-id> <video-id>
#   youtube-add-item.sh <playlist-id> <video-id> --yes        # skip TTY confirm
#   youtube-add-item.sh <playlist-id> <video-id> --dry-run    # print plan, no call
#   youtube-add-item.sh <playlist-id> <video-id> --allow-duplicate
#   youtube-add-item.sh <playlist-id> <video-id> --json
#   youtube-add-item.sh <playlist-id> <video-id> --account=LABEL
#   youtube-add-item.sh <playlist-id> <video-id> --force-refresh
#
# Exit codes:
#   0  success (added, or skipped because already present)
#   1  API/network/auth failure
#   2  bad usage / cancelled at prompt
#
# JSON output shape:
#   {"status":"added", "playlistItemId":"...", "playlistId":"...", "videoId":"..."}
#   {"status":"skipped_duplicate", "existingPlaylistItemId":"...", ...}
#   {"status":"dry_run", "plan":{...}}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=youtube-common.sh
source "$SCRIPT_DIR/youtube-common.sh"

YT_ACCOUNT_OVERRIDE=""
JSON=0
YES=0
DRY=0
ALLOW_DUP=0
FORCE_REFRESH=0
PLAYLIST_ID=""
VIDEO_ID=""
for arg in "$@"; do
  case "$arg" in
    --account=*)        YT_ACCOUNT_OVERRIDE="${arg#--account=}";;
    --json)             JSON=1;;
    --yes|-y)           YES=1;;
    --dry-run)          DRY=1;;
    --allow-duplicate)  ALLOW_DUP=1;;
    --force-refresh)    FORCE_REFRESH=1;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0;;
    --*)
      echo "youtube-add-item.sh: unknown flag '$arg'" >&2; exit 2;;
    *)
      if   [[ -z "$PLAYLIST_ID" ]]; then PLAYLIST_ID="$arg"
      elif [[ -z "$VIDEO_ID"    ]]; then VIDEO_ID="$arg"
      else echo "youtube-add-item.sh: extra positional arg '$arg'" >&2; exit 2
      fi;;
  esac
done
export YT_ACCOUNT_OVERRIDE

if [[ -z "$PLAYLIST_ID" || -z "$VIDEO_ID" ]]; then
  echo "youtube-add-item.sh: usage: <playlist-id> <video-id> [flags]" >&2
  echo "  See --help for details." >&2
  exit 2
fi

yt_require_jq

if [[ $FORCE_REFRESH -eq 1 ]]; then
  yt_refresh_access_token >&2 || exit 1
  echo "(refreshed access token)" >&2
fi

# --- Dedupe pre-check (unless --allow-duplicate) ----------------------------
# playlistItems.list supports a videoId filter, so this is one cheap call
# (1 quota unit) instead of paginating the whole playlist.
EXISTING_ID=""
if [[ $ALLOW_DUP -eq 0 ]]; then
  PID_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$PLAYLIST_ID")"
  VID_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$VIDEO_ID")"
  CHECK_URL="https://www.googleapis.com/youtube/v3/playlistItems?part=id&playlistId=$PID_ENC&videoId=$VID_ENC&maxResults=1"
  CHECK_RESP="$(yt_authorized_curl "$CHECK_URL")" || {
    echo "youtube-add-item.sh: dedupe pre-check failed:" >&2
    echo "$CHECK_RESP" >&2
    exit 1
  }
  CHECK_ERR="$(echo "$CHECK_RESP" | jq -r '.error.message // empty')"
  if [[ -n "$CHECK_ERR" ]]; then
    echo "youtube-add-item.sh: API error during dedupe pre-check: $CHECK_ERR" >&2
    echo "$CHECK_RESP" | jq . >&2
    exit 1
  fi
  EXISTING_ID="$(echo "$CHECK_RESP" | jq -r '.items[0].id // empty')"
fi

if [[ -n "$EXISTING_ID" ]]; then
  if [[ $JSON -eq 1 ]]; then
    jq -n \
      --arg pid "$PLAYLIST_ID" --arg vid "$VIDEO_ID" --arg eid "$EXISTING_ID" \
      '{status:"skipped_duplicate", existingPlaylistItemId:$eid, playlistId:$pid, videoId:$vid}'
  else
    echo "Skipped: video $VIDEO_ID is already in playlist $PLAYLIST_ID"
    echo "  Existing playlistItemId: $EXISTING_ID"
    echo "  Pass --allow-duplicate to insert anyway."
  fi
  exit 0
fi

# --- Plan + confirmation -----------------------------------------------------
plan_json() {
  jq -n --arg pid "$PLAYLIST_ID" --arg vid "$VIDEO_ID" \
    --argjson dup "$ALLOW_DUP" \
    '{action:"add", playlistId:$pid, videoId:$vid, allowDuplicate:($dup==1)}'
}

if [[ $DRY -eq 1 ]]; then
  if [[ $JSON -eq 1 ]]; then
    jq -n --argjson p "$(plan_json)" '{status:"dry_run", plan:$p}'
  else
    echo "DRY RUN — would add video $VIDEO_ID to playlist $PLAYLIST_ID"
    [[ $ALLOW_DUP -eq 1 ]] && echo "  (--allow-duplicate set)"
  fi
  exit 0
fi

if [[ $YES -eq 0 && -t 0 ]]; then
  echo "Add video $VIDEO_ID to playlist $PLAYLIST_ID? [y/N] " >&2
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "Cancelled." >&2; exit 2;;
  esac
fi
if [[ $YES -eq 0 && ! -t 0 ]]; then
  echo "youtube-add-item.sh: non-interactive context — pass --yes to confirm" >&2
  exit 2
fi

# --- Insert ------------------------------------------------------------------
BODY="$(jq -n --arg pid "$PLAYLIST_ID" --arg vid "$VIDEO_ID" \
  '{snippet:{playlistId:$pid, resourceId:{kind:"youtube#video", videoId:$vid}}}')"

INSERT_URL="https://www.googleapis.com/youtube/v3/playlistItems?part=snippet"
TOK="$(yt_access_token)"
RESP_FILE="$(mktemp)"
HTTP="$(curl -sS -o "$RESP_FILE" -w '%{http_code}' \
  -X POST "$INSERT_URL" \
  -H "Authorization: Bearer $TOK" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  --data-binary "$BODY")" || {
    echo "youtube-add-item.sh: insert request failed (network)" >&2
    cat "$RESP_FILE" >&2
    rm -f "$RESP_FILE"
    exit 1
  }

if [[ "$HTTP" == "401" ]]; then
  yt_refresh_access_token >&2 || { rm -f "$RESP_FILE"; exit 1; }
  TOK="$(jq -r '.access_token' "$(yt_credentials_path)")"
  HTTP="$(curl -sS -o "$RESP_FILE" -w '%{http_code}' \
    -X POST "$INSERT_URL" \
    -H "Authorization: Bearer $TOK" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    --data-binary "$BODY")"
fi

RESP="$(cat "$RESP_FILE")"
rm -f "$RESP_FILE"

if [[ ! "$HTTP" =~ ^2 ]]; then
  echo "youtube-add-item.sh: insert failed (HTTP $HTTP)" >&2
  echo "$RESP" | jq . >&2 2>/dev/null || echo "$RESP" >&2
  exit 1
fi

NEW_ID="$(echo "$RESP" | jq -r '.id // empty')"
if [[ -z "$NEW_ID" ]]; then
  echo "youtube-add-item.sh: insert returned 2xx but no id in body:" >&2
  echo "$RESP" >&2
  exit 1
fi

if [[ $JSON -eq 1 ]]; then
  jq -n \
    --arg pid "$PLAYLIST_ID" --arg vid "$VIDEO_ID" --arg nid "$NEW_ID" \
    '{status:"added", playlistItemId:$nid, playlistId:$pid, videoId:$vid}'
else
  echo "Added video $VIDEO_ID to playlist $PLAYLIST_ID"
  echo "  playlistItemId: $NEW_ID"
fi
