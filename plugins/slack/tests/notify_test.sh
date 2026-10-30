#!/usr/bin/env bash
# =============================================================================
# Tests for notify-slack's notify.sh — webhook resolution, payload construction,
# input precedence, guardrails, and response handling.
#
# No test reaches Slack. The send-path cases stub `curl` via PATH so the exact
# curl invocation (including the config fed on stdin) can be asserted, and the
# environment is scrubbed of every SLACK_WEBHOOK_* variable so a real webhook in
# the developer's shell can never be picked up or posted to.
#
# Usage: bash plugins/slack/tests/notify_test.sh
# Exit 0 on success; exit 1 with failing case names on any failure.
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="$SCRIPT_DIR/../skills/notify-slack/scripts/notify.sh"

PASS=0
FAIL=0
FAILED_CASES=()

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Never inherit a real webhook from the developer's shell.
while IFS='=' read -r var _; do
  [[ -n "$var" ]] && unset "$var"
done < <(env | grep -E '^SLACK_WEBHOOK' || true)
# The suite runs inside Claude Code sessions, which set this; the session-link
# cases below set it explicitly.
unset CLAUDE_CODE_BRIDGE_SESSION_ID

# Deliberately NOT shaped like a real webhook URL: GitHub push protection flags
# realistic placeholders as leaked secrets, so this only needs to satisfy the
# script's https://hooks.slack.com/ prefix check.
FAKE_URL="https://hooks.slack.com/services/EXAMPLE-TEAM/EXAMPLE-HOOK/secret-tail-sentinel"

# ---- curl stub --------------------------------------------------------------
# Records the stdin config to $SANDBOX/curl-config, writes the canned body to
# whatever `output = "…"` names, and prints the canned HTTP status.
STUB_DIR="$SANDBOX/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_SANDBOX/curl-argv"
config="$(cat)"
printf '%s' "$config" > "$STUB_SANDBOX/curl-config"
out="$(printf '%s' "$config" | sed -n 's/^output = "\(.*\)"$/\1/p')"
[[ -n "$out" ]] && printf '%s' "${STUB_BODY-ok}" > "$out"
printf '%s' "${STUB_CODE:-200}"
STUB
chmod +x "$STUB_DIR/curl"
export STUB_SANDBOX="$SANDBOX"

# run_stubbed <env-assignments…> -- <args…>  → stdout+stderr in $OUT, status in $STATUS
run_stubbed() {
  OUT="$(PATH="$STUB_DIR:$PATH" "$@" 2>&1)"
  STATUS=$?
}

# ---- config resolution ------------------------------------------------------

OUT="$(bash "$NOTIFY" 'hello' 2>&1)"; STATUS=$?
if [[ $STATUS -ne 0 ]] && grep -q "SLACK_WEBHOOK_URL" <<<"$OUT"; then
  pass "no webhook configured is a fatal error naming the variable"
else
  fail "no webhook configured is a fatal error naming the variable (status $STATUS: $OUT)"
fi

OUT="$(SLACK_WEBHOOK_URL="https://evil.example.com/services/x" bash "$NOTIFY" --check 2>&1)"; STATUS=$?
if [[ $STATUS -ne 0 ]] && grep -q "hooks.slack.com" <<<"$OUT"; then
  pass "a non-hooks.slack.com URL is refused before any request"
else
  fail "a non-hooks.slack.com URL is refused before any request (status $STATUS: $OUT)"
fi

OUT="$(SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --check 2>&1)"; STATUS=$?
if [[ $STATUS -eq 0 ]] && grep -q "SLACK_WEBHOOK_URL" <<<"$OUT"; then
  pass "--check passes on a valid URL and names its source"
else
  fail "--check passes on a valid URL and names its source (status $STATUS: $OUT)"
fi

if ! grep -q "secret-tail-sentinel" <<<"$OUT"; then
  pass "--check never prints the webhook's secret tail"
else
  fail "--check never prints the webhook's secret tail (output: $OUT)"
fi

if grep -qi "does not prove" <<<"$OUT"; then
  pass "--check says plainly that delivery is unproven"
else
  fail "--check says plainly that delivery is unproven (output: $OUT)"
fi

OUT="$(SLACK_WEBHOOK_URL_ALERTS="$FAKE_URL" bash "$NOTIFY" --to alerts --check 2>&1)"; STATUS=$?
if [[ $STATUS -eq 0 ]] && grep -q "SLACK_WEBHOOK_URL_ALERTS" <<<"$OUT"; then
  pass "--to <name> resolves the suffixed variable"
else
  fail "--to <name> resolves the suffixed variable (status $STATUS: $OUT)"
fi

OUT="$(SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --to alerts --check 2>&1)"; STATUS=$?
if [[ $STATUS -ne 0 ]] && grep -q "SLACK_WEBHOOK_URL_ALERTS" <<<"$OUT"; then
  pass "--to does NOT silently fall back to the default webhook"
else
  fail "--to does NOT silently fall back to the default webhook (status $STATUS: $OUT)"
fi

# ---- payload construction (--dry-run makes no network call) -----------------

OUT="$(SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run 'plain text' 2>&1)"; STATUS=$?
PAYLOAD="$(sed -n '/^{/,$p' <<<"$OUT")"
if [[ $STATUS -eq 0 ]] && [[ "$(jq -r '.text' <<<"$PAYLOAD")" == "plain text" ]]; then
  pass "a positional argument becomes the text field"
else
  fail "a positional argument becomes the text field (status $STATUS: $OUT)"
fi

if [[ "$(jq -r 'keys | join(",")' <<<"$PAYLOAD")" == "text" ]]; then
  pass "a plain send carries only the text key"
else
  fail "a plain send carries only the text key (got: $(jq -c 'keys' <<<"$PAYLOAD"))"
fi

printf 'line one\nline two\n\n\n' > "$SANDBOX/msg.txt"
OUT="$(SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run --text-file "$SANDBOX/msg.txt" 2>&1)"
PAYLOAD="$(sed -n '/^{/,$p' <<<"$OUT")"
if [[ "$(jq -r '.text' <<<"$PAYLOAD")" == "line one
line two" ]]; then
  pass "--text-file preserves interior newlines and trims trailing ones"
else
  fail "--text-file preserves interior newlines and trims trailing ones (got: $(jq -c '.text' <<<"$PAYLOAD"))"
fi

OUT="$(printf 'from stdin' | SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run 2>&1)"
PAYLOAD="$(sed -n '/^{/,$p' <<<"$OUT")"
if [[ "$(jq -r '.text' <<<"$PAYLOAD")" == "from stdin" ]]; then
  pass "text is read from stdin when no argument is given"
else
  fail "text is read from stdin when no argument is given (got: $OUT)"
fi

OUT="$(printf 'from stdin' | SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run --text-file "$SANDBOX/msg.txt" 2>&1)"
PAYLOAD="$(sed -n '/^{/,$p' <<<"$OUT")"
if [[ "$(jq -r '.text' <<<"$PAYLOAD")" == line*one* ]]; then
  pass "--text-file wins over stdin"
else
  fail "--text-file wins over stdin (got: $(jq -c '.text' <<<"$PAYLOAD"))"
fi

OUT="$(SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run --thread-ts 1763502924.627409 'reply' 2>&1)"
PAYLOAD="$(sed -n '/^{/,$p' <<<"$OUT")"
if [[ "$(jq -r '.thread_ts' <<<"$PAYLOAD")" == "1763502924.627409" ]]; then
  pass "--thread-ts lands in the payload"
else
  fail "--thread-ts lands in the payload (got: $OUT)"
fi

OUT="$(SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run --thread-ts 'not-a-ts' 'reply' 2>&1)"; STATUS=$?
if [[ $STATUS -ne 0 ]]; then
  pass "a malformed --thread-ts is rejected"
else
  fail "a malformed --thread-ts is rejected (status $STATUS: $OUT)"
fi

printf '[{"type":"section","text":{"type":"mrkdwn","text":"hi"}}]' > "$SANDBOX/blocks.json"
OUT="$(SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run --text 'fallback' --blocks-file "$SANDBOX/blocks.json" 2>&1)"
PAYLOAD="$(sed -n '/^{/,$p' <<<"$OUT")"
if [[ "$(jq -r '.blocks[0].type' <<<"$PAYLOAD")" == "section" ]] \
   && [[ "$(jq -r '.text' <<<"$PAYLOAD")" == "fallback" ]]; then
  pass "--blocks-file is embedded as an array beside the fallback text"
else
  fail "--blocks-file is embedded as an array beside the fallback text (got: $OUT)"
fi

printf '{"type":"section"}' > "$SANDBOX/blocks-obj.json"
OUT="$(SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run --text 'x' --blocks-file "$SANDBOX/blocks-obj.json" 2>&1)"; STATUS=$?
if [[ $STATUS -ne 0 ]] && grep -q "array" <<<"$OUT"; then
  pass "a --blocks-file that isn't a JSON array is rejected"
else
  fail "a --blocks-file that isn't a JSON array is rejected (status $STATUS: $OUT)"
fi

# ---- Remote Control session link --------------------------------------------

LINK='<https://claude.ai/code/session_TEST01|Open Claude session>'

OUT="$(CLAUDE_CODE_BRIDGE_SESSION_ID=session_TEST01 SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run 'done' 2>&1)"
PAYLOAD="$(sed -n '/^{/,$p' <<<"$OUT")"
if [[ "$(jq -r '.text' <<<"$PAYLOAD")" == "done"$'\n'"$LINK" ]]; then
  pass "a Remote Control session's link is appended as the final line"
else
  fail "a Remote Control session's link is appended as the final line (got: $(jq -c '.text' <<<"$PAYLOAD"))"
fi

OUT="$(SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run 'done' 2>&1)"
PAYLOAD="$(sed -n '/^{/,$p' <<<"$OUT")"
if [[ "$(jq -r '.text' <<<"$PAYLOAD")" == "done" ]]; then
  pass "no link is added outside a Remote Control session"
else
  fail "no link is added outside a Remote Control session (got: $(jq -c '.text' <<<"$PAYLOAD"))"
fi

OUT="$(CLAUDE_CODE_BRIDGE_SESSION_ID=session_TEST01 SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run --no-session-link 'done' 2>&1)"
PAYLOAD="$(sed -n '/^{/,$p' <<<"$OUT")"
if [[ "$(jq -r '.text' <<<"$PAYLOAD")" == "done" ]]; then
  pass "--no-session-link suppresses the link"
else
  fail "--no-session-link suppresses the link (got: $(jq -c '.text' <<<"$PAYLOAD"))"
fi

OUT="$(CLAUDE_CODE_BRIDGE_SESSION_ID=session_TEST01 SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run 'done <https://claude.ai/code/session_TEST01|Open overseer session>' 2>&1)"
PAYLOAD="$(sed -n '/^{/,$p' <<<"$OUT")"
if [[ "$(jq -r '.text' <<<"$PAYLOAD")" == 'done <https://claude.ai/code/session_TEST01|Open overseer session>' ]]; then
  pass "text that already links this session gets no second link"
else
  fail "text that already links this session gets no second link (got: $(jq -c '.text' <<<"$PAYLOAD"))"
fi

OUT="$(CLAUDE_CODE_BRIDGE_SESSION_ID='session_x>|evil' SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run 'done' 2>&1)"
PAYLOAD="$(sed -n '/^{/,$p' <<<"$OUT")"
if [[ "$(jq -r '.text' <<<"$PAYLOAD")" == "done" ]]; then
  pass "a session id that isn't session_<alnum> is never spliced into mrkdwn"
else
  fail "a session id that isn't session_<alnum> is never spliced into mrkdwn (got: $(jq -c '.text' <<<"$PAYLOAD"))"
fi

OUT="$(CLAUDE_CODE_BRIDGE_SESSION_ID=session_TEST01 SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run --text 'fallback' --blocks-file "$SANDBOX/blocks.json" 2>&1)"
PAYLOAD="$(sed -n '/^{/,$p' <<<"$OUT")"
if [[ "$(jq -r '.blocks | length' <<<"$PAYLOAD")" == "2" ]] \
   && [[ "$(jq -r '.blocks[-1].type' <<<"$PAYLOAD")" == "context" ]] \
   && [[ "$(jq -r '.blocks[-1].elements[0].text' <<<"$PAYLOAD")" == "$LINK" ]]; then
  pass "a Block Kit message gets the link as a trailing context block"
else
  fail "a Block Kit message gets the link as a trailing context block (got: $(jq -c '.blocks' <<<"$PAYLOAD"))"
fi

# ---- guardrails -------------------------------------------------------------

OUT="$(SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run --text '' </dev/null 2>&1)"; STATUS=$?
if [[ $STATUS -ne 0 ]]; then
  pass "an empty message is refused"
else
  fail "an empty message is refused (status $STATUS: $OUT)"
fi

# 40,001 bytes — one past Slack's documented text limit.
OUT="$(head -c 40001 /dev/zero | tr '\0' 'a' | SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run 2>&1)"; STATUS=$?
if [[ $STATUS -ne 0 ]] && grep -q "40000" <<<"$OUT"; then
  pass "text past Slack's 40,000-byte limit is refused, not truncated"
else
  fail "text past Slack's 40,000-byte limit is refused, not truncated (status $STATUS: $OUT)"
fi

OUT="$(SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run --bogus-flag 'x' 2>&1)"; STATUS=$?
if [[ $STATUS -ne 0 ]] && grep -q "Unknown option" <<<"$OUT"; then
  pass "an unknown option is a hard error"
else
  fail "an unknown option is a hard error (status $STATUS: $OUT)"
fi

rm -f "$SANDBOX/curl-config"
OUT="$(SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --dry-run 'x' 2>&1)"
if [[ ! -f "$SANDBOX/curl-config" ]]; then
  pass "--dry-run makes no request at all"
else
  fail "--dry-run makes no request at all (curl was invoked)"
fi

# ---- send path (stubbed curl) -----------------------------------------------

run_stubbed env SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" 'shipped'
if [[ $STATUS -eq 0 ]] && grep -q "Sent to Slack" <<<"$OUT"; then
  pass "HTTP 200 + 'ok' reports a successful send"
else
  fail "HTTP 200 + 'ok' reports a successful send (status $STATUS: $OUT)"
fi

CONFIG="$(cat "$SANDBOX/curl-config")"
if grep -q "^url = \"$FAKE_URL\"$" <<<"$CONFIG"; then
  pass "the webhook URL is passed via the stdin config, not argv"
else
  fail "the webhook URL is passed via the stdin config, not argv (config: $CONFIG)"
fi

if grep -q 'header = "Content-type: application/json"' <<<"$CONFIG"; then
  pass "the request declares a JSON content type"
else
  fail "the request declares a JSON content type (config: $CONFIG)"
fi

run_stubbed env STUB_CODE=404 STUB_BODY=no_service SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" 'x'
if [[ $STATUS -ne 0 ]] && grep -q "no_service" <<<"$OUT" && grep -qi "revoke" <<<"$OUT"; then
  pass "a revoked webhook fails with Slack's error and a regenerate hint"
else
  fail "a revoked webhook fails with Slack's error and a regenerate hint (status $STATUS: $OUT)"
fi

run_stubbed env STUB_CODE=403 STUB_BODY=action_prohibited SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" 'x'
if [[ $STATUS -ne 0 ]] && grep -qi "admin" <<<"$OUT"; then
  pass "an admin-restricted post fails with a do-not-retry hint"
else
  fail "an admin-restricted post fails with a do-not-retry hint (status $STATUS: $OUT)"
fi

run_stubbed env STUB_CODE=200 STUB_BODY=something_unexpected SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" 'x'
if [[ $STATUS -ne 0 ]] && grep -q "something_unexpected" <<<"$OUT"; then
  pass "HTTP 200 with a non-'ok' body is a failure, reported verbatim"
else
  fail "HTTP 200 with a non-'ok' body is a failure, reported verbatim (status $STATUS: $OUT)"
fi

run_stubbed env STUB_CODE=500 STUB_BODY= SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" 'x'
if [[ $STATUS -ne 0 ]] && grep -q "empty response" <<<"$OUT"; then
  pass "an empty error body is still reported rather than read as success"
else
  fail "an empty error body is still reported rather than read as success (status $STATUS: $OUT)"
fi

# ---- the message body never reaches argv ------------------------------------
# docs/compounding.md: payloads ride files or stdin, never argv — argv is
# ps-visible to every local user for the process lifetime.

SENTINEL="payload-sentinel-must-not-reach-argv"
run_stubbed env SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" --text "$SENTINEL"
if ! grep -q "$SENTINEL" "$SANDBOX/curl-argv"; then
  pass "the message body never appears in curl's argv"
else
  fail "the message body never appears in curl's argv (argv: $(cat "$SANDBOX/curl-argv"))"
fi

if ! grep -q "$SENTINEL" "$SANDBOX/curl-config"; then
  pass "the message body is not inlined into the curl config either"
else
  fail "the message body is not inlined into the curl config either"
fi

if grep -q '^data-binary = "@' "$SANDBOX/curl-config"; then
  pass "the message body rides a file referenced by the curl config"
else
  fail "the message body rides a file referenced by the curl config (config: $(cat "$SANDBOX/curl-config"))"
fi

# ---- the text limit has one source ------------------------------------------
# docs/compounding.md: each constant has one source; where a doc must state the
# fact, a canary asserts agreement. MAX_TEXT lives in notify.sh; SKILL.md and
# the plugin README both quote it in prose.

SCRIPT_MAX="$(sed -n 's/^MAX_TEXT=\([0-9]*\)$/\1/p' "$NOTIFY")"
if [[ "$SCRIPT_MAX" =~ ^[0-9]+$ ]]; then
  pass "MAX_TEXT is readable from notify.sh (found: $SCRIPT_MAX)"
else
  fail "MAX_TEXT is readable from notify.sh (found: '$SCRIPT_MAX')"
fi

# 40000 -> "40,000", the form the docs use. awk, not a sed label loop: BSD sed
# rejects ':a;…;ta' written on one line, so that form fails on macOS.
PRETTY_MAX="$(awk -v n="$SCRIPT_MAX" 'BEGIN { s = n; out = ""
  while (length(s) > 3) { out = "," substr(s, length(s) - 2) out; s = substr(s, 1, length(s) - 3) }
  print s out }')"
for doc in "$SCRIPT_DIR/../skills/notify-slack/SKILL.md" "$SCRIPT_DIR/../README.md"; do
  label="$(basename "$doc")"
  if grep -q "$PRETTY_MAX" "$doc"; then
    pass "$label quotes the limit that notify.sh actually enforces ($PRETTY_MAX)"
  else
    fail "$label quotes the limit that notify.sh actually enforces ($PRETTY_MAX not found — MAX_TEXT changed without the doc)"
  fi
done

# One send, one request — no retry loop hiding behind a failure.
rm -f "$SANDBOX/curl-count"
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'x' >> "$STUB_SANDBOX/curl-count"
out=""
printf '404'
STUB
chmod +x "$STUB_DIR/curl"
run_stubbed env SLACK_WEBHOOK_URL="$FAKE_URL" bash "$NOTIFY" 'x'
if [[ "$(wc -c < "$SANDBOX/curl-count" | tr -d ' ')" == "1" ]]; then
  pass "a failed send is attempted exactly once"
else
  fail "a failed send is attempted exactly once (attempts: $(wc -c < "$SANDBOX/curl-count" | tr -d ' '))"
fi

# ---- summary ----------------------------------------------------------------

echo ""
echo "$PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf 'Failed: %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
