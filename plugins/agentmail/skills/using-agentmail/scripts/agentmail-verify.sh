#!/usr/bin/env bash
# =============================================================================
# agentmail-verify.sh — complete AgentMail agent verification with the 6-digit
# OTP the human received, without the key passing through the transcript.
#
# Sources the API key from (in order): --key-file, the newest signup-*.json in
# the state dir, or an already-exported AGENTMAIL_API_KEY. The key is exported
# only inside this process.
#
# On success, records {"verified": true, ...} to the state file. That local
# record is the ONLY positive verification signal available anywhere — the
# AgentMail API exposes no verification field on any documented GET.
#
# Exit codes:
#    0  verified
#    1  verify call failed (CLI message passed through)
#   41  no API key available from any source
#   64  usage error (including a malformed OTP, caught before spending an attempt)
#
# Requires: agentmail, python3.
# =============================================================================
set -uo pipefail

STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agentmail"
STATE_FILE="$STATE_DIR/state.json"

OTP=""
KEY_FILE=""

usage() {
	cat <<'EOF'
Usage: agentmail-verify.sh --otp-code <6 digits> [--key-file <path>]

  --otp-code   The 6-digit code emailed to the human at sign-up. Expires 24h
               after issue; at most 10 attempts.
  --key-file   JSON file containing the api_key (as written by
               agentmail-signup.sh). Defaults to the newest
               ${XDG_CONFIG_HOME:-$HOME/.config}/agentmail/signup-*.json, then
               falls back to an exported AGENTMAIL_API_KEY.

If the OTP email never arrives, the human can instead create an account at
https://console.agentmail.to/dashboard/api-keys using the same human email.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--otp-code) OTP="${2:-}"; shift ;;
		--key-file) KEY_FILE="${2:-}"; shift ;;
		-h|--help)  usage; exit 0 ;;
		*) printf 'agentmail-verify: unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
	esac
	shift
done

# --- validate the OTP shape BEFORE spending an attempt -----------------------
# Attempts are finite (10) and exhaustion rejects even the correct code until the
# code expires, so a typo caught locally is worth catching locally.
if ! printf '%s' "$OTP" | grep -qE '^[0-9]{6}$'; then
	printf 'agentmail-verify: --otp-code must be exactly 6 digits (got: %s)\n' "${OTP:-<empty>}" >&2
	printf 'Nothing was sent — the attempt was not spent.\n' >&2
	exit 64
fi

if ! command -v agentmail >/dev/null 2>&1; then
	printf 'agentmail-verify: agentmail CLI not on PATH. Run agentmail-preflight.sh first.\n' >&2
	exit 10
fi

if ! command -v python3 >/dev/null 2>&1; then
	printf 'agentmail-verify: python3 is required to read the credential file.\n' >&2
	exit 1
fi

# --- resolve the key ---------------------------------------------------------
resolve_key_file() {
	if [ -n "$KEY_FILE" ]; then
		printf '%s' "$KEY_FILE"
		return
	fi
	# Newest signup-*.json, if any. ls -t rather than a glob sort so an empty
	# match yields nothing instead of a literal pattern.
	ls -t "$STATE_DIR"/signup-*.json 2>/dev/null | head -1
}

RESOLVED_FILE="$(resolve_key_file)"
KEY=""

if [ -n "$RESOLVED_FILE" ] && [ -f "$RESOLVED_FILE" ]; then
	KEY="$(KEY_PATH="$RESOLVED_FILE" python3 -c '
import json, os, sys
try:
    with open(os.environ["KEY_PATH"]) as fh:
        print(json.load(fh).get("api_key", ""))
except Exception:
    sys.exit(0)
')"
fi

if [ -z "$KEY" ]; then
	KEY="${AGENTMAIL_API_KEY:-}"
	RESOLVED_FILE="(exported AGENTMAIL_API_KEY)"
fi

if [ -z "$KEY" ]; then
	cat <<'EOF' >&2
agentmail-verify: no API key available.

Looked in --key-file, then the newest signup-*.json in the state dir, then
AGENTMAIL_API_KEY. Run agentmail-signup.sh first, or export the key.
EOF
	exit 41
fi

printf 'using credential from: %s\n' "$RESOLVED_FILE"

# --- verify ------------------------------------------------------------------
# The key is exported for this one call only, and lives in this process's
# environment rather than in argv (argv is world-readable via `ps`).
verify_err="$(mktemp)"
verify_out="$(AGENTMAIL_API_KEY="$KEY" agentmail agent verify \
	--otp-code "$OTP" \
	--format json 2>"$verify_err")"
verify_status=$?
verify_stderr="$(cat "$verify_err")"
rm -f "$verify_err"

if [ "$verify_status" -ne 0 ]; then
	printf 'agentmail-verify: verification FAILED (exit %d).\n' "$verify_status" >&2
	printf '%s\n' "$(printf '%s' "$verify_stderr" | head -20)" >&2
	if printf '%s%s' "$verify_out" "$verify_stderr" | grep -q 'limit_exceeded'; then
		cat <<'EOF' >&2

limit_exceeded means the 10 OTP attempts are spent. While the exhausted code is
still live, EVERY submission is rejected — including the correct one — until it
expires 24h after issue. Then `agent sign-up` issues a fresh code with a reset
attempt count. If the code has already expired, sign up again now.
EOF
	fi
	exit 1
fi

printf 'agentmail agent verify: OK — organization is verified.\n'
printf 'The send allowlist is lifted; the agent can now email any recipient.\n'

# --- record the only positive verification signal that exists ----------------
umask 077
mkdir -p "$STATE_DIR"
VERIFIED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" python3 <<PY
import json, os

state_file = "$STATE_FILE"
state = {}
if os.path.exists(state_file):
    try:
        with open(state_file) as fh:
            state = json.load(fh)
    except Exception:
        state = {}

state["verified"] = True
state["verified_at"] = os.environ["VERIFIED_AT"]

with open(state_file, "w") as fh:
    json.dump(state, fh, indent=2)
    fh.write("\n")
PY
chmod 600 "$STATE_FILE"
printf 'recorded verified=true in %s\n' "$STATE_FILE"

cat <<EOF

REMINDER: verification does not persist the key for you. If AGENTMAIL_API_KEY is
not already in the user's shell profile or password manager, it still needs to
get there — the value is in the credential file, and copying it is the user's
action, not the agent's.
EOF
