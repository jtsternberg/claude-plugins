#!/usr/bin/env bash
# Tests for auth-preflight.sh.
#
# The bug this guards against: `gws auth status` writes "Using keyring backend:
# keyring" to stderr on EVERY call. The old preflight did
#   gws auth status 2>&1 | python3 -c '...json.load(sys.stdin)...'
# which merged that line into the parser's input, failed to parse every single
# time, and printed "NOT AUTHENTICATED" for a fully authenticated account. So the
# stub here ALWAYS emits the keyring line on stderr — a stub that didn't would
# pass while the real thing stays broken.
#
# The second thing under test is the state machine: "no account selected" and
# "no credentials anywhere" have different fixes, and telling a user to re-run
# OAuth when they only needed to pick an account is the failure mode.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFLIGHT="$PLUGIN_ROOT/scripts/auth-preflight.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Stub: authenticated when $STUB_AUTHED=true for the config dir in play.
cat > "$TMP/bin/gws" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then
  # Always noisy on stderr — this is the real CLI's behavior.
  echo "Using keyring backend: keyring" >&2
  if [[ -f "${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-/nonexistent}/credentials.enc" ]]; then
    echo '{"user":"'"$(basename "${GOOGLE_WORKSPACE_CLI_CONFIG_DIR}")"'@example.com","has_refresh_token":true,"encryption_valid":true,"token_valid":true}'
    exit 0
  fi
  echo '{"has_refresh_token":false,"encryption_valid":false,"token_valid":false}'
  exit 2
fi
echo "stub: unhandled: $*" >&2; exit 1
STUB
chmod +x "$TMP/bin/gws"
export PATH="$TMP/bin:$PATH"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; }

# fresh_state <accounts-dir-name> — resets HOME so DEFAULT_CONFIG is isolated.
setup() {
  RUN="$TMP/run-$1"
  rm -rf "$RUN"
  mkdir -p "$RUN/home/.config" "$RUN/accounts"
  export HOME="$RUN/home"
  export GWS_ACCOUNTS_DIR="$RUN/accounts"
  unset GOOGLE_WORKSPACE_CLI_CONFIG_DIR
}
authed_dir() { mkdir -p "$1"; : > "$1/credentials.enc"; }

# run_preflight [args...] -> sets OUT (stdout+stderr) and RC
run_preflight() {
  OUT="$(bash "$PREFLIGHT" "$@" 2>&1)"; RC=$?
}

# --- the regression: authed account must NOT report NOT AUTHENTICATED ---------
setup authed
authed_dir "$HOME/.config/gws"
run_preflight
if [[ $RC -eq 0 && "$OUT" == *"Authenticated as: gws@example.com"* ]]; then ok
else bad "authenticated default config reports success despite keyring noise" \
  "exit 0 + 'Authenticated as:'" "rc=$RC out=$OUT"; fi

# --json must be parseable even though gws is noisy.
run_preflight --json
if [[ $RC -eq 0 ]] && printf '%s' "$OUT" | python3 -c '
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if d["authenticated"] and d["state"]=="ok" else 1)'; then ok
else bad "--json emits parseable JSON" "authenticated:true state:ok" "rc=$RC out=$OUT"; fi

# --quiet prints nothing on success (it is used as a script guard).
run_preflight --quiet
if [[ $RC -eq 0 && -z "$OUT" ]]; then ok
else bad "--quiet is silent on success" "empty output, exit 0" "rc=$RC out=$OUT"; fi

# --- no .active, but named accounts are authed --------------------------------
# Default config empty => this is a SELECT problem, not an auth problem.
setup select
authed_dir "$GWS_ACCOUNTS_DIR/work"
authed_dir "$GWS_ACCOUNTS_DIR/dw"
run_preflight
if [[ $RC -eq 1 && "$OUT" == *"no account is selected"* && "$OUT" == *"account-switch.sh"* ]]; then ok
else bad "unselected-with-candidates says select, not login" \
  "exit 1 naming 'no account is selected' + account-switch.sh" "rc=$RC out=$OUT"; fi

if [[ "$OUT" != *"gws auth login"* ]]; then ok
else bad "unselected-with-candidates does NOT suggest re-running OAuth" \
  "no 'gws auth login' in output" "$OUT"; fi

if [[ "$OUT" == *"work"* && "$OUT" == *"dw"* ]]; then ok
else bad "candidate labels are listed" "both 'work' and 'dw'" "$OUT"; fi

# --- nothing authenticated anywhere ------------------------------------------
setup nothing
run_preflight
if [[ $RC -eq 1 && "$OUT" == *"no stored credentials for any account"* && "$OUT" == *"gws auth login"* ]]; then ok
else bad "no credentials anywhere says gws auth login" \
  "exit 1 + 'no stored credentials for any account' + login hint" "rc=$RC out=$OUT"; fi

# --- authed default config while other accounts exist ------------------------
# Succeeds, but must warn that calls are silently going to the default identity.
setup warn
authed_dir "$HOME/.config/gws"
authed_dir "$GWS_ACCOUNTS_DIR/work"
run_preflight
if [[ $RC -eq 0 && "$OUT" == *"no account is selected"* && "$OUT" == *"work"* ]]; then ok
else bad "authed default warns about unselected account" \
  "exit 0 + wrong-identity warning naming 'work'" "rc=$RC out=$OUT"; fi

# The warning must not appear once an account IS selected.
printf 'work' > "$GWS_ACCOUNTS_DIR/.active"
run_preflight
if [[ $RC -eq 0 && "$OUT" != *"no account is selected"* ]]; then ok
else bad "selected account produces no warning" "exit 0, no warning" "rc=$RC out=$OUT"; fi

# --- selected account whose credentials are missing --------------------------
setup broken
authed_dir "$GWS_ACCOUNTS_DIR/other"
mkdir -p "$GWS_ACCOUNTS_DIR/work"          # selected, but no credentials.enc
printf 'work' > "$GWS_ACCOUNTS_DIR/.active"
run_preflight
if [[ $RC -eq 1 && "$OUT" == *"selected account 'work'"* && "$OUT" == *"GOOGLE_WORKSPACE_CLI_CONFIG_DIR"* ]]; then ok
else bad "selected-but-unauthed account gets a targeted re-auth hint" \
  "exit 1 naming 'work' + a scoped login command" "rc=$RC out=$OUT"; fi

# --- explicit env override ----------------------------------------------------
setup override
authed_dir "$GWS_ACCOUNTS_DIR/work"
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$GWS_ACCOUNTS_DIR/work"
run_preflight
if [[ $RC -eq 0 && "$OUT" == *"account: env-override"* && "$OUT" != *"no account is selected"* ]]; then ok
else bad "env override is honoured without an unselected warning" \
  "exit 0 + 'env-override', no selection warning" "rc=$RC out=$OUT"; fi

export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$GWS_ACCOUNTS_DIR/missing"
run_preflight
if [[ $RC -eq 1 && "$OUT" == *"GOOGLE_WORKSPACE_CLI_CONFIG_DIR=$GWS_ACCOUNTS_DIR/missing"* ]]; then ok
else bad "unauthed env override names the overridden dir" \
  "exit 1 naming the override dir" "rc=$RC out=$OUT"; fi
unset GOOGLE_WORKSPACE_CLI_CONFIG_DIR

# --- caller-propagated config dir is not a user override ----------------------
# calendar-common.sh::_calendar_resolve_account exports the RESOLVED active
# account before invoking this script as a guard. Treating that as a user
# override suppressed the selection diagnostics for every script guard.
setup propagated
authed_dir "$GWS_ACCOUNTS_DIR/work"
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$HOME/.config/gws"   # == resolve_active_config
run_preflight
if [[ $RC -eq 1 && "$OUT" == *"no account is selected"* && "$OUT" == *"account-switch.sh"* ]]; then ok
else bad "propagated config dir still gets selection diagnostics" \
  "exit 1 naming 'no account is selected' + account-switch.sh" "rc=$RC out=$OUT"; fi
unset GOOGLE_WORKSPACE_CLI_CONFIG_DIR

# --- dangling selection -------------------------------------------------------
# .active naming a directory that no longer exists. Falling through to the
# default account here means running as an identity the caller did not choose,
# so this is a hard stop even when the default config IS authenticated.
setup dangling
authed_dir "$HOME/.config/gws"          # default config is fine...
authed_dir "$GWS_ACCOUNTS_DIR/dw"
printf 'work' > "$GWS_ACCOUNTS_DIR/.active"   # ...but 'work' does not exist
run_preflight
if [[ $RC -eq 1 && "$OUT" == *"'work' no longer exists"* ]]; then ok
else bad "dangling .active is a hard stop, not a silent fallback" \
  "exit 1 naming 'work' as gone" "rc=$RC out=$OUT"; fi

if [[ "$OUT" == *"identity you did not choose"* && "$OUT" == *"dw"* ]]; then ok
else bad "dangling stop explains the risk and lists real accounts" \
  "wrong-identity warning + 'dw'" "$OUT"; fi

# The resolver must not delete .active to 'self-heal' — that erases the only
# evidence of the problem and makes the next run look normal.
if [[ -f "$GWS_ACCOUNTS_DIR/.active" ]]; then ok
else bad "preflight does not delete a dangling .active" \
  ".active still present after the run" "file was removed"; fi

run_preflight --json
if [[ $RC -eq 1 ]] && printf '%s' "$OUT" | python3 -c '
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if d["state"]=="dangling_selection" and not d["authenticated"] else 1)'; then ok
else bad "--json reports state dangling_selection" \
  "state=dangling_selection, authenticated=false" "rc=$RC out=$OUT"; fi

# resolve_active_config itself must warn without deleting.
setup resolver
authed_dir "$GWS_ACCOUNTS_DIR/dw"
printf 'gone' > "$GWS_ACCOUNTS_DIR/.active"
RESOLVER_OUT="$(
  source "$PLUGIN_ROOT/scripts/account-common.sh"
  resolve_active_config 2>&1
)"
if [[ "$RESOLVER_OUT" == *"WARNING"* && "$RESOLVER_OUT" == *"gone"* \
      && -f "$GWS_ACCOUNTS_DIR/.active" ]]; then ok
else bad "resolve_active_config warns and preserves .active" \
  "warning naming 'gone', file intact" "out=$RESOLVER_OUT present=$([[ -f "$GWS_ACCOUNTS_DIR/.active" ]] && echo yes || echo no)"; fi

# --- gws missing from PATH ----------------------------------------------------
setup nocli
if OUT="$(PATH="/usr/bin:/bin" bash "$PREFLIGHT" 2>&1)"; then
  bad "missing gws CLI exits non-zero" "exit 1" "exit 0: $OUT"
else
  [[ "$OUT" == *"not on PATH"* ]] && ok || bad "missing gws CLI is named as such" \
    "'not on PATH'" "$OUT"
fi

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
