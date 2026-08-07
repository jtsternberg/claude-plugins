#!/usr/bin/env bash
set -eu

if [[ "${CODEX_LIVE:-0}" != "1" ]]; then
	printf 'CODEX_LIVE is not 1; live Codex plugin smoke test is opt-in\n'
	exit 77
fi

if ! command -v codex >/dev/null 2>&1; then
	printf 'codex is required when CODEX_LIVE=1\n' >&2
	exit 1
fi

if [[ -z "${OPENAI_API_KEY:-}" ]]; then
	printf 'OPENAI_API_KEY is required when CODEX_LIVE=1 so the scratch CODEX_HOME can authenticate\n' >&2
	exit 1
fi

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CODEX_HOME="$TMP/codex-home"
mkdir -p "$CODEX_HOME" "$TMP/workspace"

codex plugin marketplace add "$REPO" --json >/dev/null
codex plugin add codex@jtsternberg --json >/dev/null

codex exec \
	--ephemeral \
	--ignore-rules \
	--skip-git-repo-check \
	--sandbox read-only \
	-C "$TMP/workspace" \
	-o "$TMP/last-message.txt" \
	'$codex:sol-mode Reply with exactly CODEX_PLUGIN_LIVE_OK. Do not use tools.' \
	>/dev/null 2>&1 </dev/null

grep -Fxq 'CODEX_PLUGIN_LIVE_OK' "$TMP/last-message.txt"
printf '1 passed, 0 failed\n'
