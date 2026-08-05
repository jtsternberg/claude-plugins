#!/usr/bin/env bash
# Report the gws authentication state precisely, and exit non-zero only when the
# resolved account genuinely cannot make API calls.
#
# Usage: auth-preflight.sh [--quiet] [--json]
#   --quiet  Print nothing when authenticated (diagnosis still goes to stderr on
#            failure). For use as a script guard.
#   --json   Emit a machine-readable state object on stdout.
#
# Why this exists: `gws auth status` writes "Using keyring backend: keyring" to
# stderr on EVERY invocation. Callers that merged stderr into stdout before
# parsing the JSON — `gws auth status 2>&1 | python3 -c '...json.load...'` — hit
# a parse error unconditionally and fell through to "NOT AUTHENTICATED", even
# for a fully authenticated account. Never merge gws stderr into a parser; read
# `gws auth status 2>/dev/null`.
#
# The second failure this replaces: reporting "run gws auth login" for every
# non-authenticated state. "No account selected" and "no credentials anywhere"
# need different fixes, and re-running OAuth on an already-authed account is a
# pointless detour.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/account-common.sh"

QUIET=false
AS_JSON=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quiet) QUIET=true; shift ;;
    --json)  AS_JSON=true; shift ;;
    -h|--help) sed -n '2,9p' "$0" >&2; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! command -v gws >/dev/null 2>&1; then
  if [[ "$AS_JSON" == true ]]; then
    printf '{"state":"cli_missing","authenticated":false}\n'
  else
    echo "ERROR: the 'gws' CLI is not on PATH. Install it, then run: gws auth login" >&2
  fi
  exit 1
fi

# Honour an explicit override; otherwise resolve the active account.
#
# Subtlety: callers that source calendar-common.sh have already exported
# GOOGLE_WORKSPACE_CLI_CONFIG_DIR with the *resolved* active account before
# invoking this script. Treating that as a user override would suppress the
# account-selection diagnostics for every script guard. So an override only
# counts as one when it differs from what resolution would have picked anyway.
# stderr suppressed: this script emits its own, better message for the dangling
# case below, and duplicating the resolver's warning just adds noise.
RESOLVED_DIR="$(resolve_active_config 2>/dev/null)"
if [[ -n "${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-}" \
      && "$GOOGLE_WORKSPACE_CLI_CONFIG_DIR" != "$RESOLVED_DIR" ]]; then
  CONFIG_DIR="$GOOGLE_WORKSPACE_CLI_CONFIG_DIR"
  LABEL="env-override"
  OVERRIDDEN=true
else
  CONFIG_DIR="$RESOLVED_DIR"
  LABEL="$(resolve_active_label)"
  OVERRIDDEN=false
  export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$CONFIG_DIR"
fi

# .active is what selects an account; its absence is a distinct state from
# "not authenticated", and it silently routes every call to the default config.
ACTIVE_SELECTED=true
[[ -f "$ACTIVE_FILE" ]] || ACTIVE_SELECTED=false

# A selection pointing at a directory that no longer exists is worse than no
# selection: the caller believes it is acting as one account while every call
# falls through to the default (usually personal) identity. Stop rather than
# proceed under the wrong identity.
DANGLING_LABEL="$(resolve_dangling_label)"

# Other account dirs that hold stored credentials — candidates to switch to.
CANDIDATES=()
if [[ -d "$ACCOUNTS_BASE" ]]; then
  for _dir in "$ACCOUNTS_BASE"/*/; do
    [[ -d "$_dir" ]] || continue
    [[ -f "${_dir}credentials.enc" || -f "${_dir}credentials.json" ]] || continue
    CANDIDATES+=("$(basename "${_dir%/}")")
  done
fi

# stderr discarded, never merged — see the header.
STATUS_JSON="$(gws auth status 2>/dev/null || true)"

PARSED="$(GWS_STATUS="$STATUS_JSON" python3 -c '
import json, os, sys
raw = os.environ.get("GWS_STATUS", "").strip()
if not raw:
    print("unparseable\t\tfalse\tfalse")
    sys.exit(0)
try:
    d = json.loads(raw)
except Exception:
    print("unparseable\t\tfalse\tfalse")
    sys.exit(0)
user = d.get("user") or ""
have = bool(d.get("has_refresh_token")) and bool(d.get("encryption_valid"))
# token_valid False is not a failure: a refresh token renews it on next call.
print("\t".join(["ok" if have else "no_credentials", user,
                 "true" if have else "false",
                 "true" if d.get("token_valid") else "false"]))
')"

IFS=$'\t' read -r STATE USER_EMAIL HAVE_CREDS TOKEN_VALID <<<"$PARSED"

emit_json() {
  GWS_STATE="$STATE" GWS_USER="$USER_EMAIL" GWS_LABEL="$LABEL" \
  GWS_DIR="$CONFIG_DIR" GWS_ACTIVE="$ACTIVE_SELECTED" GWS_TOKEN="$TOKEN_VALID" \
  GWS_CANDS="$(IFS=,; echo "${CANDIDATES[*]:-}")" python3 -c '
import json, os
c = os.environ.get("GWS_CANDS", "")
print(json.dumps({
    "state": os.environ["GWS_STATE"],
    "authenticated": os.environ["GWS_STATE"] == "ok",
    "user": os.environ["GWS_USER"] or None,
    "account": os.environ["GWS_LABEL"],
    "config_dir": os.environ["GWS_DIR"],
    "active_selected": os.environ["GWS_ACTIVE"] == "true",
    "token_valid": os.environ["GWS_TOKEN"] == "true",
    "candidates": [x for x in c.split(",") if x],
}, indent=2))'
}

# A dangling selection is a hard stop even when the fallback config is authed —
# succeeding here means running as an identity the caller did not choose.
if [[ "$OVERRIDDEN" != true && -n "$DANGLING_LABEL" ]]; then
  STATE="dangling_selection"
  if [[ "$AS_JSON" == true ]]; then
    emit_json
  else
    {
      echo "ERROR: the selected account '$DANGLING_LABEL' no longer exists"
      echo "  ($ACCOUNTS_BASE/$DANGLING_LABEL is named by $ACTIVE_FILE but is not there.)"
      echo "  Refusing to fall through to the default account — that would run as"
      echo "  an identity you did not choose."
      if [[ ${#CANDIDATES[@]} -gt 0 ]]; then
        echo "  Accounts that do exist: ${CANDIDATES[*]}"
        echo "  Select one with: account-switch.sh <label>"
      else
        echo "  No other accounts have stored credentials. Either re-add it:"
        echo "    account-add.sh $DANGLING_LABEL"
        echo "  or select the default: account-switch.sh default"
      fi
    } >&2
  fi
  exit 1
fi

if [[ "$HAVE_CREDS" == true ]]; then
  if [[ "$AS_JSON" == true ]]; then
    emit_json
  elif [[ "$QUIET" != true ]]; then
    echo "Authenticated as: ${USER_EMAIL:-unknown} (account: $LABEL)"
    # The trap that matters in practice: no account selected means every call
    # silently goes to the default config, which may be the wrong identity.
    if [[ "$OVERRIDDEN" != true && "$ACTIVE_SELECTED" != true && ${#CANDIDATES[@]} -gt 0 ]]; then
      echo "Note: no account is selected (${ACTIVE_FILE} is missing), so this is the default config."
      echo "      Other accounts with stored credentials: ${CANDIDATES[*]}"
      echo "      Select one with: account-switch.sh <label>"
    fi
  fi
  exit 0
fi

# Not usable. Say which of the three problems it actually is.
if [[ "$AS_JSON" == true ]]; then
  emit_json
  exit 1
fi

{
  if [[ "$OVERRIDDEN" == true ]]; then
    echo "ERROR: no usable credentials in GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$CONFIG_DIR"
    echo "  Authenticate that config with:"
    echo "    GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$CONFIG_DIR gws auth login"
  elif [[ "$ACTIVE_SELECTED" != true && ${#CANDIDATES[@]} -gt 0 ]]; then
    echo "ERROR: no account is selected and the default config ($CONFIG_DIR) has no credentials."
    echo "  This is NOT an auth failure — these accounts have stored credentials:"
    echo "    ${CANDIDATES[*]}"
    echo "  Select one instead of re-authenticating:"
    echo "    account-switch.sh <label>"
  elif [[ ${#CANDIDATES[@]} -gt 0 ]]; then
    echo "ERROR: the selected account '$LABEL' ($CONFIG_DIR) has no usable credentials."
    echo "  Re-authenticate just that account:"
    echo "    GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$CONFIG_DIR gws auth login"
    echo "  Or switch to one that does: ${CANDIDATES[*]}"
    echo "    account-switch.sh <label>"
  else
    echo "ERROR: gws has no stored credentials for any account."
    echo "  Authenticate with: gws auth login"
  fi
  [[ "$STATE" == "unparseable" && -n "$STATUS_JSON" ]] && \
    echo "  (gws auth status returned output this script could not parse)"
} >&2

exit 1
