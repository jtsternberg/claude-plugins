#!/usr/bin/env bash
# =============================================================================
# Behavioral tests for the mail-check hook.
#
# This hook runs before every prompt in every session, unattended, with a live
# credential in the environment. So the assertions that matter most are the
# negative ones: it must be silent and exit 0 on every failure, it must never
# touch the key, and it must never call the API more often than its cooldown.
#
# `agentmail` is stubbed on PATH and driven by env vars. HOME, XDG_CONFIG_HOME,
# and XDG_CACHE_HOME are redirected into a temp dir, so no real config, cache,
# or credential is read or written. No network, no key needed.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/scripts/mail-check.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; return 0; }

command -v python3 >/dev/null 2>&1 || { echo "python3 not installed — skipping"; exit 0; }

if [ ! -f "$HOOK" ]; then
	echo "  ✗ $HOOK does not exist"
	echo "1 passed, 1 failed"; exit 1
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

STUB_BIN="$SANDBOX/bin"
mkdir -p "$STUB_BIN"

KEY="am_us_STUBKEY0123456789abcdef"
INBOX="my-agent@agentmail.to"

# ---------------------------------------------------------------------------
# The stub CLI. STUB_UNREAD sets how many unread messages `list` returns, and
# STUB_NEWEST names the newest message id so a test can change it and watch the
# re-notify logic react. Every invocation is logged, which is how the cooldown
# tests prove no call was made rather than merely that nothing was printed.
# ---------------------------------------------------------------------------
cat > "$STUB_BIN/agentmail" <<'STUB'
#!/usr/bin/env bash
[ -n "${STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$STUB_LOG"

case "${1:-}" in
  --version) echo "agentmail version 0.7.14-stub"; exit 0 ;;
esac

case "${STUB_MODE:-ok}" in
  forbidden)
    echo 'GET "https://api.agentmail.to/v0/inboxes": 403 Forbidden' >&2
    echo '{ "message": "Forbidden" }' >&2
    exit 1 ;;
  garbage)
    echo 'this is not json at all <<<>>>'
    exit 0 ;;
  hang)
    sleep 10
    echo '{}'
    exit 0 ;;
esac

case "$*" in
  *"inboxes list"*)
    printf '{"count":1,"inboxes":[{"inbox_id":"%s","email":"%s","display_name":"Stub"}]}\n' \
      "${STUB_INBOX:-my-agent@agentmail.to}" "${STUB_INBOX:-my-agent@agentmail.to}"
    exit 0 ;;
  *"inboxes:messages list"*)
    n="${STUB_UNREAD:-0}"
    limit=99
    # Honor --limit so the "count is items RETURNED, not items matching" trap is
    # reproduced faithfully: the real API caps the array at the limit.
    limit="$(printf '%s\n' "$*" | sed -n 's/.*--limit \([0-9]*\).*/\1/p')"
    [ -z "$limit" ] && limit=99
    [ "$n" -gt "$limit" ] && n="$limit"
    python3 - "$n" "${STUB_NEWEST:-msg-newest}" "${STUB_PREVIEW:-Preview text for the message body.}" <<'PY'
import json, sys
n = int(sys.argv[1]); newest = sys.argv[2]; preview = sys.argv[3]
msgs = []
for i in range(n):
    msgs.append({
        "inbox_id": "my-agent@agentmail.to",
        "thread_id": "thread-%d" % i,
        "message_id": newest if i == 0 else "msg-%d" % i,
        "labels": ["received", "unread"],
        "timestamp": "2026-08-11T21:2%d:00.000Z" % (i % 10),
        "from": "Sender %d <sender%d@example.com>" % (i, i),
        "to": ["My Agent <my-agent@agentmail.to>"],
        "subject": "Subject number %d" % i,
        "preview": preview,
    })
print(json.dumps({"count": len(msgs), "limit": int(sys.argv[1]), "messages": msgs}))
PY
    exit 0 ;;
esac
echo '{}'
exit 0
STUB
chmod +x "$STUB_BIN/agentmail"

# A PATH with every ordinary tool the hook might use, but deliberately WITHOUT
# python3/python/jq — used to prove the hook degrades silently rather than
# emitting a hand-built JSON string it cannot escape correctly.
NOJSON_BIN="$SANDBOX/nojson"
mkdir -p "$NOJSON_BIN"
for t in bash sh cat date mkdir rm mv chmod grep sed sleep stat cut head tail tr wc sort awk env printf ls find dirname basename mktemp kill pkill; do
	for d in /bin /usr/bin; do
		[ -x "$d/$t" ] && ln -sf "$d/$t" "$NOJSON_BIN/$t" && break
	done
done
ln -sf "$STUB_BIN/agentmail" "$NOJSON_BIN/agentmail"

CASE_N=0
CASE_HOME=""; CONFIG=""; STATE=""; LOG=""

fresh_case() {
	CASE_N=$((CASE_N+1))
	CASE_HOME="$SANDBOX/home-$CASE_N"
	mkdir -p "$CASE_HOME/.config/agentmail" "$CASE_HOME/.cache/agentmail"
	CONFIG="$CASE_HOME/.config/agentmail/mail-check.json"
	STATE="$CASE_HOME/.cache/agentmail/mail-check-state.json"
	LOG="$CASE_HOME/stub.log"
	: > "$LOG"
}

# write_config <json-body>
write_config() { printf '%s\n' "$1" > "$CONFIG"; }

# run [--no-json-tools] [--no-cli] [--no-key] [--harness claude|codex] -- <hook args...>
run() {
	local path="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
	local with_key="yes" harness="" mode="${STUB_MODE_OVERRIDE:-ok}"
	while [ $# -gt 0 ]; do
		case "$1" in
			--no-json-tools) path="$NOJSON_BIN" ;;
			--no-cli) path="/usr/bin:/bin:/usr/sbin:/sbin" ;;
			--no-key) with_key="" ;;
			--harness) shift; harness="$1" ;;
			--) shift; break ;;
		esac
		shift
	done
	env -i \
		HOME="$CASE_HOME" \
		XDG_CONFIG_HOME="$CASE_HOME/.config" \
		XDG_CACHE_HOME="$CASE_HOME/.cache" \
		PATH="$path" \
		STUB_MODE="$mode" \
		STUB_LOG="$LOG" \
		${STUB_UNREAD:+STUB_UNREAD="$STUB_UNREAD"} \
		${STUB_NEWEST:+STUB_NEWEST="$STUB_NEWEST"} \
		${STUB_PREVIEW:+STUB_PREVIEW="$STUB_PREVIEW"} \
		${with_key:+AGENTMAIL_API_KEY="$KEY"} \
		${harness:+$( [ "$harness" = claude ] && echo CLAUDE_CODE_SESSION_ID=sess-1 || echo CODEX_THREAD_ID=thread-1 )} \
		bash "$HOOK" "$@"
	return $?
}

# age_state <seconds-ago> — backdate last_checked_at/last_notified_at so a
# cooldown can be exercised without a production "what time is it" seam.
age_state() {
	python3 - "$STATE" "$1" <<'PY'
import json, sys, time
path, ago = sys.argv[1], int(sys.argv[2])
d = json.load(open(path))
now = int(time.time())
for v in d.get("inboxes", {}).values():
    if v.get("last_checked_at"):
        v["last_checked_at"] = now - ago
    if v.get("last_notified_at"):
        v["last_notified_at"] = now - ago
json.dump(d, open(path, "w"))
PY
}

# json_field <dotted.path> — reads JSON on stdin. The program lives in a file
# because a heredoc would occupy the stdin we need for the piped JSON.
JF="$SANDBOX/json_field.py"
cat > "$JF" <<'JFEOF'
import json, sys
path = sys.argv[1].split(".")
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for p in path:
    if not isinstance(d, dict) or p not in d:
        sys.exit(1)
    d = d[p]
print(d)
JFEOF
json_field() { python3 "$JF" "$1"; }

REMIND='{"version":1,"enabled":true,"mode":"remind","check_every_minutes":15,"list_ceiling":25}'

echo "== silent and zero on every failure =="

# No config at all: installing the plugin must not start making network calls.
fresh_case
out="$(run -- --event UserPromptSubmit)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "no config → silent, exit 0" \
	|| bad "no config should be silent+0, got rc=$rc out='$out'"
[ ! -s "$LOG" ] && ok "no config → no API call at all" || bad "no config still called the API" "$(cat "$LOG")"

for body in \
	'{"version":1,"enabled":false,"mode":"remind"}' \
	'{"version":1,"enabled":true,"mode":"off"}' \
	'{ this is not json' \
	'{"version":1,"enabled":true,"mode":"nonsense"}' ; do
	fresh_case; write_config "$body"; STUB_UNREAD=3
	out="$(run -- --event UserPromptSubmit)"; rc=$?
	label="$(printf '%s' "$body" | cut -c1-42)"
	[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "config '${label}…' → silent, exit 0" \
		|| bad "config '${label}…' should be silent+0, got rc=$rc out='$out'"
	unset STUB_UNREAD
done

fresh_case; write_config "$REMIND"; STUB_UNREAD=3
out="$(run --no-cli -- --event UserPromptSubmit)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "no agentmail CLI → silent, exit 0" \
	|| bad "missing CLI should be silent+0, got rc=$rc out='$out'"

out="$(run --no-key -- --event UserPromptSubmit)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "no API key → silent, exit 0" \
	|| bad "missing key should be silent+0, got rc=$rc out='$out'"

out="$(run --no-json-tools -- --event UserPromptSubmit)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "no python3/jq → silent, exit 0 (never hand-builds JSON)" \
	|| bad "missing JSON tool should be silent+0, got rc=$rc out='$out'"

STUB_MODE_OVERRIDE=forbidden
fresh_case; write_config "$REMIND"
out="$(run -- --event UserPromptSubmit)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "403 from the API → silent, exit 0" \
	|| bad "403 should be silent+0, got rc=$rc out='$out'"
[ -f "$STATE" ] && ok "a failed probe still records last_checked_at (so it cannot retry every prompt)" \
	|| bad "a failed probe wrote no state — the hook would call the API on every prompt"
unset STUB_MODE_OVERRIDE

STUB_MODE_OVERRIDE=garbage
fresh_case; write_config "$REMIND"
out="$(run -- --event UserPromptSubmit)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "unparseable API response → silent, exit 0" \
	|| bad "garbage response should be silent+0, got rc=$rc out='$out'"
unset STUB_MODE_OVERRIDE

STUB_MODE_OVERRIDE=hang
fresh_case; write_config '{"version":1,"enabled":true,"mode":"remind","timeout_seconds":1}'
start="$(date +%s)"
out="$(run -- --event UserPromptSubmit)"; rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "a hanging CLI → silent, exit 0" \
	|| bad "hang should be silent+0, got rc=$rc out='$out'"
[ "$elapsed" -lt 6 ] && ok "a hanging CLI is abandoned in ${elapsed}s (timeout_seconds honored)" \
	|| bad "hang took ${elapsed}s — the hook would stall the session"
unset STUB_MODE_OVERRIDE

fresh_case; write_config "$REMIND"; STUB_UNREAD=3
out="$(run -- --event Frobnicate)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "unknown --event → silent, exit 0 (never a mismatched object)" \
	|| bad "unknown event should be silent+0, got rc=$rc out='$out'"
out="$(run -- )"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "no --event → silent, exit 0" \
	|| bad "missing event should be silent+0, got rc=$rc out='$out'"
unset STUB_UNREAD

fresh_case; write_config "$REMIND"; STUB_UNREAD=0
out="$(run -- --event UserPromptSubmit)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "zero unread → silent, exit 0" \
	|| bad "zero unread should be silent+0, got rc=$rc out='$out'"
grep -q 'inboxes:messages list' "$LOG" && ok "zero unread still made its one check" \
	|| bad "zero unread did not check at all"
unset STUB_UNREAD

echo
echo "== remind mode =="

fresh_case; write_config "$REMIND"; STUB_UNREAD=3
out="$(run --harness claude -- --event UserPromptSubmit)"; rc=$?
[ "$rc" -eq 0 ] && ok "remind with unread mail → exit 0" || bad "remind should exit 0, got $rc"
if printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
	ok "output is exactly one parseable JSON object"
else
	bad "output is not a single JSON object" "$out"
fi
ev="$(printf '%s' "$out" | json_field hookSpecificOutput.hookEventName)"
[ "$ev" = "UserPromptSubmit" ] && ok "hookEventName matches the firing event" \
	|| bad "hookEventName is '$ev', expected UserPromptSubmit"
ctx="$(printf '%s' "$out" | json_field hookSpecificOutput.additionalContext)"
printf '%s' "$ctx" | grep -q '3 unread' && ok "the notice states the unread count" \
	|| bad "the notice does not state the count" "$ctx"
printf '%s' "$ctx" | grep -qF "$INBOX" && ok "the notice names the inbox" \
	|| bad "the notice does not name the inbox" "$ctx"
printf '%s' "$ctx" | grep -qE 'as of [0-9]{2}:[0-9]{2}' \
	&& ok "the notice is timestamped (Claude Code replays injected text on --resume)" \
	|| bad "the notice has no timestamp — a stale replay would read as current" "$ctx"
printf '%s' "$out" | grep -q '"suppressOutput"' && ok "suppressOutput is set" || bad "suppressOutput is not set"

# SessionStart is the other half of the pair and must self-label correctly.
fresh_case; write_config "$REMIND"; STUB_UNREAD=2
out="$(run -- --event SessionStart)"
ev="$(printf '%s' "$out" | json_field hookSpecificOutput.hookEventName)"
[ "$ev" = "SessionStart" ] && ok "SessionStart labels itself SessionStart" \
	|| bad "hookEventName is '$ev', expected SessionStart"
unset STUB_UNREAD

echo
echo "== the count trap: 'count' is items returned, not items matching =="

fresh_case; write_config '{"version":1,"enabled":true,"mode":"remind","list_ceiling":5}'
STUB_UNREAD=99
out="$(run -- --event UserPromptSubmit)"
ctx="$(printf '%s' "$out" | json_field hookSpecificOutput.additionalContext)"
printf '%s' "$ctx" | grep -q '5+' \
	&& ok "at the list ceiling the notice says '5+', not '5'" \
	|| bad "a saturated count is reported as exact — the API returns at most --limit rows" "$ctx"
grep -q -- '--limit 5' "$LOG" && ok "the query asks for the configured ceiling" \
	|| bad "the query did not use list_ceiling" "$(cat "$LOG")"
unset STUB_UNREAD

echo
echo "== auto mode caps what it injects =="

fresh_case
write_config '{"version":1,"enabled":true,"mode":"auto","max_messages":2,"per_message_bytes":40,"max_bytes":600,"list_ceiling":25}'
STUB_UNREAD=6
STUB_PREVIEW="$(python3 -c "print('x'*400)")"
out="$(run -- --event UserPromptSubmit)"; rc=$?
[ "$rc" -eq 0 ] && ok "auto mode → exit 0" || bad "auto should exit 0, got $rc"
ctx="$(printf '%s' "$out" | json_field hookSpecificOutput.additionalContext)"
n_items="$(printf '%s' "$ctx" | grep -cE '^[0-9]+\. ')"
[ "$n_items" -le 2 ] && ok "auto listed $n_items summaries, within max_messages=2" \
	|| bad "auto listed $n_items summaries, exceeding max_messages=2"
bytes="$(printf '%s' "$ctx" | wc -c | tr -d ' ')"
[ "$bytes" -le 600 ] && ok "auto injected ${bytes}B, within max_bytes=600" \
	|| bad "auto injected ${bytes}B, exceeding max_bytes=600"
printf '%s' "$ctx" | grep -q 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' \
	&& bad "a 400-byte preview was injected whole, ignoring per_message_bytes" \
	|| ok "previews are truncated to per_message_bytes"
printf '%s' "$ctx" | grep -qi 'unread state is unchanged' \
	&& ok "auto says it did not mark anything read" \
	|| bad "auto does not state that unread state is untouched" "$ctx"
printf '%s' "$ctx" | grep -qiE 'truncated|full bodies' \
	&& ok "auto warns these are previews, not full bodies" \
	|| bad "auto does not warn that previews are not full bodies" "$ctx"
unset STUB_PREVIEW

# A byte cap applied naively splits a multibyte character and the harness's JSON
# parse fails on the result.
fresh_case
write_config '{"version":1,"enabled":true,"mode":"auto","max_messages":3,"per_message_bytes":25,"max_bytes":900}'
STUB_UNREAD=3
STUB_PREVIEW="$(python3 -c "print('é'*80)")"
out="$(run -- --event UserPromptSubmit)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
	ok "truncating a multibyte preview still yields valid JSON/UTF-8"
else
	bad "multibyte truncation broke the output" "$out"
fi
unset STUB_PREVIEW STUB_UNREAD

echo
echo "== the cooldown really prevents calls, not just output =="

fresh_case; write_config "$REMIND"; STUB_UNREAD=3
run -- --event UserPromptSubmit >/dev/null
: > "$LOG"
out="$(run -- --event UserPromptSubmit)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "a second prompt inside check_every_minutes is silent" \
	|| bad "a second prompt inside the cooldown produced output" "$out"
# The cooldown is checked BEFORE the CLI is touched, so an in-cooldown prompt
# spawns nothing at all — not even the local --version probe.
[ ! -s "$LOG" ] && ok "…and invoked agentmail zero times (the cooldown gates the call, not the print)" \
	|| bad "the cooldown printed nothing but still invoked the CLI" "$(cat "$LOG")"

# SessionStart must not be silenced by another session's recent check — it has
# its own, much shorter floor.
fresh_case; write_config '{"version":1,"enabled":true,"mode":"remind","check_every_minutes":15,"session_start_floor_seconds":60}'
STUB_UNREAD=3
run -- --event UserPromptSubmit >/dev/null
age_state 120
: > "$LOG"
run -- --event SessionStart >/dev/null
grep -q 'inboxes:messages list' "$LOG" \
	&& ok "SessionStart bypasses check_every_minutes once past its own floor" \
	|| bad "SessionStart was silenced by another session's cooldown" "$(cat "$LOG")"

fresh_case; write_config '{"version":1,"enabled":true,"mode":"remind","session_start_floor_seconds":600}'
STUB_UNREAD=3
run -- --event SessionStart >/dev/null
: > "$LOG"
out="$(run -- --event SessionStart)"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "SessionStart still honors its own floor" \
	|| bad "SessionStart ignored session_start_floor_seconds" "$out"
[ ! -s "$LOG" ] && ok "…and made no API call inside the floor" || bad "SessionStart called inside its floor"
unset STUB_UNREAD

echo
echo "== re-notify only on new mail, or after renotify_after_minutes =="

fresh_case
write_config '{"version":1,"enabled":true,"mode":"remind","check_every_minutes":0,"renotify_after_minutes":120}'
STUB_UNREAD=3; STUB_NEWEST=msg-alpha
out="$(run -- --event UserPromptSubmit)"
[ -n "$out" ] && ok "first sighting notifies" || bad "first sighting did not notify"
out="$(run -- --event UserPromptSubmit)"
[ -z "$out" ] && ok "same newest message inside renotify window → silent (no nagging)" \
	|| bad "the same unread mail was announced twice" "$out"

STUB_NEWEST=msg-beta
out="$(run -- --event UserPromptSubmit)"
[ -n "$out" ] && ok "a NEW newest message re-notifies immediately" \
	|| bad "new mail arrived and the hook stayed quiet"

STUB_NEWEST=msg-beta
age_state 7300
out="$(run -- --event UserPromptSubmit)"
[ -n "$out" ] && ok "past renotify_after_minutes the same mail is raised again" \
	|| bad "renotify_after_minutes never fires"
unset STUB_UNREAD STUB_NEWEST

echo
echo "== state file hygiene =="

fresh_case; write_config "$REMIND"; STUB_UNREAD=3
run -- --event UserPromptSubmit >/dev/null
if [ -f "$STATE" ]; then
	ok "state file written"
	python3 -c "import json,sys; json.load(open('$STATE'))" 2>/dev/null \
		&& ok "state file is valid JSON" || bad "state file is not valid JSON"
	m="$(python3 -c "import os,stat; print(oct(stat.S_IMODE(os.stat('$STATE').st_mode)))")"
	[ "$m" = "0o600" ] && ok "state file is mode 600" || bad "state file is $m, expected 0o600"
	case "$STATE" in
		"$PLUGIN_ROOT"*) bad "state was written inside the repo" ;;
		*) ok "state is outside the repository" ;;
	esac
	python3 -c "
import json,sys
d=json.load(open('$STATE'))
inb=d.get('inboxes',{})
sys.exit(0 if '$INBOX' in inb and inb['$INBOX'].get('newest_message_id') else 1)" 2>/dev/null \
		&& ok "state is keyed per inbox and records newest_message_id" \
		|| bad "state does not record per-inbox newest_message_id" "$(cat "$STATE")"
else
	bad "no state file was written"
fi

# The inbox id is resolved once and cached; re-resolving it every prompt would
# double the API cost of the cheapest possible check.
: > "$LOG"
age_state 99999
run -- --event UserPromptSubmit >/dev/null
if grep -q 'inboxes list' "$LOG"; then
	bad "the inbox id was re-resolved despite being cached" "$(cat "$LOG")"
else
	ok "a cached inbox id is reused instead of re-resolved"
fi
unset STUB_UNREAD

echo
echo "== the key never appears anywhere =="

fresh_case; write_config "$REMIND"; STUB_UNREAD=3
out="$(run -- --event UserPromptSubmit)"
printf '%s' "$out" | grep -qF "$KEY" && bad "the hook printed the API key" \
	|| ok "the key is absent from hook output"
grep -rqF "$KEY" "$CASE_HOME/.cache" 2>/dev/null && bad "the key was written into the state dir" \
	|| ok "the key is absent from the state file"
grep -qF "$KEY" "$CONFIG" 2>/dev/null && bad "the key was written into the config" \
	|| ok "the key is absent from the config file"
if grep -vE '^[[:space:]]*#' "$HOOK" | grep -qE '(echo|printf)[^#]*AGENTMAIL_API_KEY'; then
	bad "the hook prints AGENTMAIL_API_KEY"
else
	ok "no executable line in the hook prints the key"
fi
unset STUB_UNREAD

echo
echo "== harness-aware invocation hint =="

fresh_case; write_config "$REMIND"; STUB_UNREAD=3
ctx="$(run --harness claude -- --event UserPromptSubmit | json_field hookSpecificOutput.additionalContext)"
printf '%s' "$ctx" | grep -q '/agentmail:check-mail' \
	&& ok "under Claude Code the hint uses /agentmail:" || bad "no /agentmail: hint under Claude Code" "$ctx"

fresh_case; write_config "$REMIND"; STUB_UNREAD=3
ctx="$(run --harness codex -- --event UserPromptSubmit | json_field hookSpecificOutput.additionalContext)"
printf '%s' "$ctx" | grep -q '\$agentmail:check-mail' \
	&& ok "under Codex the hint uses \$agentmail:" || bad "no \$agentmail: hint under Codex" "$ctx"

fresh_case; write_config "$REMIND"; STUB_UNREAD=3
ctx="$(run -- --event UserPromptSubmit | json_field hookSpecificOutput.additionalContext)"
if printf '%s' "$ctx" | grep -qE '/agentmail:|\$agentmail:'; then
	bad "with no harness marker the hook guessed a client syntax" "$ctx"
else
	ok "with no harness marker it names no client-specific syntax"
fi
unset STUB_UNREAD

echo
echo "== --init is the one-gesture activation =="

fresh_case
rm -f "$CONFIG"
out="$(run -- --init)"; rc=$?
[ "$rc" -eq 0 ] && ok "--init → exit 0" || bad "--init should exit 0, got $rc: $out"
[ -f "$CONFIG" ] && ok "--init wrote the config" || bad "--init wrote no config"
python3 -c "import json; d=json.load(open('$CONFIG')); assert d['mode']=='remind'" 2>/dev/null \
	&& ok "--init defaults to remind mode" || bad "--init did not default to remind" "$(cat "$CONFIG" 2>/dev/null)"
printf '%s' "$out" | grep -qF "$CONFIG" && ok "--init prints where it wrote" \
	|| bad "--init does not say what it wrote or where" "$out"

out="$(run -- --init)"; rc=$?
[ "$rc" -eq 4 ] && ok "--init over an existing config → exit 4" || bad "--init should refuse with 4, got $rc"

fresh_case
rm -f "$CONFIG"
out="$(run -- --init --mode auto)"; rc=$?
python3 -c "import json; d=json.load(open('$CONFIG')); assert d['mode']=='auto'" 2>/dev/null \
	&& ok "--init --mode auto honors the mode" || bad "--init --mode auto did not set auto"
out="$(run -- --init --mode sideways)"; rc=$?
[ "$rc" -eq 64 ] && ok "--init with a bad mode → exit 64" || bad "bad --init mode should exit 64, got $rc"

# Activation must not silently start a session's worth of checks.
fresh_case
rm -f "$CONFIG"
: > "$LOG"
run -- --init >/dev/null
[ ! -s "$LOG" ] && ok "--init makes no API call" || bad "--init called the API" "$(cat "$LOG")"

echo
echo "== hooks.json =="

if [ -f "$HOOKS_JSON" ]; then
	ok "hooks/hooks.json exists"
	python3 - "$HOOKS_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
hooks = d["hooks"]
# Only events supported by BOTH Claude Code and Codex. `Stop` is excluded on
# purpose: Claude Code does not add Stop stdout to context, and Stop's
# additionalContext continues the conversation instead of informing it.
allowed = {"SessionStart", "UserPromptSubmit", "PreCompact", "PostCompact",
           "PreToolUse", "PostToolUse", "SessionEnd", "SubagentStart", "SubagentStop"}
problems = []
if set(hooks) - allowed:
    problems.append("unsupported events: %s" % (set(hooks) - allowed))
if "UserPromptSubmit" not in hooks or "SessionStart" not in hooks:
    problems.append("must register both SessionStart and UserPromptSubmit")
for event, groups in hooks.items():
    for g in groups:
        if event == "UserPromptSubmit" and "matcher" in g:
            problems.append("UserPromptSubmit has a matcher (unsupported on that event)")
        for h in g.get("hooks", []):
            if "${CLAUDE_PLUGIN_ROOT}" not in h.get("command", ""):
                problems.append("%s command is not anchored at CLAUDE_PLUGIN_ROOT" % event)
            if not isinstance(h.get("timeout"), int):
                problems.append("%s hook has no integer timeout" % event)
            if "--event %s" % event not in h.get("command", ""):
                problems.append("%s command does not pass --event %s" % (event, event))
if problems:
    print("; ".join(problems))
    sys.exit(1)
PY
	if [ $? -eq 0 ]; then
		ok "hooks.json registers both events correctly, anchored and timed out"
	else
		bad "hooks.json is wrong (see above)"
	fi
	grep -q 'mail-check.sh' "$HOOKS_JSON" && ok "hooks.json points at mail-check.sh" \
		|| bad "hooks.json does not reference mail-check.sh"
	grep -q '|| true' "$HOOKS_JSON" && ok "hook commands are suffixed with '|| true'" \
		|| bad "hook commands can fail the event"
else
	bad "hooks/hooks.json does not exist"
fi

echo
echo "== the hook cannot mutate the inbox =="

fresh_case; write_config '{"version":1,"enabled":true,"mode":"auto","max_messages":3}'
STUB_UNREAD=3
run -- --event UserPromptSubmit >/dev/null
if grep -qE 'messages update|add-label|remove-label|drafts|send|reply|forward|delete' "$LOG"; then
	bad "the hook issued a mutating command" "$(cat "$LOG")"
else
	ok "the hook only ever listed — no update, label, draft, send, or delete"
fi
if grep -vE '^[[:space:]]*#' "$HOOK" | grep -qE 'agentmail [^|]*(send|reply|forward|delete|update|drafts)'; then
	bad "the hook source contains a mutating agentmail command"
else
	ok "no mutating agentmail command appears in the hook source"
fi
unset STUB_UNREAD

echo
echo "== every exit is zero =="

# A non-zero exit from a UserPromptSubmit hook blocks the prompt. Nothing this
# hook can encounter is worth doing that for.
#
# `--init` is an interactive admin command in the same file and legitimately
# exits 4 and 64, so this checks only the region after the hook-path marker. The
# marker is required: without it the two paths cannot be told apart, and an
# unreviewable grep over the whole file would either miss a real bug or ban a
# correct exit.
MARKER='=== hook path'
if grep -q "$MARKER" "$HOOK"; then
	ok "the hook marks where its unattended path begins"
	hookpath="$(awk "/$MARKER/{f=1} f" "$HOOK" | grep -vE '^[[:space:]]*#')"
	if printf '%s\n' "$hookpath" | grep -qE '^[[:space:]]*exit[[:space:]]+[1-9]'; then
		bad "the unattended hook path has a non-zero exit" \
			"$(printf '%s\n' "$hookpath" | grep -nE '^[[:space:]]*exit[[:space:]]+[1-9]')"
	else
		ok "no non-zero exit anywhere in the unattended hook path"
	fi
	# And `set -e` would turn any unchecked command into one.
	if printf '%s\n' "$hookpath" | grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*e'; then
		bad "the hook enables 'set -e' — any unchecked command becomes a blocked prompt"
	else
		ok "the hook does not enable 'set -e'"
	fi
else
	bad "the hook has no '$MARKER' marker separating admin exits from the hook path"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
