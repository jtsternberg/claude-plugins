#!/usr/bin/env bash
# Remove persisted YouTube credentials.
#
# Mirrors `gws auth logout` semantics for the youtube_credentials.json file:
#   - operates on the active gws account by default
#   - --account=LABEL targets a specific account
#   - --all-accounts iterates every dir under ~/.config/gws-accounts
#   - idempotent: missing file is not an error
#   - --json for machine-readable output
#
# Usage:
#   youtube-logout.sh                      # active account
#   youtube-logout.sh --account=LABEL
#   youtube-logout.sh --all-accounts
#   youtube-logout.sh --json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=youtube-common.sh
source "$SCRIPT_DIR/youtube-common.sh"

YT_ACCOUNT_OVERRIDE=""
ALL=0
JSON=0
for arg in "$@"; do
  case "$arg" in
    --account=*) YT_ACCOUNT_OVERRIDE="${arg#--account=}";;
    --all-accounts) ALL=1;;
    --json) JSON=1;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0;;
    *) echo "youtube-logout.sh: unknown arg '$arg'" >&2; exit 2;;
  esac
done

yt_require_jq

removed=()

remove_for_dir() {
  local dir="$1" path="$1/youtube_credentials.json"
  if [[ -f "$path" ]]; then
    rm -f "$path"
    removed+=("$path")
  fi
}

if [[ $ALL -eq 1 ]]; then
  base="${GWS_ACCOUNTS_DIR:-$HOME/.config/gws-accounts}"
  if [[ -d "$base" ]]; then
    for d in "$base"/*/; do
      [[ -d "$d" ]] || continue
      remove_for_dir "${d%/}"
    done
  fi
else
  export YT_ACCOUNT_OVERRIDE
  dir="$(yt_resolve_account_dir)"
  remove_for_dir "$dir"
fi

if [[ $JSON -eq 1 ]]; then
  if (( ${#removed[@]} == 0 )); then
    jq -n '{status:"success", message:"No youtube credentials found to remove.", removed:[]}'
  else
    printf '%s\n' "${removed[@]}" | jq -R . | jq -s \
      '{status:"success", message:"Youtube credentials removed.", removed:.}'
  fi
else
  if (( ${#removed[@]} == 0 )); then
    echo "No youtube credentials found to remove."
  else
    echo "Removed:"
    for p in "${removed[@]}"; do echo "  $p"; done
  fi
fi
