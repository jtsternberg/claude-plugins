#!/usr/bin/env bash
# =============================================================================
# session-start_test.sh — tests for handoff startup and compaction hooks.
#
# Focus: which bd issues get announced as pending handoffs. The marker is the
# `pending-handoff: ` title PREFIX, but `bd --title-contains` matches
# case-insensitively and anywhere in the title, so the hook re-filters on the
# prefix. Getting that wrong fails in both directions — dropping a real handoff
# (a cold start, the thing this hook exists to prevent), or announcing an ordinary
# issue as one (a notice you learn to ignore).
#
# `bd` is stubbed via PATH, so this never touches a real beads database.
#
# Usage: bash plugins/handoff/tests/session-start_test.sh
# =============================================================================
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/scripts/session-start.sh"
[ -f "$HOOK" ] || { echo "cannot find hook at $HOOK" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POST_COMPACT="$ROOT/hooks/scripts/post-compact-nudge.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Isolate the session cache. Both hooks walk their ancestry to the real
# claude/codex PID and write /tmp/claude-handoff/<pid>.json — so running them
# directly here would overwrite the LIVE session's cache with fixture values,
# which session-info.sh would then feed the next agent (claude-plugins-d4ux).
# Every hook/nudge/session-info run below inherits this scratch dir instead.
export CLAUDE_HANDOFF_CACHE_DIR="$TMP/handoff-cache"
mkdir -p "$CLAUDE_HANDOFF_CACHE_DIR"

# PostCompact is shared by both harnesses. SessionStart must not also match
# compact, or each compaction would run the nudge twice.
HOOK_CONFIG="$ROOT/hooks/hooks.json"
if node - "$HOOK_CONFIG" <<'NODE'
const fs = require('node:fs');
const hooks = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')).hooks;
const sessionStart = hooks.SessionStart || [];
const postCompact = hooks.PostCompact || [];
const hasStartupResume = sessionStart.some(({ matcher }) => matcher === 'startup|resume');
const hasSessionCompact = sessionStart.some(({ matcher = '' }) => matcher.split('|').includes('compact'));
const hasPostCompact = postCompact.some(({ matcher }) => matcher === 'manual|auto');
process.exit(hasStartupResume && !hasSessionCompact && hasPostCompact ? 0 : 1);
NODE
then
  pass "hook config uses one PostCompact nudge, not SessionStart compact"
else
  fail "hook config uses one PostCompact nudge, not SessionStart compact"
fi

SESSION_INFO="$ROOT/skills/handoff/scripts/session-info.sh"
for harness in claude codex; do
	cp "$(command -v bash)" "$TMP/$harness"
	if OUT=$("$TMP/$harness" -c '
		cache="$CLAUDE_HANDOFF_CACHE_DIR/$$.json"
		mkdir -p "$CLAUDE_HANDOFF_CACHE_DIR"
		printf "%s\\n" "{\"session_id\":\"'$harness'-session\"}" >"$cache"
		bash "$1"
		status=$?
		rm -f "$cache"
		exit "$status"
	' _ "$SESSION_INFO") && grep -Fxq "{\"session_id\":\"$harness-session\"}" <<<"$OUT"; then
		pass "session-info reads a cache below a $harness ancestor"
	else
		fail "session-info reads a cache below a $harness ancestor"
	fi
done

for shape in claude codex; do
	case "$shape" in
		claude) INPUT='{"session_id":"claude-session","transcript_path":"/tmp/claude.jsonl","cwd":"/tmp","hook_event_name":"PostCompact","trigger":"manual","compact_summary":"summary"}'; COMMAND='/handoff:handoff'; MARKER='-u CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID=claude-session' ;;
		codex) INPUT='{"session_id":"codex-session","transcript_path":"/tmp/codex.jsonl","cwd":"/tmp","hook_event_name":"PostCompact","trigger":"auto"}'; COMMAND='$handoff:handoff'; MARKER='-u CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID=codex-thread' ;;
	esac
	if OUT=$(printf '%s' "$INPUT" | env $MARKER bash "$POST_COMPACT" 2>&1) && grep -Fq "$COMMAND" <<<"$OUT"; then
		pass "PostCompact nudge uses the $shape command and input shape"
	else
		fail "PostCompact nudge uses the $shape command and input shape"
	fi
done

if OUT=$(printf '%s' '{"hook_event_name":"PostCompact","trigger":"manual"}' \
	| CLAUDE_CODE_SESSION_ID=claude-session CODEX_THREAD_ID=codex-thread bash "$POST_COMPACT" 2>&1) && \
	grep -Fq "the installed handoff skill using this client's skill syntax" <<<"$OUT"; then
	pass "PostCompact uses a neutral instruction for ambiguous markers"
else
	fail "PostCompact uses a neutral instruction for ambiguous markers"
fi

# --- fixture: a repo with .beads/ and a stubbed `bd` on PATH -----------------
REPO="$TMP/repo"
mkdir -p "$REPO/.beads"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" commit -q --allow-empty -m init 2>/dev/null

BIN="$TMP/bin"; mkdir -p "$BIN"

# Emits --flat-shaped rows covering every case that matters. A real
# `bd --title-contains "pending-handoff"` returns all of these: its match is
# case-insensitive and unanchored, so issues that merely mention the marker come
# back too.
cat > "$BIN/bd" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *list*)
    cat <<'ROWS'
○ proj-aaaa [● P2] [task] - pending-handoff: canonical
○ proj-bbbb [● P2] [task] - Pending-Handoff: odd casing but genuine
○ proj-cccc [● P2] [bug] - fix(handoff): make pending-handoff detection precise
○ proj-dddd [○ P4] [feature] - handoff-plugin: central registry across repos
○ proj-eeee [● P2] [task] - refactor the pending-handoff: prefix contract
ROWS
    ;;
esac
exit 0
STUB
chmod +x "$BIN/bd"

OUT=$(printf '{"session_id":"test-sid","transcript_path":"/tmp/t.jsonl","cwd":"%s"}' "$REPO" \
  | env -u CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID=claude-session PATH="$BIN:$PATH" bash "$HOOK" 2>&1)
CODEX_OUT=$(printf '{"session_id":"test-sid","transcript_path":"/tmp/t.jsonl","cwd":"%s"}' "$REPO" \
  | env -u CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID=codex-thread PATH="$BIN:$PATH" bash "$HOOK" 2>&1)

# --- announced as handoffs: the prefix matches, any casing ------------------
if grep -q 'proj-aaaa' <<<"$OUT"; then
  pass "canonical 'pending-handoff:' prefix is announced"
else
  fail "canonical 'pending-handoff:' prefix is announced"
fi

# The original regression: bd returns it, a case-sensitive shell glob dropped it.
if grep -q 'proj-bbbb' <<<"$OUT"; then
  pass "odd-cased prefix is announced (case-mismatch regression)"
else
  fail "odd-cased prefix is announced (case-mismatch regression)"
fi

HANDOFFS=$(grep 'Handoff issue:' <<<"$OUT")
if [ "$(grep -c . <<<"$HANDOFFS")" -eq 2 ]; then
  pass "exactly the two prefix-matched issues are labelled handoffs"
else
  fail "expected 2 labelled handoffs, got: $HANDOFFS"
fi

# --- sorted, never discarded ------------------------------------------------
# Titles that merely MENTION the marker must not be labelled as handoffs, but must
# still be visible: dropping a real handoff is the worse failure.
MENTIONS=$(grep 'Mentions a handoff' <<<"$OUT")
for id in proj-cccc proj-dddd proj-eeee; do
  if grep -q "$id" <<<"$OUT"; then
    pass "$id is still surfaced (nothing discarded)"
  else
    fail "$id was dropped entirely"
  fi
  if grep -q "$id" <<<"$MENTIONS"; then
    pass "$id is classed as a mention, not a handoff"
  else
    fail "$id was mislabelled as a pending handoff"
  fi
done

# --- the notice hands over the identifier -----------------------------------
if grep -Fq '/handoff:pickup-handoff <id-or-filename>' <<<"$OUT" && \
	grep -Fq '$handoff:pickup-handoff <id-or-filename>' <<<"$CODEX_OUT" && \
	! grep -Fq '\\<id-or-filename\\>' <<<"$OUT" && \
	! grep -Fq '\\<id-or-filename\\>' <<<"$CODEX_OUT"; then
	pass "startup notice uses the harness-specific pickup command"
else
	fail "startup notice uses the harness-specific pickup command"
fi

AMBIGUOUS_OUT=$(printf '{"session_id":"test-sid","transcript_path":"/tmp/t.jsonl","cwd":"%s"}' "$REPO" \
  | CLAUDE_CODE_SESSION_ID=claude-session CODEX_THREAD_ID=codex-thread PATH="$BIN:$PATH" bash "$HOOK" 2>&1)
if grep -Fq 'could not determine whether this is Claude Code or Codex' <<<"$AMBIGUOUS_OUT"; then
	pass "ambiguous markers produce a neutral pickup instruction"
else
	fail "ambiguous markers produce a neutral pickup instruction"
fi

# --- mentions only: don't claim a handoff, don't go silent either -----------
MB="$TMP/bin-mentions"; mkdir -p "$MB"
cat > "$MB/bd" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *list*) echo "○ proj-cccc [● P2] [bug] - fix(handoff): unrelated pending-handoff bug" ;;
esac
exit 0
STUB
chmod +x "$MB/bd"

MENTION_OUT=$(printf '{"session_id":"s","transcript_path":"/tmp/t","cwd":"%s"}' "$REPO" \
  | PATH="$MB:$PATH" bash "$HOOK" 2>&1)

if grep -q 'Pending handoff(s) found' <<<"$MENTION_OUT"; then
  fail "must not claim a pending handoff when only mentions matched"
else
  pass "does not claim a pending handoff when only mentions matched"
fi

if grep -q 'proj-cccc' <<<"$MENTION_OUT"; then
  pass "still surfaces the mention so a hand-titled handoff isn't lost"
else
  fail "mention was swallowed when it was the only match"
fi

# --- silence when there is nothing to report --------------------------------
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
EMPTY_OUT=$(printf '{"session_id":"s","transcript_path":"/tmp/t","cwd":"%s"}' "$EMPTY" \
  | PATH="$BIN:$PATH" bash "$HOOK" 2>&1)
if [ -z "$EMPTY_OUT" ]; then
  pass "prints nothing when there is no .beads/ and no HANDOFF*.md"
else
  fail "prints nothing when clean (got: $EMPTY_OUT)"
fi

# --- never fails the session ------------------------------------------------
if printf 'not json at all' | PATH="$BIN:$PATH" bash "$HOOK" >/dev/null 2>&1; then
  pass "exits 0 on malformed stdin"
else
  fail "exits 0 on malformed stdin"
fi

# --- the cache override is honored: no write escapes to the default dir -----
# Regression for claude-plugins-d4ux: with CLAUDE_HANDOFF_CACHE_DIR set, a hook
# run must write ONLY under it. If a future edit hardcodes /tmp/claude-handoff
# again, this test's own claude/codex ancestor PID lands a fixture file there
# and the snapshot diff catches it.
DEFAULT_DIR="/tmp/claude-handoff"
printf '{"session_id":"leak-probe","transcript_path":"/tmp/probe.jsonl","cwd":"%s"}' "$EMPTY" \
  | PATH="$BIN:$PATH" bash "$HOOK" >/dev/null 2>&1
printf '{"session_id":"leak-probe","transcript_path":"/tmp/probe.jsonl","cwd":"/tmp","hook_event_name":"PostCompact","trigger":"manual"}' \
  | CLAUDE_CODE_SESSION_ID=leak-probe bash "$POST_COMPACT" >/dev/null 2>&1
if grep -rlq 'leak-probe' "$DEFAULT_DIR" 2>/dev/null; then
  fail "a hook wrote to $DEFAULT_DIR despite CLAUDE_HANDOFF_CACHE_DIR being set"
else
  pass "hooks write only to CLAUDE_HANDOFF_CACHE_DIR, never the default dir"
fi
grep -rlq 'leak-probe' "$CLAUDE_HANDOFF_CACHE_DIR" 2>/dev/null \
  && pass "the override dir received the write" \
  || fail "the override dir did not receive the hook write"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
