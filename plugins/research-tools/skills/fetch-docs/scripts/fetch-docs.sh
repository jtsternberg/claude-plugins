#!/bin/bash
# Fetch a URL into a local file and print the path on stdout.
# Purpose: give Claude the raw source to Read, bypassing WebFetch's
# small-model summarization pass that routinely drops specifics.
#
# Usage: fetch-docs.sh <url> [--slug=name] [--ttl=seconds] [--md] [--render]

set -euo pipefail

print_help() {
	cat <<'EOF'
Usage: fetch-docs <url> [--slug=name] [--ttl=seconds] [--md] [--render]

Positional:
  <url>           Any http/https URL. Quote it plainly with double quotes
                  (no backslashes before ? or & in zsh).

Flags:
  --slug=NAME     Output filename slug. Defaults to a short hash of the URL.
  --ttl=SECONDS   Cache TTL. Default 86400 (24h). 0 forces a refetch.
  --md            Convert HTML to markdown via readability-cli + turndown-cli.
                  Uses PATH-installed binaries when present (fastest); falls
                  back to `npx -y` otherwise (no install needed, but adds
                  ~4s overhead per call). For speed, run:
                    npm i -g readability-cli turndown-cli
                  No-op when the source is already markdown.
  --render        Fetch via a real headless browser (agent-browser) instead of
                  curl, so client-rendered pages (React/Vue/Svelte SPAs that
                  curl returns as an empty shell) come back fully rendered.
                  Requires agent-browser on PATH — this script never installs
                  it. Combine with --md to convert the rendered HTML.
  --check         Print availability of curl / node+npx / agent-browser and
                  exit. No URL needed. Used by the skill's prerequisites check.

Outputs:
  The cached file path on stdout. Paths use /tmp/fetch-docs-<slug>.<ext>
  where <ext> is html for HTML sources and md for markdown sources or
  --md conversions.

Exit codes:
  0  Success (path printed).
  1  Runtime failure (non-200 response, converter error, missing tool).
  2  Bad usage (unknown flag, missing URL).
EOF
}

# Emit the "looks client-rendered — try --render" tip to stderr when the given
# HTML file looks like an empty SPA shell and agent-browser is on PATH to act on
# it. Conservative thresholds keep false positives low. Called on BOTH a fresh
# fetch and a cache hit, so the nudge survives the 24h cache window (a second
# plain fetch of a shell within TTL would otherwise return it silently). Always
# returns 0 so it's safe as a bare statement under `set -e`.
emit_spa_hint() {
	local f="$1"
	command -v agent-browser >/dev/null 2>&1 || return 0
	grep -qiE 'id="(root|app|__next|swagger-ui|___gatsby)"|data-reactroot|ng-app=' "$f" || return 0
	local vis_chars
	vis_chars=$(sed 's/<[^>]*>//g' "$f" | tr -s ' \t\n' ' ' | wc -c | tr -d ' ')
	[ "${vis_chars:-0}" -lt 500 ] || return 0
	echo "fetch-docs: tip — this page looks client-rendered (empty SPA shell, ~${vis_chars} chars of visible text). agent-browser is installed; re-run with --render to capture the JS-rendered DOM." >&2
	return 0
}

URL=""
SLUG=""
TTL=86400
WANT_MD=0
WANT_RENDER=0
WANT_CHECK=0

for arg in "$@"; do
	case "$arg" in
		--slug=*) SLUG="${arg#--slug=}" ;;
		--ttl=*) TTL="${arg#--ttl=}" ;;
		--md) WANT_MD=1 ;;
		--render) WANT_RENDER=1 ;;
		--check) WANT_CHECK=1 ;;
		-h|--help) print_help; exit 0 ;;
		--*)
			echo "fetch-docs: unknown flag: $arg" >&2
			exit 2
			;;
		*)
			if [ -z "$URL" ]; then
				URL="$arg"
			else
				echo "fetch-docs: unexpected positional argument: $arg" >&2
				exit 2
			fi
			;;
	esac
done

# Tool-availability report. Lives here (not in a SKILL.md ```! fence) because a
# compound `(cmd && echo) || echo` line trips Claude Code's shell-operator
# permission gate; routing through this allowlisted script avoids that entirely.
if [ "$WANT_CHECK" = 1 ]; then
	if command -v curl >/dev/null 2>&1; then
		echo "curl: OK ($(curl --version | head -1))"
	else
		echo "curl: NOT INSTALLED (required)"
	fi
	if command -v node >/dev/null 2>&1 && command -v npx >/dev/null 2>&1; then
		echo "node+npx: OK (npx $(npx --version)) — only needed for --md on HTML sources"
	else
		echo "node+npx: not installed (only needed for --md on HTML sources; markdown sources skip the pipeline)"
	fi
	if command -v agent-browser >/dev/null 2>&1; then
		echo "agent-browser: OK ($(agent-browser --version 2>/dev/null | head -1)) — enables --render for JS pages"
	else
		echo "agent-browser: not installed (optional; only needed for --render on client-rendered SPAs)"
	fi
	exit 0
fi

if [ -z "$URL" ]; then
	echo "fetch-docs: URL is required. See --help." >&2
	exit 2
fi

if ! [[ "$TTL" =~ ^[0-9]+$ ]]; then
	echo "fetch-docs: --ttl must be a non-negative integer" >&2
	exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
	echo "fetch-docs: curl is required but not on PATH" >&2
	exit 1
fi

if [ "$WANT_RENDER" = 1 ] && ! command -v agent-browser >/dev/null 2>&1; then
	echo "fetch-docs: --render requires agent-browser on PATH (not installed)." >&2
	echo "fetch-docs: install it with one of, then 'agent-browser install' once:" >&2
	echo "    npm install -g agent-browser" >&2
	echo "    brew install agent-browser" >&2
	echo "fetch-docs: then retry with --render. This script will not install it for you." >&2
	exit 1
fi

if [ "$WANT_MD" = 1 ]; then
	if ! command -v node >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
		echo "fetch-docs: --md requires node and npx on PATH" >&2
		exit 1
	fi
	# Prefer PATH-installed CLIs (global npm install) over npx. npx adds ~2s
	# overhead per call even with a warm cache; global installs run in ~0.3s.
	# readability-cli installs its binary as `readable` (not `readability-cli`),
	# so that's the PATH name to probe first.
	if command -v readable >/dev/null 2>&1; then
		READABILITY_CMD=(readable)
	elif command -v readability-cli >/dev/null 2>&1; then
		READABILITY_CMD=(readability-cli)
	else
		READABILITY_CMD=(npx -y readability-cli)
	fi
	if command -v turndown >/dev/null 2>&1; then
		TURNDOWN_CMD=(turndown)
	elif command -v turndown-cli >/dev/null 2>&1; then
		TURNDOWN_CMD=(turndown-cli)
	else
		TURNDOWN_CMD=(npx -y turndown-cli)
	fi
fi

if [ -z "$SLUG" ]; then
	if command -v md5 >/dev/null 2>&1; then
		SLUG=$(printf '%s' "$URL" | md5 -q)
	else
		SLUG=$(printf '%s' "$URL" | md5sum | awk '{print $1}')
	fi
	SLUG="${SLUG:0:12}"
fi

# URL-based markdown detection — ignore query string / fragment.
# .mdx/.mdoc are markdown supersets (Astro/Starlight, Cloudflare docs, etc.);
# treat them as markdown-native so they're saved .md, not .html.
path_only="${URL%%\?*}"
path_only="${path_only%%#*}"
IS_MD_SOURCE=0
case "$path_only" in
	*.md|*.markdown|*.mdx|*.mdoc) IS_MD_SOURCE=1 ;;
esac

# Rendered output caches under a distinct path so a prior cheap curl fetch of
# the same URL can't satisfy a later --render call (and vice versa). Mirrors the
# way raw .html and converted .md already cache independently. Without this, the
# canonical "plain fetch → see SPA tip → re-run with --render" sequence would
# return the stale empty shell from cache.
RENDER_TAG=""
[ "$WANT_RENDER" = 1 ] && RENDER_TAG=".rendered"
OUT_HTML="/tmp/fetch-docs-${SLUG}${RENDER_TAG}.html"
OUT_MD="/tmp/fetch-docs-${SLUG}${RENDER_TAG}.md"

if [ "$IS_MD_SOURCE" = 1 ] || [ "$WANT_MD" = 1 ]; then
	TARGET="$OUT_MD"
else
	TARGET="$OUT_HTML"
fi

# Cache hit short-circuit.
if [ -f "$TARGET" ] && [ "$TTL" -gt 0 ]; then
	now=$(date +%s)
	if mtime=$(stat -f %m "$TARGET" 2>/dev/null); then :
	else mtime=$(stat -c %Y "$TARGET" 2>/dev/null || echo 0)
	fi
	if [ -n "$mtime" ] && [ "$((now - mtime))" -lt "$TTL" ]; then
		# Re-emit the SPA tip on a cache hit too — only for a raw-HTML plain
		# fetch (not --render, not the .md paths, where it doesn't apply).
		if [ "$WANT_RENDER" = 0 ] && [ "$TARGET" = "$OUT_HTML" ]; then
			emit_spa_hint "$TARGET"
		fi
		echo "$TARGET"
		exit 0
	fi
fi

HDRS=$(mktemp -t fetch-docs-hdrs.XXXXXX)
BODY=$(mktemp -t fetch-docs-body.XXXXXX)
AB_ERR=$(mktemp -t fetch-docs-ab.XXXXXX)
CLEAN=""
AB_SESSION=""
cleanup() {
	rm -f "$HDRS" "$BODY" "$AB_ERR"
	[ -n "$CLEAN" ] && rm -f "$CLEAN"
	# Close the isolated render session so we don't leak browser daemons.
	[ -n "$AB_SESSION" ] && agent-browser --session "$AB_SESSION" close >/dev/null 2>&1
	return 0
}
trap cleanup EXIT

if [ "$WANT_RENDER" = 1 ]; then
	# Dedicated, isolated session so we never touch a user's other agent-browser
	# sessions. A single fixed name (not per-PID) keeps `session list` from
	# accumulating dead records — agent-browser has no non-destructive way to
	# drop one session record (`close --all` would nuke the user's too), so we
	# reuse one name. Each open() re-navigates fresh; the trap closes the
	# browser on exit. (Two truly-concurrent --render runs would share this
	# session — unlikely for an interactive docs fetch, but worth knowing.)
	AB_SESSION="fetch-docs-render"
	if ! agent-browser --session "$AB_SESSION" open "$URL" >/dev/null 2>"$AB_ERR"; then
		echo "fetch-docs: agent-browser failed to open $URL" >&2
		sed 's/^/fetch-docs: agent-browser: /' "$AB_ERR" >&2
		exit 1
	fi
	# Best-effort settle for XHR/lazy content. A networkidle timeout on pages
	# with long-lived connections (analytics, websockets) must not fail the
	# render — we still capture whatever has painted by then.
	agent-browser --session "$AB_SESSION" wait --load networkidle >/dev/null 2>&1 || true
	# `get html html` returns the innerHTML of <html> (head+body) as clean raw
	# HTML — no JSON escaping, unlike `eval`. Wrap it back into a valid document.
	if ! agent-browser --session "$AB_SESSION" get html html >"$BODY" 2>"$AB_ERR" || [ ! -s "$BODY" ]; then
		echo "fetch-docs: agent-browser could not read the rendered DOM for $URL" >&2
		sed 's/^/fetch-docs: agent-browser: /' "$AB_ERR" >&2
		exit 1
	fi
	{ printf '<!DOCTYPE html><html>\n'; cat "$BODY"; printf '\n</html>\n'; } >"${BODY}.w" \
		&& mv "${BODY}.w" "$BODY"
	# Rendered output is always HTML; skip curl's content-type sniffing below.
	http_code=200
else
	if ! http_code=$(curl -sLD "$HDRS" -o "$BODY" -w '%{http_code}' "$URL"); then
		echo "fetch-docs: curl failed for $URL" >&2
		exit 1
	fi

	if [ "$http_code" != "200" ]; then
		echo "fetch-docs: HTTP $http_code for $URL" >&2
		exit 1
	fi

	if [ ! -s "$BODY" ]; then
		echo "fetch-docs: empty response body from $URL" >&2
		exit 1
	fi
fi

if [ "$IS_MD_SOURCE" = 0 ]; then
	# Multiple redirects → multiple Content-Type headers; use the last.
	# Tolerate responses that have no Content-Type at all (grep returns empty).
	content_type=$( { grep -i '^content-type:' "$HDRS" || true; } \
		| tail -1 \
		| awk -F': ' '{print tolower($2)}' \
		| tr -d '\r' \
		| awk -F';' '{print $1}' \
		| tr -d ' ')
	case "$content_type" in
		text/markdown|text/x-markdown) IS_MD_SOURCE=1 ;;
	esac
fi

if [ "$IS_MD_SOURCE" = 1 ]; then
	mv "$BODY" "$OUT_MD"
	echo "$OUT_MD"
	exit 0
fi

mv "$BODY" "$OUT_HTML"

# Discoverability: if curl returned what looks like an empty client-rendered
# shell, nudge toward --render. (Same check runs on cache hits above.)
if [ "$WANT_RENDER" = 0 ]; then
	emit_spa_hint "$OUT_HTML"
fi

if [ "$WANT_MD" = 1 ]; then
	CLEAN=$(mktemp -t fetch-docs-clean.XXXXXX).html
	# -l exit → fail fast on non-article pages instead of emitting CSS-leaked garbage.
	if ! "${READABILITY_CMD[@]}" -l exit -q "$OUT_HTML" -o "$CLEAN" >/dev/null 2>&1 || [ ! -s "$CLEAN" ]; then
		echo "fetch-docs: readability-cli could not extract an article from $OUT_HTML (page is likely not article-shaped — drop --md and read the raw HTML)" >&2
		exit 1
	fi
	# --head=atx + --code=fenced: nicer for agents than setext underlines + indented code.
	if ! "${TURNDOWN_CMD[@]}" --head=2 --code=2 "$CLEAN" "$OUT_MD" >/dev/null 2>&1; then
		echo "fetch-docs: turndown-cli failed converting $CLEAN" >&2
		exit 1
	fi
	if [ ! -s "$OUT_MD" ]; then
		echo "fetch-docs: turndown-cli produced empty markdown" >&2
		exit 1
	fi
	# If we went through npx for either tool, emit a speed-up tip to stderr.
	# The skill's SKILL.md tells Claude to surface this to the user once per
	# session and offer to run the install — don't repeat the offer.
	if [ "${READABILITY_CMD[0]}" = "npx" ] || [ "${TURNDOWN_CMD[0]}" = "npx" ]; then
		echo "fetch-docs: tip — npx fallback in use; 'npm i -g readability-cli turndown-cli' makes --md ~6× faster" >&2
	fi
	echo "$OUT_MD"
	exit 0
fi

echo "$OUT_HTML"
