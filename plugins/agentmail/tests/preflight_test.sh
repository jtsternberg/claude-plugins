#!/usr/bin/env bash
# =============================================================================
# Behavioral tests for the three bundled scripts, against a STUBBED agentmail.
#
# Nothing here touches the real AgentMail API, and no real API key is needed or
# used. A fake `agentmail` is placed earlier on PATH and driven by env vars,
# following the same stubbing convention as the handoff suite (which stubs `bd`).
#
# HOME and XDG_CONFIG_HOME are redirected into a temp dir for every case, so the
# scripts' credential files land there and never near the user's real config.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS="$PLUGIN_ROOT/skills/using-agentmail/scripts"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; return 0; }

command -v python3 >/dev/null 2>&1 || { echo "python3 not installed — skipping"; exit 0; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

STUB_BIN="$SANDBOX/bin"
mkdir -p "$STUB_BIN"

# The fake CLI. STUB_MODE selects the scenario; STUB_LOG records that it ran, so
# a test can prove the --local path made no call.
cat > "$STUB_BIN/agentmail" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_LOG"

case "${1:-}" in
  --version) echo "agentmail version 0.7.14-stub"; exit 0 ;;
esac

case "${STUB_MODE:-ok}" in
  ok)
    case "$*" in
      *"organizations get"*) echo '{"organization_id":"org_stub","inbox_count":1}'; exit 0 ;;
      *"agent sign-up"*)
        echo '{"api_key":"am_us_STUBKEY0123456789abcdef","inbox_id":"my-agent@agentmail.to","organization_id":"org_stub"}'
        exit 0 ;;
      *"agent verify"*) echo '{"verified":true}'; exit 0 ;;
    esac
    echo '{}'; exit 0 ;;
  unauthorized)
    echo '{"name":"UnauthorizedError","code":"unknown_api_key","message":"Unauthorized"}' >&2
    exit 1 ;;
  forbidden_bare)
    # The REAL shape for an invalid key, captured live from api.agentmail.to.
    # 403 (not the documented 401), and NO `code` field at all — which is why the
    # preflight classifies on HTTP status rather than on `code`.
    echo 'GET "https://api.agentmail.to/v0/organizations": 403 Forbidden' >&2
    echo '{ "message": "Forbidden" }' >&2
    exit 1 ;;
  forbidden_permission)
    echo 'GET "https://api.agentmail.to/v0/organizations": 403 Forbidden' >&2
    echo '{"name":"ForbiddenError","code":"missing_permission","message":"Forbidden","fix":"needs organization_read"}' >&2
    exit 1 ;;
  ratelimited)
    echo '{"name":"RateLimitError","code":"rate_limit_exceeded","message":"Too Many Requests"}' >&2
    exit 1 ;;
  signup_fail)
    echo '{"code":"already_exists","message":"already signed up"}' >&2
    exit 1 ;;
  otp_exhausted)
    echo '{"code":"limit_exceeded","message":"too many attempts"}' >&2
    exit 1 ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/agentmail"

# Run a script in a clean sandbox. Usage: sandboxed <mode> <with_cli 0|1> <key> -- cmd...
run_case() {
	local mode="$1" with_cli="$2" key="$3"; shift 3
	[ "${1:-}" = "--" ] && shift

	local case_home="$SANDBOX/home-$RANDOM"
	mkdir -p "$case_home"
	local path="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
	[ "$with_cli" -eq 0 ] && path="/usr/bin:/bin:/usr/sbin:/sbin"

	CASE_HOME="$case_home" env -i \
		HOME="$case_home" \
		XDG_CONFIG_HOME="$case_home/.config" \
		PATH="$path" \
		STUB_MODE="$mode" \
		STUB_LOG="${STUB_LOG_OVERRIDE:-$case_home/stub.log}" \
		${key:+AGENTMAIL_API_KEY="$key"} \
		bash "$@" 2>&1
	return $?
}

KEY="am_us_STUBKEY0123456789abcdef"

echo "== preflight: exit codes =="

out="$(run_case ok 0 "" -- "$SCRIPTS/agentmail-preflight.sh")"; rc=$?
[ "$rc" -eq 10 ] && ok "no CLI on PATH → exit 10" || bad "no CLI should exit 10, got $rc"
printf '%s' "$out" | grep -q 'npm install -g agentmail-cli' \
	&& ok "exit 10 names the install options" || bad "exit 10 does not name install options"
printf '%s' "$out" | grep -qi 'without asking the user' \
	&& ok "exit 10 states the consent rule" || bad "exit 10 omits the consent rule"

out="$(run_case ok 1 "" -- "$SCRIPTS/agentmail-preflight.sh")"; rc=$?
[ "$rc" -eq 11 ] && ok "CLI present, key unset → exit 11" || bad "key unset should exit 11, got $rc"
printf '%s' "$out" | grep -q 'agentmail-signup.sh' \
	&& ok "exit 11 points at onboarding" || bad "exit 11 does not point at onboarding"

out="$(run_case unauthorized 1 "$KEY" -- "$SCRIPTS/agentmail-preflight.sh")"; rc=$?
[ "$rc" -eq 12 ] && ok "401 from probe → exit 12" || bad "401 should exit 12, got $rc"
printf '%s' "$out" | grep -qi 'rotat' \
	&& ok "exit 12 mentions key rotation as a cause" || bad "exit 12 omits the rotation cause"

# Regression guard for a bug found by probing the live API: an invalid key
# returns 403 with a bare {"message":"Forbidden"} and NO `code` field, despite
# the docs promising every error carries one. A code-only detector reported this
# as "inconclusive" (exit 30), sending the user after a network problem they did
# not have. Classification must come from the HTTP status.
out="$(run_case forbidden_bare 1 "$KEY" -- "$SCRIPTS/agentmail-preflight.sh")"; rc=$?
[ "$rc" -eq 12 ] && ok "bare 403 with no error code → exit 12 (not 30)" \
	|| bad "the real invalid-key shape should exit 12, got $rc"
printf '%s' "$out" | grep -q 'HTTP 403' \
	&& ok "bare 403 reports the status it classified on" || bad "bare 403 does not name the status"

out="$(run_case forbidden_permission 1 "$KEY" -- "$SCRIPTS/agentmail-preflight.sh")"; rc=$?
[ "$rc" -eq 12 ] && ok "403 missing_permission → exit 12" || bad "missing_permission should exit 12, got $rc"
printf '%s' "$out" | grep -qi 'lacks a required permission' \
	&& ok "missing_permission gets its own remedy, not the rotation story" \
	|| bad "missing_permission reuses the wrong remedy text"

out="$(run_case ok 1 "$KEY" -- "$SCRIPTS/agentmail-preflight.sh")"; rc=$?
[ "$rc" -eq 0 ] && ok "valid key → exit 0" || bad "valid key should exit 0, got $rc"
printf '%s' "$out" | grep -qi 'does NOT mean the org is OTP-verified' \
	&& ok "exit 0 refuses to imply verification" || bad "exit 0 does not caveat verification"

# The distinction that matters: a rate limit is not a bad credential.
out="$(run_case ratelimited 1 "$KEY" -- "$SCRIPTS/agentmail-preflight.sh")"; rc=$?
[ "$rc" -eq 30 ] && ok "429 → exit 30 (inconclusive), not 12" || bad "429 should exit 30, got $rc"
printf '%s' "$out" | grep -qi 'Retry-After' \
	&& ok "exit 30 mentions Retry-After" || bad "exit 30 omits Retry-After"

echo
echo "== preflight: --local makes no network call =="

case_home="$SANDBOX/home-local"
mkdir -p "$case_home"
STUB_LOG="$case_home/stub.log"
out="$(env -i HOME="$case_home" XDG_CONFIG_HOME="$case_home/.config" \
	PATH="$STUB_BIN:/usr/bin:/bin" STUB_MODE=ok STUB_LOG="$STUB_LOG" \
	AGENTMAIL_API_KEY="$KEY" bash "$SCRIPTS/agentmail-preflight.sh" --local 2>&1)"; rc=$?
[ "$rc" -eq 20 ] && ok "--local with CLI + key → exit 20" || bad "--local should exit 20, got $rc"
if grep -q 'organizations get' "$STUB_LOG" 2>/dev/null; then
	bad "--local called the API" "$(cat "$STUB_LOG")"
else
	ok "--local invoked no API command (only --version)"
fi
printf '%s' "$out" | grep -q 'no API call made' \
	&& ok "--local says it made no API call" || bad "--local does not state it stayed offline"

echo
echo "== masking: the key never appears in output =="

for mode in ok unauthorized ratelimited; do
	for flag in "" "--local"; do
		out="$(run_case "$mode" 1 "$KEY" -- "$SCRIPTS/agentmail-preflight.sh" $flag)" || true
		if printf '%s' "$out" | grep -qF "$KEY"; then
			bad "preflight ($mode ${flag:-default}) leaked the full key"
		else
			ok "preflight ($mode ${flag:-default}) did not leak the key"
		fi
	done
done

out="$(run_case ok 1 "$KEY" -- "$SCRIPTS/agentmail-preflight.sh" --local)"
printf '%s' "$out" | grep -q 'am_us_…cdef' \
	&& ok "preflight prints a masked fingerprint" \
	|| bad "preflight did not print the expected masked fingerprint" "$(printf '%s' "$out" | grep API_KEY)"

echo
echo "== signup: the rotation guard =="

out="$(run_case ok 1 "$KEY" -- "$SCRIPTS/agentmail-signup.sh" --human-email a@b.com --username agent)"; rc=$?
[ "$rc" -eq 40 ] && ok "key already set → refuses with exit 40" || bad "should refuse with 40, got $rc"
printf '%s' "$out" | grep -qi 'ROTATES the API key' \
	&& ok "refusal explains key rotation" || bad "refusal does not explain rotation"

out="$(run_case ok 1 "" -- "$SCRIPTS/agentmail-signup.sh" --username agent)"; rc=$?
[ "$rc" -eq 64 ] && ok "missing --human-email → exit 64" || bad "missing arg should exit 64, got $rc"

out="$(run_case ok 1 "" -- "$SCRIPTS/agentmail-signup.sh" --human-email notanemail --username agent)"; rc=$?
[ "$rc" -eq 64 ] && ok "malformed email → exit 64 before any call" || bad "bad email should exit 64, got $rc"

out="$(run_case ok 1 "" -- "$SCRIPTS/agentmail-signup.sh" --human-email a@b.com --username '.bad')"; rc=$?
[ "$rc" -eq 64 ] && ok "username leading with a separator → exit 64" || bad "bad username should exit 64, got $rc"

echo
echo "== signup: happy path writes a 0600 file and prints nothing sensitive =="

case_home="$SANDBOX/home-signup"
mkdir -p "$case_home"
out="$(env -i HOME="$case_home" XDG_CONFIG_HOME="$case_home/.config" \
	PATH="$STUB_BIN:/usr/bin:/bin" STUB_MODE=ok \
	bash "$SCRIPTS/agentmail-signup.sh" --human-email you@example.com --username my-agent 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "signup happy path → exit 0" || bad "signup should exit 0, got $rc: $out"

cred="$(ls "$case_home/.config/agentmail"/signup-*.json 2>/dev/null | head -1)"
if [ -n "$cred" ]; then
	ok "credential file written: $(basename "$cred")"
	mode="$(python3 -c "import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))" "$cred")"
	[ "$mode" = "0o600" ] && ok "credential file is mode 600" || bad "credential file is $mode, expected 0o600"
	case "$cred" in
		"$PLUGIN_ROOT"*) bad "credential file was written inside the repo: $cred" ;;
		*) ok "credential file is outside the repository" ;;
	esac
	grep -q 'am_us_STUBKEY' "$cred" && ok "credential file contains the key (that is its job)" \
		|| bad "credential file does not contain the key"
else
	bad "no credential file was written"
fi

if printf '%s' "$out" | grep -qF "$KEY"; then
	bad "signup printed the full API key to stdout" "This is the whole point of the script."
else
	ok "signup did not print the full API key"
fi
printf '%s' "$out" | grep -q 'am_us_…cdef' && ok "signup printed a masked fingerprint" || bad "signup printed no masked fingerprint"
printf '%s' "$out" | grep -q 'my-agent@agentmail.to' && ok "signup reported the inbox_id" || bad "signup did not report inbox_id"
printf '%s' "$out" | grep -qi 'only email you@example.com' && ok "signup warns sends are restricted pre-verification" || bad "signup omits the pre-verification restriction"
printf '%s' "$out" | grep -qi 'do not read it into this conversation' && ok "signup tells the agent not to read the file back" || bad "signup omits the do-not-read instruction"

out="$(run_case signup_fail 1 "" -- "$SCRIPTS/agentmail-signup.sh" --human-email a@b.com --username agent)"; rc=$?
[ "$rc" -eq 1 ] && ok "sign-up API failure → exit 1 with the CLI message" || bad "signup failure should exit 1, got $rc"

echo
echo "== verify: OTP validated locally before an attempt is spent =="

for badotp in "12345" "1234567" "12x456" ""; do
	case_home="$SANDBOX/home-otp-$RANDOM"; mkdir -p "$case_home"
	log="$case_home/stub.log"
	out="$(env -i HOME="$case_home" XDG_CONFIG_HOME="$case_home/.config" \
		PATH="$STUB_BIN:/usr/bin:/bin" STUB_MODE=ok STUB_LOG="$log" \
		bash "$SCRIPTS/agentmail-verify.sh" --otp-code "$badotp" 2>&1)"; rc=$?
	if [ "$rc" -eq 64 ] && ! grep -q 'agent verify' "$log" 2>/dev/null; then
		ok "OTP '${badotp:-<empty>}' rejected locally, no attempt spent"
	else
		bad "OTP '${badotp:-<empty>}' should exit 64 without calling out (got $rc)"
	fi
done

echo
echo "== verify: happy path records the only positive signal there is =="

case_home="$SANDBOX/home-verify"
mkdir -p "$case_home/.config/agentmail"
printf '{"api_key":"%s","inbox_id":"my-agent@agentmail.to"}' "$KEY" \
	> "$case_home/.config/agentmail/signup-20260811T000000Z.json"
chmod 600 "$case_home/.config/agentmail/signup-20260811T000000Z.json"

out="$(env -i HOME="$case_home" XDG_CONFIG_HOME="$case_home/.config" \
	PATH="$STUB_BIN:/usr/bin:/bin" STUB_MODE=ok \
	bash "$SCRIPTS/agentmail-verify.sh" --otp-code 123456 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "verify happy path → exit 0" || bad "verify should exit 0, got $rc: $out"
printf '%s' "$out" | grep -qF "$KEY" && bad "verify leaked the key" || ok "verify did not leak the key"

state="$case_home/.config/agentmail/state.json"
if [ -f "$state" ] && grep -q '"verified": true' "$state"; then
	ok "verify recorded verified=true in state.json"
	mode="$(python3 -c "import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))" "$state")"
	[ "$mode" = "0o600" ] && ok "state.json is mode 600" || bad "state.json is $mode, expected 0o600"
else
	bad "verify did not record verified=true"
fi

# And the preflight must then surface it — that record is the only positive
# verification signal that exists anywhere.
out="$(env -i HOME="$case_home" XDG_CONFIG_HOME="$case_home/.config" \
	PATH="$STUB_BIN:/usr/bin:/bin" STUB_MODE=ok AGENTMAIL_API_KEY="$KEY" \
	bash "$SCRIPTS/agentmail-preflight.sh" --local 2>&1)" || true
printf '%s' "$out" | grep -qi 'recorded locally as verified' \
	&& ok "preflight surfaces the local verification record" \
	|| bad "preflight ignores the local verification record"

echo
echo "== verify: no key anywhere, and exhausted attempts =="

case_home="$SANDBOX/home-nokey"; mkdir -p "$case_home"
out="$(env -i HOME="$case_home" XDG_CONFIG_HOME="$case_home/.config" \
	PATH="$STUB_BIN:/usr/bin:/bin" STUB_MODE=ok \
	bash "$SCRIPTS/agentmail-verify.sh" --otp-code 123456 2>&1)"; rc=$?
[ "$rc" -eq 41 ] && ok "no key from any source → exit 41" || bad "no key should exit 41, got $rc"

case_home="$SANDBOX/home-exhausted"; mkdir -p "$case_home"
out="$(env -i HOME="$case_home" XDG_CONFIG_HOME="$case_home/.config" \
	PATH="$STUB_BIN:/usr/bin:/bin" STUB_MODE=otp_exhausted AGENTMAIL_API_KEY="$KEY" \
	bash "$SCRIPTS/agentmail-verify.sh" --otp-code 123456 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "exhausted OTP attempts → exit 1" || bad "exhausted attempts should exit 1, got $rc"
printf '%s' "$out" | grep -qi 'including the correct one' \
	&& ok "exhaustion message explains the correct code is also rejected" \
	|| bad "exhaustion message omits the counterintuitive part"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
