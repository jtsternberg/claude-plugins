#!/usr/bin/env bash
# =============================================================================
# slack.sh — read-only Slack Web API helper
#
# Subcommands:
#   thread <url|channel ts>   Print a full thread/message as clean text
#   search <query> [count]    Search messages (search.messages, user-token only)
#   history <channel> [limit] Print a channel's recent messages
#   --check                   Verify deps + token + auth.test
#
# Auth: resolves a user token (xoxp-…) from $SLACK_USER_TOKEN, or from a
# 1Password ref in $SLACK_TOKEN_OP_REF via `op read`. The token is handed to
# curl on stdin (--config -) so it never appears in argv / `ps` / shell history.
#
# Deps: curl, jq. (op only if SLACK_TOKEN_OP_REF is used.)
# =============================================================================
set -euo pipefail

API="https://slack.com/api"
TOKEN=""

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

resolve_token() {
	if [[ -n "${SLACK_TOKEN_OP_REF:-}" ]]; then
		command -v op >/dev/null 2>&1 || die "SLACK_TOKEN_OP_REF is set but the 1Password CLI (op) is not installed."
		TOKEN="$(op read "$SLACK_TOKEN_OP_REF")" || die "Failed to read token from 1Password ref: $SLACK_TOKEN_OP_REF"
	elif [[ -n "${SLACK_USER_TOKEN:-}" ]]; then
		TOKEN="$SLACK_USER_TOKEN"
	else
		die "No token. Set SLACK_USER_TOKEN=xoxp-… (or SLACK_TOKEN_OP_REF to a 1Password op:// ref). See the plugin README for how to create the Slack app and mint a token."
	fi
	[[ "$TOKEN" == xox* ]] || printf 'Warning: token does not look like a Slack token (expected to start with xox…).\n' >&2
}

# slack_api <method> [key=value ...] — POST form-encoded; token via stdin config.
slack_api() {
	local method="$1"; shift
	local resp
	resp="$(
		{
			printf 'url = "%s/%s"\n' "$API" "$method"
			printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"
			local kv
			for kv in "$@"; do
				printf 'data-urlencode = "%s"\n' "$kv"
			done
		} | curl -sS --config -
	)"
	if [[ "$(jq -r '.ok' <<<"$resp")" != "true" ]]; then
		die "Slack API ($method) failed: $(jq -r '.error // "unknown_error"' <<<"$resp")"
	fi
	printf '%s' "$resp"
}

# ---- helpers ----------------------------------------------------------------

USER_CACHE=""   # "|Uxxx=Display Name|Uyyy=…|"

resolve_user() {
	local uid="$1" name rest
	case "$USER_CACHE" in
		*"|$uid="*)
			rest="${USER_CACHE##*"|$uid="}"
			printf '%s' "${rest%%"|"*}"
			return;;
	esac
	# Tolerate lookup failure (deactivated/bot/out-of-view users): slack_api dies
	# on API errors, so shield the assignment from set -e with `|| true`. Slack's
	# display_name is often "", which jq's `//` won't skip — handle it explicitly.
	name="$( { slack_api users.info "user=$uid" 2>/dev/null \
		| jq -r '(.user.profile.display_name // "") as $d | if $d != "" then $d else (.user.profile.real_name // .user.name // "") end' 2>/dev/null ; } || true )"
	[[ -z "$name" ]] && name="$uid"
	USER_CACHE="${USER_CACHE}|$uid=$name|"
	printf '%s' "$name"
}

fmt_ts() {
	local epoch="${1%%.*}"
	if date -r "$epoch" +'%Y-%m-%d %H:%M' >/dev/null 2>&1; then
		date -r "$epoch" +'%Y-%m-%d %H:%M'        # BSD/macOS
	else
		date -d "@$epoch" +'%Y-%m-%d %H:%M'        # GNU/Linux
	fi
}

# Turn Slack mrkdwn into readable plain text: resolve <@U…> mentions, unwrap
# <url|label> and <#C…|chan> refs, then unescape HTML entities.
clean_text() {
	local t="$1" uid
	# Resolve user mentions (<@U123> and <@U123|label>)
	while [[ "$t" =~ \<@([A-Z0-9]+)(\|[^>]*)?\> ]]; do
		uid="${BASH_REMATCH[1]}"
		t="${t//${BASH_REMATCH[0]}/@$(resolve_user "$uid")}"
	done
	# Channel refs <#C123|name> -> #name
	t="$(sed -E 's/<#[A-Z0-9]+\|([^>]*)>/#\1/g' <<<"$t")"
	# Links <url|label> -> label (url) ; bare <url> -> url
	t="$(sed -E 's/<(https?:[^|>]+)\|([^>]*)>/\2 (\1)/g; s/<(https?:[^>]+)>/\1/g' <<<"$t")"
	# Entities
	printf '%s' "$t" | sed -E 's/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g'
}

print_message() {
	local msg="$1" ts user author text
	ts="$(jq -r '.ts' <<<"$msg")"
	user="$(jq -r '.user // empty' <<<"$msg")"
	if [[ -n "$user" ]]; then
		author="$(resolve_user "$user")"
	else
		author="$(jq -r '.username // .bot_id // "unknown"' <<<"$msg")"
	fi
	text="$(jq -r '.text // ""' <<<"$msg")"
	printf '%s  [%s]\n' "$author" "$(fmt_ts "$ts")"
	clean_text "$text"
	printf '\n\n'
}

# ---- subcommands ------------------------------------------------------------

cmd_thread() {
	local input="${1:-}" channel="" ts="" thread_ts="" p root resp
	[[ -n "$input" ]] || die "Usage: slack.sh thread <url | channel-id> [ts]"
	if [[ "$input" == http* ]]; then
		channel="$(sed -nE 's#.*/archives/([A-Z0-9]+).*#\1#p' <<<"$input")"
		[[ -z "$channel" ]] && channel="$(sed -nE 's#.*[?&]cid=([A-Z0-9]+).*#\1#p' <<<"$input")"
		p="$(sed -nE 's#.*/p([0-9]+).*#\1#p' <<<"$input")"
		[[ -n "$p" ]] && ts="${p:0:${#p}-6}.${p: -6}"
		thread_ts="$(sed -nE 's#.*[?&]thread_ts=([0-9.]+).*#\1#p' <<<"$input")"
	else
		channel="$input"; ts="${2:-}"; thread_ts="${2:-}"
	fi
	[[ -n "$channel" ]] || die "Could not determine channel from input."
	root="${thread_ts:-$ts}"
	[[ -n "$root" ]] || die "Could not determine a message timestamp from input."
	resp="$(slack_api conversations.replies "channel=$channel" "ts=$root" "limit=200")"
	local n; n="$(jq -r '.messages | length' <<<"$resp")"
	printf '=== Thread in %s — %s message(s) ===\n\n' "$channel" "$n"
	local msg
	while IFS= read -r msg; do
		print_message "$msg"
	done < <(jq -c '.messages[]' <<<"$resp")
}

cmd_history() {
	local channel="${1:-}" limit="${2:-20}" resp
	[[ -n "$channel" ]] || die "Usage: slack.sh history <channel-id> [limit]"
	if [[ "$channel" == http* ]]; then
		channel="$(sed -nE 's#.*/archives/([A-Z0-9]+).*#\1#p' <<<"$channel")"
	fi
	resp="$(slack_api conversations.history "channel=$channel" "limit=$limit")"
	printf '=== Recent %s message(s) in %s (newest first) ===\n\n' "$limit" "$channel"
	local msg
	while IFS= read -r msg; do
		print_message "$msg"
	done < <(jq -c '.messages[]' <<<"$resp")
}

cmd_search() {
	local query="${1:-}" count="${2:-20}" resp
	[[ -n "$query" ]] || die "Usage: slack.sh search <query> [count]"
	resp="$(slack_api search.messages "query=$query" "count=$count")"
	local total; total="$(jq -r '.messages.total' <<<"$resp")"
	printf '=== %s match(es) for: %s ===\n\n' "$total" "$query"
	local m ts author text chan link
	while IFS= read -r m; do
		ts="$(jq -r '.ts' <<<"$m")"
		author="$(jq -r '.username // .user // "unknown"' <<<"$m")"
		chan="$(jq -r '.channel.name // .channel.id // "?"' <<<"$m")"
		link="$(jq -r '.permalink // empty' <<<"$m")"
		text="$(jq -r '.text // ""' <<<"$m")"
		printf '#%s — %s  [%s]\n' "$chan" "$author" "$(fmt_ts "$ts")"
		clean_text "$text"
		printf '\n'
		[[ -n "$link" ]] && printf '%s\n' "$link"
		printf '\n'
	done < <(jq -c '.messages.matches[]' <<<"$resp")
}

cmd_check() {
	local missing=""
	command -v curl >/dev/null 2>&1 || missing="$missing curl"
	command -v jq   >/dev/null 2>&1 || missing="$missing jq"
	[[ -n "$missing" ]] && die "Missing required tool(s):$missing"
	resolve_token
	local resp
	resp="$(slack_api auth.test)"
	printf 'OK — authenticated as %s in workspace %s.\n' \
		"$(jq -r '.user' <<<"$resp")" "$(jq -r '.team' <<<"$resp")"
	printf 'Token source: %s\n' "${SLACK_TOKEN_OP_REF:+1Password ($SLACK_TOKEN_OP_REF)}${SLACK_TOKEN_OP_REF:-SLACK_USER_TOKEN env}"
}

# ---- dispatch ---------------------------------------------------------------

main() {
	local cmd="${1:-}"; shift || true
	case "$cmd" in
		--check|check) cmd_check "$@" ;;
		thread)  resolve_token; cmd_thread "$@" ;;
		history) resolve_token; cmd_history "$@" ;;
		search)  resolve_token; cmd_search "$@" ;;
		""|-h|--help)
			sed -nE '/^# ={5,}/,/^# ={5,}$/p' "$0" | sed -E 's/^# ?//'
			;;
		*) die "Unknown subcommand: $cmd (try: thread | search | history | --check)" ;;
	esac
}

main "$@"
