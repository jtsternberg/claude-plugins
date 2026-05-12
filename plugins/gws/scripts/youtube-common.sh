#!/usr/bin/env bash
# Shared helpers for gws youtube-* scripts.
# Source this file; do not execute directly.
#
# Provides:
#   yt_resolve_account_dir       -> echoes active (or --account=) account dir
#   yt_client_secret_path        -> echoes path to client_secret.json in account dir
#   yt_credentials_path          -> echoes path to youtube_credentials.json in account dir
#   yt_token_valid               -> 0 if file has unexpired access_token, else 1
#   yt_refresh_access_token      -> POSTs to oauth2 token endpoint, updates file in place
#   yt_authorized_curl <args...> -> curl with Authorization: Bearer; auto-refresh on 401
#   yt_require_jq                -> exit 1 if jq missing
#
# Conventions match plugins/gws/scripts/calendar-common.sh.

set -euo pipefail

YT_SCOPE="https://www.googleapis.com/auth/youtube"
YT_TOKEN_URL="https://oauth2.googleapis.com/token"
YT_DEVICE_URL="https://oauth2.googleapis.com/device/code"

# --- account resolution (mirrors calendar-common.sh idiom) -------------------

_yt_source_account_common() {
  local _common
  _common="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/account-common.sh"
  if [[ ! -f "$_common" ]]; then
    echo "youtube-common.sh: cannot locate account-common.sh at $_common" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  source "$_common"
}

# Echo the account config dir to use. Honors YT_ACCOUNT_OVERRIDE (caller-set
# from --account=<label>) before falling back to the gws active account.
yt_resolve_account_dir() {
  if [[ -n "${YT_ACCOUNT_OVERRIDE:-}" ]]; then
    local dir="${ACCOUNTS_BASE:-$HOME/.config/gws-accounts}/$YT_ACCOUNT_OVERRIDE"
    if [[ ! -d "$dir" ]]; then
      echo "youtube-common.sh: account '$YT_ACCOUNT_OVERRIDE' not found at $dir" >&2
      return 1
    fi
    echo "$dir"
    return
  fi
  _yt_source_account_common
  resolve_active_config
}

yt_client_secret_path() {
  local dir
  dir="$(yt_resolve_account_dir)" || return 1
  echo "$dir/client_secret.json"
}

yt_credentials_path() {
  local dir
  dir="$(yt_resolve_account_dir)" || return 1
  echo "$dir/youtube_credentials.json"
}

yt_require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "youtube-common.sh: requires 'jq' on PATH (brew install jq)" >&2
    return 1
  fi
}

# Print the active account label (best-effort; used for status messages only).
yt_active_label() {
  _yt_source_account_common
  if [[ -n "${YT_ACCOUNT_OVERRIDE:-}" ]]; then
    echo "$YT_ACCOUNT_OVERRIDE"
  else
    resolve_active_label
  fi
}

# --- token freshness + refresh ----------------------------------------------

# Returns 0 if the file has an access_token whose expires_at is at least 60s
# in the future. Returns 1 otherwise (missing file, missing token, expired,
# or malformed). Does NOT attempt refresh — caller decides.
yt_token_valid() {
  yt_require_jq
  local creds
  creds="$(yt_credentials_path)" || return 1
  [[ -f "$creds" ]] || return 1
  local now exp
  now="$(date +%s)"
  exp="$(jq -r '.expires_at // 0' "$creds" 2>/dev/null || echo 0)"
  [[ "$exp" =~ ^[0-9]+$ ]] || return 1
  (( exp > now + 60 ))
}

# Refresh the access token in place using the stored refresh_token.
# On success: updates access_token + expires_at in the credentials file.
# On failure: returns non-zero with a message on stderr; file untouched.
yt_refresh_access_token() {
  yt_require_jq
  local creds cs refresh client_id client_secret resp new_access expires_in
  creds="$(yt_credentials_path)" || return 1
  cs="$(yt_client_secret_path)" || return 1
  if [[ ! -f "$creds" ]]; then
    echo "youtube-common.sh: no credentials at $creds — run youtube-login.sh first" >&2
    return 1
  fi
  if [[ ! -f "$cs" ]]; then
    echo "youtube-common.sh: missing client_secret.json at $cs" >&2
    return 1
  fi
  refresh="$(jq -r '.refresh_token // empty' "$creds")"
  if [[ -z "$refresh" ]]; then
    echo "youtube-common.sh: no refresh_token in $creds — re-run youtube-login.sh" >&2
    return 1
  fi
  client_id="$(jq -r '.installed.client_id // .web.client_id // empty' "$cs")"
  client_secret="$(jq -r '.installed.client_secret // .web.client_secret // empty' "$cs")"
  if [[ -z "$client_id" || -z "$client_secret" ]]; then
    echo "youtube-common.sh: could not parse client_id/client_secret from $cs" >&2
    return 1
  fi
  resp="$(curl -sS -X POST "$YT_TOKEN_URL" \
    --data-urlencode "client_id=$client_id" \
    --data-urlencode "client_secret=$client_secret" \
    --data-urlencode "refresh_token=$refresh" \
    --data-urlencode "grant_type=refresh_token")" || {
      echo "youtube-common.sh: token refresh request failed" >&2
      return 1
    }
  new_access="$(echo "$resp" | jq -r '.access_token // empty')"
  expires_in="$(echo "$resp" | jq -r '.expires_in // empty')"
  if [[ -z "$new_access" || -z "$expires_in" ]]; then
    echo "youtube-common.sh: refresh response missing access_token/expires_in:" >&2
    echo "$resp" >&2
    return 1
  fi
  local now exp tmp
  now="$(date +%s)"
  exp=$(( now + expires_in - 30 ))
  tmp="$(mktemp "${creds}.XXXXXX")"
  jq --arg at "$new_access" --argjson exp "$exp" \
    '.access_token = $at | .expires_at = $exp' "$creds" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$creds"
}

# Get a usable access token, refreshing if needed. Echoes the token to stdout.
yt_access_token() {
  if ! yt_token_valid; then
    yt_refresh_access_token >&2 || return 1
  fi
  jq -r '.access_token' "$(yt_credentials_path)"
}

# Authorized curl. First arg is the URL (or any curl flags); we inject the
# bearer header. On HTTP 401 we refresh once and retry.
yt_authorized_curl() {
  local tok body http
  tok="$(yt_access_token)" || return 1
  body="$(mktemp)"
  http="$(curl -sS -o "$body" -w '%{http_code}' \
    -H "Authorization: Bearer $tok" \
    -H "Accept: application/json" \
    "$@")" || { rm -f "$body"; return 1; }
  if [[ "$http" == "401" ]]; then
    yt_refresh_access_token >&2 || { rm -f "$body"; return 1; }
    tok="$(jq -r '.access_token' "$(yt_credentials_path)")"
    http="$(curl -sS -o "$body" -w '%{http_code}' \
      -H "Authorization: Bearer $tok" \
      -H "Accept: application/json" \
      "$@")" || { rm -f "$body"; return 1; }
  fi
  cat "$body"
  rm -f "$body"
  if [[ "$http" =~ ^2 ]]; then
    return 0
  fi
  return 22
}
