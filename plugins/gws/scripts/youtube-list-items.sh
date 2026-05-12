#!/usr/bin/env bash
# List items (videos) in a YouTube playlist.
#
# Read-only. Uses youtube-common.sh for auth + refresh on 401.
#
# Usage:
#   youtube-list-items.sh <playlist-id>
#   youtube-list-items.sh <playlist-id> --account=LABEL
#   youtube-list-items.sh <playlist-id> --json
#   youtube-list-items.sh <playlist-id> --max=N       # cap results (default 5000)
#   youtube-list-items.sh <playlist-id> --force-refresh
#
# Output (human): position, videoId, title (truncated), publishedAt
# Output (JSON): array of {playlistItemId, videoId, title, position, publishedAt}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=youtube-common.sh
source "$SCRIPT_DIR/youtube-common.sh"

YT_ACCOUNT_OVERRIDE=""
JSON=0
MAX=5000
FORCE_REFRESH=0
PLAYLIST_ID=""
for arg in "$@"; do
  case "$arg" in
    --account=*)     YT_ACCOUNT_OVERRIDE="${arg#--account=}";;
    --json)          JSON=1;;
    --max=*)         MAX="${arg#--max=}";;
    --force-refresh) FORCE_REFRESH=1;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0;;
    --*)
      echo "youtube-list-items.sh: unknown flag '$arg'" >&2; exit 2;;
    *)
      if [[ -n "$PLAYLIST_ID" ]]; then
        echo "youtube-list-items.sh: extra positional arg '$arg' (expected one playlist id)" >&2
        exit 2
      fi
      PLAYLIST_ID="$arg";;
  esac
done
export YT_ACCOUNT_OVERRIDE

if [[ -z "$PLAYLIST_ID" ]]; then
  echo "youtube-list-items.sh: missing <playlist-id>" >&2
  echo "  Run youtube-list-playlists.sh to find one." >&2
  exit 2
fi

yt_require_jq
[[ "$MAX" =~ ^[0-9]+$ ]] || { echo "--max must be a positive integer" >&2; exit 2; }

if [[ $FORCE_REFRESH -eq 1 ]]; then
  yt_refresh_access_token >&2 || exit 1
  echo "(refreshed access token)" >&2
fi

API="https://www.googleapis.com/youtube/v3/playlistItems"
PID_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$PLAYLIST_ID")"
PAGE_SIZE=50
COLLECTED="[]"
PAGE_TOKEN=""

while :; do
  URL="$API?part=snippet,contentDetails&playlistId=$PID_ENC&maxResults=$PAGE_SIZE"
  if [[ -n "$PAGE_TOKEN" ]]; then
    PT_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$PAGE_TOKEN")"
    URL="$URL&pageToken=$PT_ENC"
  fi

  RESP="$(yt_authorized_curl "$URL")" || {
    echo "youtube-list-items.sh: API request failed:" >&2
    echo "$RESP" >&2
    exit 1
  }

  ERR="$(echo "$RESP" | jq -r '.error.message // empty')"
  if [[ -n "$ERR" ]]; then
    echo "youtube-list-items.sh: API error: $ERR" >&2
    echo "$RESP" | jq . >&2
    exit 1
  fi

  PAGE_ITEMS="$(echo "$RESP" | jq '[.items[] | {
    playlistItemId: .id,
    videoId: .contentDetails.videoId,
    title: .snippet.title,
    position: .snippet.position,
    publishedAt: .contentDetails.videoPublishedAt
  }]')"

  COLLECTED="$(jq -n --argjson a "$COLLECTED" --argjson b "$PAGE_ITEMS" '$a + $b')"

  COUNT="$(echo "$COLLECTED" | jq 'length')"
  if (( COUNT >= MAX )); then
    COLLECTED="$(echo "$COLLECTED" | jq --argjson m "$MAX" '.[:$m]')"
    break
  fi

  PAGE_TOKEN="$(echo "$RESP" | jq -r '.nextPageToken // empty')"
  [[ -z "$PAGE_TOKEN" ]] && break
done

if [[ $JSON -eq 1 ]]; then
  echo "$COLLECTED" | jq .
  exit 0
fi

TOTAL="$(echo "$COLLECTED" | jq 'length')"
echo "$TOTAL item(s) in playlist $PLAYLIST_ID:"
echo ""
echo "$COLLECTED" | jq -r '.[] | [
    (.position // 0 | tostring),
    .videoId,
    (.title // "(deleted/private)"),
    (.publishedAt // "")
  ] | @tsv' \
  | awk -F'\t' 'BEGIN{ printf "  %-4s  %-11s  %-50s  %s\n", "POS", "VIDEOID", "TITLE", "PUBLISHED" }
                { printf "  %-4s  %-11s  %-50s  %s\n", $1, $2, substr($3,1,50), $4 }'
