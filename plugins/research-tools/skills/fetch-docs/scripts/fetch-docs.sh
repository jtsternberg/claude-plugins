#!/bin/bash
# Fetch a URL into a local file and print the path on stdout.
# Purpose: give Claude the raw source to Read, bypassing WebFetch's
# small-model summarization pass that routinely drops specifics.
#
# Usage: fetch-docs.sh <url> [--slug=name] [--ttl=seconds] [--md]

set -euo pipefail

print_help() {
	cat <<'EOF'
Usage: fetch-docs <url> [--slug=name] [--ttl=seconds] [--md]

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

URL=""
SLUG=""
TTL=86400
WANT_MD=0

for arg in "$@"; do
	case "$arg" in
		--slug=*) SLUG="${arg#--slug=}" ;;
		--ttl=*) TTL="${arg#--ttl=}" ;;
		--md) WANT_MD=1 ;;
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
path_only="${URL%%\?*}"
path_only="${path_only%%#*}"
IS_MD_SOURCE=0
case "$path_only" in
	*.md|*.markdown) IS_MD_SOURCE=1 ;;
esac

OUT_HTML="/tmp/fetch-docs-${SLUG}.html"
OUT_MD="/tmp/fetch-docs-${SLUG}.md"

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
		echo "$TARGET"
		exit 0
	fi
fi

HDRS=$(mktemp -t fetch-docs-hdrs.XXXXXX)
BODY=$(mktemp -t fetch-docs-body.XXXXXX)
CLEAN=""
cleanup() {
	rm -f "$HDRS" "$BODY"
	[ -n "$CLEAN" ] && rm -f "$CLEAN"
	return 0
}
trap cleanup EXIT

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
	echo "$OUT_MD"
	exit 0
fi

echo "$OUT_HTML"
