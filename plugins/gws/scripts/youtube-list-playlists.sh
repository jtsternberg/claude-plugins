#!/usr/bin/env bash
# List YouTube playlists owned by the authenticated user (mine=true).
#
# Read-only. Uses youtube-common.sh for auth + refresh on 401.
#
# Usage:
#   youtube-list-playlists.sh                  # active account, human table
#   youtube-list-playlists.sh --account=LABEL  # specific account
#   youtube-list-playlists.sh --json           # raw JSON array (one obj/playlist)
#   youtube-list-playlists.sh --max=N          # cap results (default 250)
#   youtube-list-playlists.sh --force-refresh  # refresh token before request
#                                              # (exercises refresh path for testing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=youtube-common.sh
source "$SCRIPT_DIR/youtube-common.sh"

YT_ACCOUNT_OVERRIDE=""
JSON=0
MAX=250
FORCE_REFRESH=0
for arg in "$@"; do
  case "$arg" in
    --account=*)     YT_ACCOUNT_OVERRIDE="${arg#--account=}";;
    --json)          JSON=1;;
    --max=*)         MAX="${arg#--max=}";;
    --force-refresh) FORCE_REFRESH=1;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0;;
    *) echo "youtube-list-playlists.sh: unknown arg '$arg'" >&2; exit 2;;
  esac
done
export YT_ACCOUNT_OVERRIDE

yt_require_jq
[[ "$MAX" =~ ^[0-9]+$ ]] || { echo "--max must be a positive integer" >&2; exit 2; }

if [[ $FORCE_REFRESH -eq 1 ]]; then
  yt_refresh_access_token >&2 || exit 1
  echo "(refreshed access token)" >&2
fi

API="https://www.googleapis.com/youtube/v3/playlists"
PAGE_SIZE=50
COLLECTED="[]"
PAGE_TOKEN=""

while :; do
  URL="$API?part=snippet,contentDetails,status&mine=true&maxResults=$PAGE_SIZE"
  if [[ -n "$PAGE_TOKEN" ]]; then
    PT_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$PAGE_TOKEN")"
    URL="$URL&pageToken=$PT_ENC"
  fi

  RESP="$(yt_authorized_curl "$URL")" || {
    echo "youtube-list-playlists.sh: API request failed:" >&2
    echo "$RESP" >&2
    exit 1
  }

  ERR="$(echo "$RESP" | jq -r '.error.message // empty')"
  if [[ -n "$ERR" ]]; then
    echo "youtube-list-playlists.sh: API error: $ERR" >&2
    echo "$RESP" | jq . >&2
    exit 1
  fi

  PAGE_ITEMS="$(echo "$RESP" | jq '[.items[] | {
    id: .id,
    title: .snippet.title,
    itemCount: .contentDetails.itemCount,
    privacyStatus: .status.privacyStatus,
    publishedAt: .snippet.publishedAt
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

# Human-readable table: itemCount  title  id
TOTAL="$(echo "$COLLECTED" | jq 'length')"
echo "$TOTAL playlist(s):"
echo ""
echo "$COLLECTED" | jq -r '.[] | [(.itemCount | tostring), .title, .id] | @tsv' \
  | awk -F'\t' 'BEGIN{ printf "  %-5s  %-40s  %s\n", "COUNT", "TITLE", "ID" }
                { printf "  %-5s  %-40s  %s\n", $1, substr($2,1,40), $3 }'
