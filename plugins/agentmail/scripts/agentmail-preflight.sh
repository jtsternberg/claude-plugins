#!/usr/bin/env bash
# =============================================================================
# agentmail-preflight.sh — report AgentMail CLI + credential readiness.
#
# Two modes:
#   --local   offline only: is the CLI on PATH, what version, is a key set.
#             This is what the skill runs at load time. It makes NO network call.
#   (default) --local plus ONE authenticated probe (`inboxes list`).
#
# The probe is `inboxes list` because it succeeds on inbox-, pod-, AND
# organization-scoped keys, and it returns the inbox id every other consumer
# needs. `organizations get` looked cheaper — no required flags — but it succeeds
# ONLY on an organization-scoped key. Verified live: an inbox-scoped key gets
# `403 missing_permission` from it, which this script used to report as a rejected
# credential. It was reporting a working key as broken.
#
# Never prints the API key. A masked fingerprint (prefix + last 4) is the most
# this script will ever reveal, because its output lands in an agent transcript
# and transcripts get archived and indexed.
#
# Exit codes are the interface — the calling model branches on them rather than
# parsing prose:
#    0  ready: CLI present and key set. With --local that is all an offline check
#       can know (verification/reachability UNKNOWN); without --local it also means
#       the key was accepted by a live probe — including a recognized key that is
#       merely SCOPE-LIMITED: a `missing_permission` refusal means the credential
#       is good and simply does not carry that permission (exit 0 with a note
#       naming the gap). Either way the healthy path exits 0 so the skill can
#       inject it from a load-time `!` block without Claude Code reporting a
#       spurious "shell command failed" on a non-zero exit.
#   10  CLI not on PATH
#   11  CLI present, AGENTMAIL_API_KEY unset
#   12  key rejected — malformed, revoked, or rotated. NOT a scope gap.
#   30  CLI + key present, probe failed for another reason (network/429/5xx).
#       Reachability unknown — deliberately NOT reported as a bad key.
#   64  usage error
#
# There is deliberately no "org unverified" exit code. The AgentMail API exposes
# no verification field on any documented GET (`organizations get` returns
# counts/limits/billing; `/v0/auth/me` returns scope), so an unverified org is
# indistinguishable from a verified one until a send to a non-signup address
# fails with 403 message_rejected. Guessing here would be worse than silence.
# The only positive signal is local: agentmail-verify.sh records it on success.
# =============================================================================
set -uo pipefail

STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agentmail"
STATE_FILE="$STATE_DIR/state.json"

LOCAL_ONLY=0

usage() {
	cat <<'EOF'
Usage: agentmail-preflight.sh [--local]

  --local   Offline check only (CLI presence, version, key set). No network.
            Exits 0 when both are present.

With no flag, additionally runs one authenticated probe against the AgentMail
API and exits 0 (accepted) / 12 (rejected) / 30 (probe inconclusive).
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--local) LOCAL_ONLY=1 ;;
		-h|--help) usage; exit 0 ;;
		*) printf 'agentmail-preflight: unknown option: %s\n' "$1" >&2; usage >&2; exit 64 ;;
	esac
	shift
done

PY="$(command -v python3 || command -v python || true)"

# json_field <key> — read one string field out of the probe response on stdin.
# python3 when it exists; otherwise a sed fallback that is good enough for the flat
# error bodies this API returns. Never fails the script.
json_field() {
	local key="$1"
	if [ -n "$PY" ]; then
		"$PY" -c '
import json, re, sys
key = sys.argv[1]
raw = sys.stdin.read()
# The CLI prints a status line before the JSON body on an error, so find the
# object rather than assuming the whole stream parses.
for m in re.finditer(r"\{.*\}", raw, re.S):
    try:
        d = json.loads(m.group(0))
    except Exception:
        continue
    v = d.get(key)
    if isinstance(v, str) and v:
        print(v)
        break
' "$key" 2>/dev/null
		return
	fi
	sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# --- masking -----------------------------------------------------------------
# Enough to tell two keys apart, not enough to use. Anything shorter than 12
# characters is shown as **** rather than half-revealed.
mask() {
	local v="${1:-}"
	if [ "${#v}" -lt 12 ]; then
		printf '****'
		return
	fi
	printf '%s…%s' "${v:0:6}" "${v: -4}"
}

# --- 1. is the CLI installed? ------------------------------------------------
if ! command -v agentmail >/dev/null 2>&1; then
	cat <<'EOF'
agentmail CLI: NOT INSTALLED

The `agentmail` binary is not on PATH.

Do not install it without asking the user first. Offer these, then stop:

  npm install -g agentmail-cli      # official; postinstall downloads a Go
                                    # binary from GitHub releases, so this
                                    # needs network + github.com reachable
  npx agentmail-cli <args>          # no global install; pays the binary
                                    # download on a cold cache

Note: if the CLI itself ever tells you to reinstall `@agentmail/cli`, that
package name is wrong — the published name is `agentmail-cli`.
EOF
	exit 10
fi

CLI_VERSION="$(agentmail --version 2>/dev/null)"
printf 'agentmail CLI: %s\n' "${CLI_VERSION:-installed (version unknown)}"

# --- 2. is a key set? --------------------------------------------------------
if [ -z "${AGENTMAIL_API_KEY:-}" ]; then
	cat <<'EOF'
AGENTMAIL_API_KEY: NOT SET

Two ways to get one:
  1. Agent self-signup (no console needed) — run scripts/agentmail-signup.sh,
     then scripts/agentmail-verify.sh with the 6-digit code emailed to the
     human. See references/onboarding.md.
  2. A human creates a key at https://console.agentmail.to/dashboard/api-keys
     (that page requires a scope + access level — see references/onboarding.md)
     and exports it.

Then: export AGENTMAIL_API_KEY=...   (do not commit it; do not paste it here)
EOF
	exit 11
fi

printf 'AGENTMAIL_API_KEY: set (%s)\n' "$(mask "$AGENTMAIL_API_KEY")"

# --- 3. local verification hint ----------------------------------------------
# Positive-only. Absence means "unknown", never "unverified".
if [ -f "$STATE_FILE" ] && grep -q '"verified"[[:space:]]*:[[:space:]]*true' "$STATE_FILE" 2>/dev/null; then
	printf 'verification: recorded locally as verified (%s)\n' "$STATE_FILE"
else
	printf 'verification: unknown — the API exposes no verification field.\n'
	printf '              If a send to a non-signup address returns 403\n'
	printf '              message_rejected, the org still needs OTP verification.\n'
fi

if [ "$LOCAL_ONLY" -eq 1 ]; then
	printf '\nlocal check only — no API call made.\n'
	exit 0
fi

# --- 4. one authenticated probe ----------------------------------------------
# stdout and stderr are captured SEPARATELY. Merging them (`2>&1`) into a parser
# is a mistake this repo has already paid for once (see gws auth_check_drift).
probe_err="$(mktemp)"
probe_out="$(agentmail inboxes list --format json 2>"$probe_err")"
probe_status=$?
probe_stderr="$(cat "$probe_err")"
rm -f "$probe_err"

# Every consumer of this script needs the inbox id, and the probe response already
# carries it. Printing it here is what lets the skills and the mail-check hook skip
# a call of their own.
inbox_ids() {
	local body="$1"
	if [ -n "$PY" ]; then
		printf '%s' "$body" | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ids = [i.get("inbox_id") or i.get("email") for i in (d.get("inboxes") or [])]
ids = [i for i in ids if i]
if ids:
    print(", ".join(ids[:3]) + (f" (+{len(ids)-3} more)" if len(ids) > 3 else ""))
' 2>/dev/null
		return
	fi
	# No python3: pull the ids out with sed. Flat enough that this is safe.
	printf '%s' "$body" | tr ',' '\n' \
		| sed -n 's/.*"inbox_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
		| head -3 | paste -sd ',' - 2>/dev/null
}

if [ "$probe_status" -eq 0 ]; then
	printf 'API probe: OK (inboxes list accepted the key)\n'
	ids="$(inbox_ids "$probe_out")"
	if [ -n "$ids" ]; then
		printf 'inbox: %s\n' "$ids"
	else
		printf 'inbox: none returned — the key is valid but reaches no inbox.\n'
	fi
	printf 'NOTE: a valid key does NOT mean the org is OTP-verified.\n'
	exit 0
fi

# A scope gap is not a bad credential. Check this BEFORE the status classification
# below: `missing_permission` arrives as a 403, and treating every 403 as a
# rejection is exactly the bug this ordering fixes. A key that is recognized well
# enough to be told which permission it lacks is a key that works.
probe_joined="$(printf '%s\n%s' "$probe_out" "$probe_stderr")"
if printf '%s' "$probe_joined" | grep -q 'missing_permission'; then
	printf 'API probe: KEY ACCEPTED, scope-limited\n\n'
	printf 'The key was recognized. It simply does not carry the permission this call\n'
	printf 'needs, or its scope (inbox/pod) does not cover this resource. That is a\n'
	printf 'working credential with a narrower reach — not a rejected one. A key cannot\n'
	printf 'grant itself a permission it does not already hold.\n\n'
	fix="$(printf '%s' "$probe_joined" | json_field fix)"
	[ -n "$fix" ] && printf 'The API says: %s\n\n' "$fix"
	printf 'NOTE: a valid key does NOT mean the org is OTP-verified.\n'
	exit 0
fi

# Then classify by HTTP STATUS, not by the error `code`.
#
# The docs promise that "every error response includes a stable, machine-readable
# code" — and for a rejected credential that is not true. Verified live against
# api.agentmail.to with an invalid key:
#
#   GET "https://api.agentmail.to/v0/inboxes": 403 Forbidden
#   { "message": "Forbidden" }
#
# No `code`, no `fix`, and 403 rather than the documented 401. A code-only
# detector reports a bad key as "inconclusive", which sends the user hunting a
# network problem they do not have. So: status first, code as a refinement.
#
# `missing_permission` already returned above, so anything reaching here with a
# 401/403 is a genuine rejection.
probe_all="$probe_joined"
http_status="$(printf '%s' "$probe_all" | grep -oE ':[[:space:]]+[0-9]{3}[[:space:]]' | grep -oE '[0-9]{3}' | head -1)"

case "${http_status:-}" in
	401|403)
		printf 'API probe: CREDENTIAL REJECTED (HTTP %s)\n\n' "$http_status"
		cat <<'EOF'
The key in AGENTMAIL_API_KEY was not accepted. Either it is malformed, it was
revoked, or it was rotated — note that re-running `agent sign-up` for the same
human email ROTATES the key, silently invalidating the old one.

(AgentMail returns a bare {"message":"Forbidden"} with no error `code` here, so
this was classified from the HTTP status. A `missing_permission` refusal is NOT
this case — that is a working key with a narrower scope, and it exits 0.)
EOF
		exit 12
		;;
esac

# Secondary signal: an auth-class `code` when one is actually present.
if printf '%s' "$probe_all" | grep -qE 'unknown_api_key|"unauthorized"|missing_authorization|invalid_token_type'; then
	cat <<'EOF'
API probe: CREDENTIAL REJECTED

The key in AGENTMAIL_API_KEY was not accepted. Either it is malformed, it was
revoked, or it was rotated by a repeat `agent sign-up`.
EOF
	exit 12
fi

# Anything else — network, 429, 5xx, a resource error. Do not call this a bad
# key; a rate limit or a dropped connection is not a credential problem.
printf 'API probe: INCONCLUSIVE (exit %d) — CLI and key are present but the\n' "$probe_status"
printf '           probe did not complete. Network, 429, or a server error.\n'
if [ -n "$probe_stderr" ]; then
	printf '           stderr: %s\n' "$(printf '%s' "$probe_stderr" | head -3)"
fi
printf '           If this is a 429, honor Retry-After and try once more.\n'
exit 30
