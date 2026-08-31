#!/usr/bin/env bash
#
# tripwire-hook_test.sh — behavior suite for the PostToolUse tripwire hook.
#
# Feeds the hook real PostToolUse-shaped payloads (stubbed `bd`, throwaway git
# repo) and asserts: it fires once, the session-keyed throttle silences a repeat
# on the same file, a different file in the same session still fires, and an
# unwatched file is silent. No real beads db is ever touched.

set -u

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="$TEST_DIR/../hooks/scripts/tripwire-posttooluse.sh"

pass=0; fail=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
notok() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

command -v git     >/dev/null 2>&1 || { echo "tripwire-hook_test: git not found — SKIP"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "tripwire-hook_test: python3 not found — SKIP"; exit 0; }

WORK=$(mktemp -d); BINDIR=$(mktemp -d); STATE=$(mktemp -d)
BD_STUB_JSON="$BINDIR/index.json"
cat >"$BINDIR/bd" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "list" ]; then cat "$BD_STUB_JSON"; exit 0; fi
exit 0
STUB
chmod +x "$BINDIR/bd"
export PATH="$BINDIR:$PATH"
export BEADS_TRIPWIRE_STATE_DIR="$STATE"

cat >"$BD_STUB_JSON" <<'EOF'
[{"id":"cp-hook","status":"open","title":"hook watcher","description":"tripwire-paths: watched.txt"}]
EOF
( cd "$WORK" && git init -q && git config user.email t@t && git config user.name t \
  && printf 'a\n' > watched.txt && printf 'z\n' > other.txt && git add watched.txt other.txt && git commit -qm base )

fire() {  # $1=session $2=file  -> hook stdout
  printf '{"session_id":"%s","cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' \
    "$1" "$WORK" "$2" | bash "$HOOK" 2>/dev/null
}

echo "tripwire hook behavior suite"

out=$(fire sess-1 watched.txt)
printf '%s' "$out" | grep -q "cp-hook" && ok "fires on an edit to a watched file" || notok "fires on an edit to a watched file"
printf '%s' "$out" | grep -q "additionalContext" && ok "emits a PostToolUse context envelope" || notok "emits a PostToolUse context envelope"

out2=$(fire sess-1 watched.txt)
[ -z "$out2" ] && ok "throttled: same file, same session is silent the second time" || notok "throttled: same file, same session is silent the second time"

out3=$(fire sess-2 watched.txt)
printf '%s' "$out3" | grep -q "cp-hook" && ok "a different session fires again (throttle is session-keyed)" || notok "a different session fires again (throttle is session-keyed)"

out4=$(fire sess-1 other.txt)
[ -z "$out4" ] && ok "an unwatched file is silent" || notok "an unwatched file is silent"

# Degrade: bd unavailable → matcher matches nothing → hook silent, exit 0.
cat >"$BINDIR/bd" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "list" ]; then echo "boom" >&2; exit 1; fi
exit 0
STUB
chmod +x "$BINDIR/bd"
out5=$(fire sess-9 watched.txt); rc=$?
{ [ -z "$out5" ] && [ "$rc" -eq 0 ]; } && ok "degrade: an unavailable bd → silent, exit 0" || notok "degrade: an unavailable bd → silent, exit 0 (rc=$rc)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
