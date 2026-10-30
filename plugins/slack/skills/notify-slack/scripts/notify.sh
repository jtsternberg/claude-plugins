#!/usr/bin/env bash
# =============================================================================
# notify.sh — post a message to Slack via an incoming webhook
#
# Usage:
#   notify.sh [options] [text]        Post a message (text also accepted on stdin)
#   notify.sh --check [options]       Validate local config; makes NO network call
#
# Options:
#   --to <name>          Use the webhook named SLACK_WEBHOOK_URL_<NAME> rather
#                        than the unsuffixed default. Name it for what the
#                        notifications are FOR, not for its current channel.
#   --text <string>      Message text.
#   --text-file <path>   Read message text from a file (keeps it out of argv).
#   --blocks-file <path> JSON array of Block Kit blocks; --text becomes the
#                        notification/fallback line.
#   --thread-ts <ts>     Post as a reply in the thread with this parent ts.
#   --no-session-link    Don't append this Claude session's Remote Control link.
#   --dry-run            Print the JSON payload and the destination; send nothing.
#
# Text resolution order: --text-file, --text, positional arg, stdin.
#
# Session link: when run from a Claude Code session with Remote Control on
# ($CLAUDE_CODE_BRIDGE_SESSION_ID set), a "<https://claude.ai/code/…|Open Claude
# session>" link is appended as the message's last line (or, with --blocks-file,
# as a trailing context block) so the reader can jump into that session. Skipped
# when the text already links the same session.
#
# Auth: with --to <name>, resolves the webhook URL from SLACK_WEBHOOK_URL_<NAME>
# or a 1Password ref in SLACK_WEBHOOK_OP_REF_<NAME> via `op read` — name each
# webhook for the ROLE its notifications play, since the URL says nothing and
# the channel behind it can be re-pointed. With no --to, the unsuffixed
# SLACK_WEBHOOK_URL / SLACK_WEBHOOK_OP_REF are used.
# The URL is handed to curl on stdin (--config -) so it never appears in argv /
# `ps` / shell history — it is a bearer secret, and Slack revokes leaked ones.
#
# Deps: curl, jq. (op only if a *_OP_REF var is used.)
# =============================================================================
set -euo pipefail

WEBHOOK_URL=""
WEBHOOK_SOURCE=""   # human-readable description of where the URL came from
TARGET=""           # --to name, empty for the default webhook
TEXT=""
TEXT_FILE=""
BLOCKS_FILE=""
THREAD_TS=""
DRY_RUN=0
CHECK=0
SESSION_LINK=1
POSITIONAL=""

# Slack's documented maximum for a message's `text` field.
MAX_TEXT=40000

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

# ---- webhook URL resolution -------------------------------------------------

# resolve_webhook — fill WEBHOOK_URL/WEBHOOK_SOURCE from the environment.
#
# An incoming webhook URL is bound to one channel at install time and cannot be
# retargeted by the payload, so several destinations means several URLs. The
# --to suffix convention is how a caller picks between them by role.
resolve_webhook() {
	local url_var="SLACK_WEBHOOK_URL" ref_var="SLACK_WEBHOOK_OP_REF" suffix=""
	if [[ -n "$TARGET" ]]; then
		# Uppercase, and map the characters legal in a name but not in a shell
		# variable (-, ., space) onto _.
		suffix="$(printf '%s' "$TARGET" | tr '[:lower:]' '[:upper:]' | tr -- '-. ' '___')"
		[[ "$suffix" =~ ^[A-Z0-9_]+$ ]] || die "--to name must be alphanumeric (plus - . _): got '$TARGET'"
		url_var="SLACK_WEBHOOK_URL_$suffix"
		ref_var="SLACK_WEBHOOK_OP_REF_$suffix"
	fi

	if [[ -n "${!ref_var:-}" ]]; then
		command -v op >/dev/null 2>&1 || die "$ref_var is set but the 1Password CLI (op) is not installed."
		WEBHOOK_URL="$(op read "${!ref_var}")" || die "Failed to read webhook URL from 1Password ref: ${!ref_var}"
		WEBHOOK_SOURCE="$ref_var (1Password)"
	elif [[ -n "${!url_var:-}" ]]; then
		WEBHOOK_URL="${!url_var}"
		WEBHOOK_SOURCE="$url_var"
	elif [[ -n "$TARGET" ]]; then
		die "No webhook for --to $TARGET. Set $url_var=https://hooks.slack.com/services/… (or $ref_var to a 1Password op:// ref). See the plugin README."
	else
		die "No webhook URL. Name one for what the notifications are for — export SLACK_WEBHOOK_URL_<NAME>=https://hooks.slack.com/services/… (or SLACK_WEBHOOK_OP_REF_<NAME> for a 1Password op:// ref) and pass --to <name>. A single webhook may instead use the unsuffixed SLACK_WEBHOOK_URL. See the plugin README for how to create the Slack app and webhook."
	fi

	# Refuse anything that isn't a Slack webhook endpoint: this URL is a secret
	# in a query-less path, and a typo'd host would hand it to a stranger.
	[[ "$WEBHOOK_URL" == https://hooks.slack.com/* ]] \
		|| die "$WEBHOOK_SOURCE does not look like a Slack incoming webhook (expected https://hooks.slack.com/…)."
}

# ---- argument parsing -------------------------------------------------------

while [[ $# -gt 0 ]]; do
	case "$1" in
		--check)        CHECK=1; shift;;
		--dry-run)      DRY_RUN=1; shift;;
		--no-session-link) SESSION_LINK=0; shift;;
		--to)           TARGET="${2:-}"; [[ -n "$TARGET" ]] || die "--to needs a name"; shift 2;;
		--text)         TEXT="${2:-}"; shift 2;;
		--text-file)    TEXT_FILE="${2:-}"; [[ -n "$TEXT_FILE" ]] || die "--text-file needs a path"; shift 2;;
		--blocks-file)  BLOCKS_FILE="${2:-}"; [[ -n "$BLOCKS_FILE" ]] || die "--blocks-file needs a path"; shift 2;;
		--thread-ts)    THREAD_TS="${2:-}"; [[ -n "$THREAD_TS" ]] || die "--thread-ts needs a timestamp"; shift 2;;
		# Print the header block verbatim rather than from a line range, so
		# editing the header can't silently truncate --help.
		-h|--help)      awk 'NR>2 && /^# =+$/{exit} NR>2{sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}"; exit 0;;
		-)              POSITIONAL="$(cat)"; shift;;
		-*)             die "Unknown option: $1";;
		*)              POSITIONAL="$1"; shift;;
	esac
done

command -v curl >/dev/null 2>&1 || die "curl is required but not installed."
command -v jq   >/dev/null 2>&1 || die "jq is required but not installed."

# ---- --check: local validation only -----------------------------------------

# There is no auth.test for incoming webhooks — the only way to prove a URL
# still works is to post with it, which would put a message in the channel.
# So --check verifies everything that can be verified offline and says plainly
# that delivery is unproven.
if [[ $CHECK -eq 1 ]]; then
	printf 'deps:     curl OK, jq OK\n'
	resolve_webhook
	printf 'webhook:  %s\n' "$WEBHOOK_SOURCE"
	# Print the service/bot path segment but never the secret tail.
	printf 'endpoint: %s/…\n' "$(printf '%s' "$WEBHOOK_URL" | cut -d/ -f1-5)"
	printf 'channel:  fixed at install time; not visible from the URL\n'
	printf '\nConfig looks valid. Incoming webhooks have no auth-check endpoint,\n'
	printf 'so this does not prove the webhook is still live — send a real\n'
	printf 'message to confirm delivery.\n'
	exit 0
fi

# ---- message text -----------------------------------------------------------

TMPDIR_SELF="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SELF"' EXIT
chmod 700 "$TMPDIR_SELF"
TEXT_SRC="$TMPDIR_SELF/text"

if [[ -n "$TEXT_FILE" ]]; then
	[[ -f "$TEXT_FILE" ]] || die "--text-file not found: $TEXT_FILE"
	cat "$TEXT_FILE" > "$TEXT_SRC"
elif [[ -n "$TEXT" ]]; then
	printf '%s' "$TEXT" > "$TEXT_SRC"
elif [[ -n "$POSITIONAL" ]]; then
	printf '%s' "$POSITIONAL" > "$TEXT_SRC"
elif [[ ! -t 0 ]]; then
	cat > "$TEXT_SRC"
else
	die "No message text. Pass it as an argument, --text, --text-file, or on stdin."
fi

# Trailing newlines from a heredoc or file render as blank lines in Slack.
# Command substitution drops them; the round-trip keeps the text off argv.
TRIMMED="$(cat "$TEXT_SRC")"
printf '%s' "$TRIMMED" > "$TEXT_SRC"
unset TRIMMED

[[ -s "$TEXT_SRC" ]] || die "Message text is empty."

# The id is spliced into mrkdwn, so anything outside the shape Claude Code
# issues (session_<alnum>) is dropped rather than escaped. Callers that already
# link the session themselves (the overseer, with its own label) are left alone.
LINK=""
BRIDGE_ID="${CLAUDE_CODE_BRIDGE_SESSION_ID:-}"
if [[ $SESSION_LINK -eq 1 && "$BRIDGE_ID" =~ ^session_[A-Za-z0-9]+$ ]]; then
	SESSION_URL="https://claude.ai/code/$BRIDGE_ID"
	if ! grep -qF "$SESSION_URL" "$TEXT_SRC" ${BLOCKS_FILE:+"$BLOCKS_FILE"}; then
		LINK="<$SESSION_URL|Open Claude session>"
		[[ -n "$BLOCKS_FILE" ]] || printf '\n%s' "$LINK" >> "$TEXT_SRC"
	fi
fi

TEXT_LEN=$(wc -c < "$TEXT_SRC" | tr -d ' ')
if [[ "$TEXT_LEN" -gt "$MAX_TEXT" ]]; then
	die "Message is $TEXT_LEN bytes; Slack's limit for a message's text is $MAX_TEXT. Post a summary plus a link, or split it deliberately."
fi

# ---- payload ----------------------------------------------------------------

PAYLOAD="$TMPDIR_SELF/payload.json"

jq_args=(-n --rawfile text "$TEXT_SRC")
jq_filter='{text: $text}'

if [[ -n "$BLOCKS_FILE" ]]; then
	[[ -f "$BLOCKS_FILE" ]] || die "--blocks-file not found: $BLOCKS_FILE"
	jq -e 'type == "array"' "$BLOCKS_FILE" >/dev/null 2>&1 \
		|| die "--blocks-file must contain a JSON array of Block Kit blocks: $BLOCKS_FILE"
	jq_args+=(--slurpfile blocks "$BLOCKS_FILE")
	if [[ -n "$LINK" ]]; then
		jq_args+=(--arg link "$LINK")
		jq_filter+=' + {blocks: ($blocks[0] + [{type: "context", elements: [{type: "mrkdwn", text: $link}]}])}'
	else
		jq_filter+=' + {blocks: $blocks[0]}'
	fi
fi

if [[ -n "$THREAD_TS" ]]; then
	[[ "$THREAD_TS" =~ ^[0-9]+\.[0-9]+$ ]] || die "--thread-ts must look like 1763502924.627409: got '$THREAD_TS'"
	jq_args+=(--arg thread_ts "$THREAD_TS")
	jq_filter+=' + {thread_ts: $thread_ts}'
fi

jq "${jq_args[@]}" "$jq_filter" > "$PAYLOAD" || die "Failed to build the JSON payload."

if [[ $DRY_RUN -eq 1 ]]; then
	resolve_webhook
	printf 'DRY RUN — nothing sent.\n'
	printf 'webhook: %s\n' "$WEBHOOK_SOURCE"
	printf 'payload:\n'
	cat "$PAYLOAD"
	printf '\n'
	exit 0
fi

# ---- send -------------------------------------------------------------------

resolve_webhook

BODY="$TMPDIR_SELF/response"
HTTP_CODE="$(
	{
		printf 'url = "%s"\n' "$WEBHOOK_URL"
		printf 'header = "Content-type: application/json"\n'
		printf 'data-binary = "@%s"\n' "$PAYLOAD"
		printf 'output = "%s"\n' "$BODY"
		printf 'write-out = "%%{http_code}"\n'
		printf 'silent\n'
		printf 'show-error\n'
	} | curl --config -
)" || die "curl failed to reach Slack (network error). Nothing was confirmed sent."

RESPONSE="$(tr -d '\n' < "$BODY" 2>/dev/null || true)"

if [[ "$HTTP_CODE" == "200" && "$RESPONSE" == "ok" ]]; then
	if [[ -n "$THREAD_TS" ]]; then
		printf 'Sent to Slack (thread reply under %s).\n' "$THREAD_TS"
	else
		printf 'Sent to Slack.\n'
	fi
	exit 0
fi

# Incoming webhooks answer with an HTTP status plus a bare error string. The
# hints below are the failures a caller can actually act on; everything else is
# reported verbatim rather than guessed at.
hint=""
case "$RESPONSE" in
	no_service|no_service_id|no_active_hooks)
		hint="The webhook is disabled, deleted, or revoked. Slack revokes URLs it finds leaked — regenerate it in the app's Incoming Webhooks settings.";;
	action_prohibited)
		hint="A workspace admin has restricted this way of posting. Do not retry; ask the admin.";;
	channel_is_archived)
		hint="The webhook's channel is archived. Unarchive it, or create a webhook for a different channel.";;
	posting_to_general_channel_denied)
		hint="Posting to #general is restricted for this workspace and the webhook's creator is not allowed to post there.";;
	invalid_payload)
		hint="Slack rejected the JSON. Re-run with --dry-run to inspect the payload.";;
	invalid_token)
		hint="The webhook URL is expired, invalid, or truncated — check $WEBHOOK_SOURCE.";;
	no_text)
		hint="The payload carried no text. Re-run with --dry-run to inspect it.";;
esac

printf 'Error: Slack rejected the message (HTTP %s): %s\n' "$HTTP_CODE" "${RESPONSE:-<empty response>}" >&2
[[ -n "$hint" ]] && printf '%s\n' "$hint" >&2
exit 1
