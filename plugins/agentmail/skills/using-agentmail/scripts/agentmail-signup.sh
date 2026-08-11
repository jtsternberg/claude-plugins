#!/usr/bin/env bash
# =============================================================================
# agentmail-signup.sh — run AgentMail's agent self-signup WITHOUT leaking the
# API key into the agent transcript.
#
# `agentmail agent sign-up` returns {api_key, inbox_id, organization_id} on
# stdout. Run bare by an agent, that writes a live credential into the
# conversation transcript — which is archived, and on this machine is also
# auto-ingested into a local searchable index. So: this script captures the
# response, writes it to a 0600 file OUTSIDE any repository, and prints only
# masked values plus the path.
#
# Exit codes:
#    0  signed up; JSON written; OTP sent to the human's email
#    1  sign-up call failed (message from the CLI is passed through)
#   40  refused: AGENTMAIL_API_KEY is already set (use --force)
#   64  usage error
#
# Requires: agentmail, python3 (JSON parsing only — no third-party packages).
# =============================================================================
set -uo pipefail

STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agentmail"

HUMAN_EMAIL=""
USERNAME=""
OUT_PATH=""
FORCE=0

usage() {
	cat <<'EOF'
Usage: agentmail-signup.sh --human-email <addr> --username <name> [--out <path>] [--force]

  --human-email  Email address of the human who owns the agent. The 6-digit OTP
                 is sent here. Until OTP verification completes, this is the ONLY
                 address the agent can email.
  --username     Username for the auto-created inbox (e.g. "my-agent" creates
                 my-agent@agentmail.to).
  --out          Where to write the credential JSON. Default:
                 ${XDG_CONFIG_HOME:-$HOME/.config}/agentmail/signup-<utc>.json
  --force        Proceed even though AGENTMAIL_API_KEY is already set. Sign-up
                 ROTATES the key for an existing human email, which invalidates
                 the key currently in your environment.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--human-email) HUMAN_EMAIL="${2:-}"; shift ;;
		--username)    USERNAME="${2:-}"; shift ;;
		--out)         OUT_PATH="${2:-}"; shift ;;
		--force)       FORCE=1 ;;
		-h|--help)     usage; exit 0 ;;
		*) printf 'agentmail-signup: unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
	esac
	shift
done

# --- validate locally before spending a sign-up ------------------------------
if [ -z "$HUMAN_EMAIL" ] || [ -z "$USERNAME" ]; then
	printf 'agentmail-signup: --human-email and --username are both required\n' >&2
	usage >&2
	exit 64
fi

case "$HUMAN_EMAIL" in
	*@*.*) : ;;
	*) printf 'agentmail-signup: --human-email does not look like an email: %s\n' "$HUMAN_EMAIL" >&2; exit 64 ;;
esac

if ! printf '%s' "$USERNAME" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
	printf 'agentmail-signup: --username must be alphanumeric with . _ - and cannot lead with a separator: %s\n' "$USERNAME" >&2
	exit 64
fi

if ! command -v agentmail >/dev/null 2>&1; then
	printf 'agentmail-signup: agentmail CLI not on PATH. Run agentmail-preflight.sh first.\n' >&2
	exit 10
fi

if ! command -v python3 >/dev/null 2>&1; then
	printf 'agentmail-signup: python3 is required to parse the response without printing it.\n' >&2
	exit 1
fi

# --- the rotation guard ------------------------------------------------------
# Sign-up is idempotent per the docs, but re-signing an existing human email
# ROTATES the API key. Silently invalidating the key already in the environment
# is the kind of thing that gets discovered an hour later, so refuse by default.
if [ -n "${AGENTMAIL_API_KEY:-}" ] && [ "$FORCE" -ne 1 ]; then
	cat <<'EOF' >&2
agentmail-signup: REFUSED — AGENTMAIL_API_KEY is already set.

Sign-up is idempotent, but calling it again for an email that already signed up
ROTATES the API key: the key currently in your environment stops working, with
no warning at the call site.

If you already have a working key you do not need to sign up at all — just use
it. If you really do want to rotate, re-run with --force.
EOF
	exit 40
fi

# --- run it, capturing stdout; never echoing it ------------------------------
umask 077
mkdir -p "$STATE_DIR"
if [ -z "$OUT_PATH" ]; then
	OUT_PATH="$STATE_DIR/signup-$(date -u +%Y%m%dT%H%M%SZ).json"
fi

signup_err="$(mktemp)"
signup_out="$(agentmail agent sign-up \
	--human-email "$HUMAN_EMAIL" \
	--username "$USERNAME" \
	--source agentmail-cli \
	--format json 2>"$signup_err")"
signup_status=$?

if [ "$signup_status" -ne 0 ]; then
	printf 'agentmail-signup: sign-up failed (exit %d).\n' "$signup_status" >&2
	head -20 "$signup_err" >&2
	rm -f "$signup_err"
	exit 1
fi
rm -f "$signup_err"

printf '%s' "$signup_out" > "$OUT_PATH"
chmod 600 "$OUT_PATH"

# --- report, masked ----------------------------------------------------------
# python3 reads the file rather than the variable so nothing key-shaped is ever
# an argv value (argv is visible in `ps`).
OUT_PATH="$OUT_PATH" python3 <<'PY'
import json, os, sys

path = os.environ["OUT_PATH"]
try:
    with open(path) as fh:
        data = json.load(fh)
except (json.JSONDecodeError, OSError) as exc:
    print(f"agentmail-signup: wrote {path} but could not parse it: {exc}", file=sys.stderr)
    sys.exit(1)

def mask(v):
    v = v or ""
    return "****" if len(v) < 12 else f"{v[:6]}…{v[-4:]}"

print("agentmail sign-up: OK")
print(f"  inbox_id:        {data.get('inbox_id', '(absent)')}")
print(f"  organization_id: {data.get('organization_id', '(absent)')}")
print(f"  api_key:         {mask(data.get('api_key'))}  (masked — full value is in the file below)")
print(f"  credential file: {path}  (mode 600)")
if not data.get("api_key"):
    print("  WARNING: response carried no api_key — check the file.")
PY

cat <<EOF

NEXT — the OTP step needs a human:
  1. Ask the user to check $HUMAN_EMAIL for a 6-digit AgentMail code.
     It expires in 24h and allows at most 10 attempts.
  2. Run: scripts/agentmail-verify.sh --otp-code <6 digits>

UNTIL VERIFICATION SUCCEEDS the agent can only email $HUMAN_EMAIL. Sends to any
other recipient fail with 403 message_rejected.

PERSISTING THE KEY is the user's call, not the agent's. The full key is in the
file above; do not read it into this conversation. Point the user at it so they
can copy it into their shell profile or password manager:

  export AGENTMAIL_API_KEY=...   # value from $OUT_PATH

Once it is stored somewhere durable, the file can be deleted — it holds a live
credential. Never commit it, and never write it into a project .env.
EOF
