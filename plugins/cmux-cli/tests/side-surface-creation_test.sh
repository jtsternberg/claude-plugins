#!/usr/bin/env bash
# Exercise creation identity and readiness against a stale tree and a fake clock.
set -u
OPENER="$(cd "$(dirname "$0")/.." && pwd)/skills/using-cmux-cli/scripts/open-side-surface.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/cmux" <<'SHIM'
#!/usr/bin/env bash
json=0
case "$1" in --json) json=1; shift; [[ "$1 $2" == '--id-format both' ]] || exit 9; shift 2;; esac
case "$1" in
 identify) echo '{"caller":{"pane_ref":"pane:1","workspace_ref":"workspace:1","window_ref":"window:1"}}';;
 tree) if [[ -n "${ONE_PANE:-}" ]]; then echo '{"windows":[{"ref":"window:1","id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","workspaces":[{"ref":"workspace:1","id":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","title":"workspace","panes":[{"ref":"pane:1","id":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","index":0,"surfaces":[{"ref":"surface:3","id":"FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"}]}]}]}]}'; else echo '{"windows":[{"ref":"window:1","id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","workspaces":[{"ref":"workspace:1","id":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","title":"workspace","panes":[{"ref":"pane:1","id":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","index":0,"surfaces":[]},{"ref":"pane:2","id":"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD","index":1,"surfaces":[]}]}]}]}'; fi;;
 new-pane|new-surface) [[ -z "${CREATE_NOT_FOUND:-}" ]] || { echo "not_found" >&2; exit 1; }; [[ "$json" == 1 ]] || exit 9; [[ -z "${CREATE_WARNING:-}" ]] || echo "cmux warning" >&2; printf '%s\n' "$*" > "$STATE/create"; if [[ -n "${CREATE_RESPONSE:-}" ]]; then printf '%s\n' "$CREATE_RESPONSE"; else echo '{"surface_id":"EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE","surface_ref":"surface:3","pane_id":"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD","pane_ref":"pane:2","workspace_id":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","workspace_ref":"workspace:1"}'; fi;;
 rename-tab) :;;
 send) [[ "$3" == 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB' && "$5" == 'EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE' ]] || exit 9; printf '%s' "$6" | grep -oE '__CMUX_PTYREADY_[0-9]+__' > "$STATE/marker" || :;;
 read-screen) [[ -z "${READ_LATE:-}" ]] || echo 99 > "$STATE/time"; [[ "$3" == 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB' && "$5" == 'EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE' ]] || exit 9; if (( $(cat "$STATE/time") >= ${READY_AT:-999} )); then cat "$STATE/marker" "$STATE/marker"; fi;;
 close-surface) if [[ -z "${CLOSE_FAIL:-}" ]]; then
   case "$*" in *EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE*) rm -f "$STATE/owned";; *FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF*) rm -f "$STATE/bystander";; esac
 fi; printf '%s\n' "$*" >> "$STATE/closed"; [[ -z "${CLOSE_FAIL:-}" ]];;
 *) exit 9;;
esac
SHIM
cat > "$tmp/bin/date" <<'SHIM'
#!/usr/bin/env bash
cat "$STATE/time"
SHIM
cat > "$tmp/bin/sleep" <<'SHIM'
#!/usr/bin/env bash
n=$(cat "$STATE/time"); echo $((n+1)) > "$STATE/time"
SHIM
REAL_PYTHON=$(command -v python3)
export REAL_PYTHON
cat > "$tmp/bin/python3" <<'SHIM'
#!/usr/bin/env bash
if [[ "$1" == */bounded-command.py && "${4:-}" == "${STUCK_VERB:-__none__}" ]]; then
  echo "$4" >> "$STATE/stuck"
  [[ "$4" == close-surface ]] || echo 99 > "$STATE/time"
  exit 124
fi
exec "$REAL_PYTHON" "$@"
SHIM
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" STATE="$tmp" CMUX_READY_CLOCK_FILE="$tmp/time"
pass=0; fail=0
check() { if "$@"; then pass=$((pass+1)); echo "  PASS $name"; else fail=$((fail+1)); echo "  FAIL $name (rc=$rc, err=$(cat "$tmp/err"))"; fi; }
run() { touch "$tmp/owned" "$tmp/bystander"; echo 0 > "$tmp/time"; rm -f "$tmp/closed" "$tmp/marker"; rc=0; bash "$OPENER" --title test --json "$@" > "$tmp/out" 2> "$tmp/err" || rc=$?; }
name='missing refs still succeeds with UUIDs'; CREATE_RESPONSE='{"surface_id":"EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE","pane_id":"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD","workspace_id":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"}' run; check test "$rc" -eq 0
name='stderr warning does not corrupt JSON'; CREATE_WARNING=1 run; check test "$rc" -eq 0
name='creation UUID succeeds despite stale tree'; run; check test "$rc" -eq 0
name='returns the created UUID'; check jq -e '.surface_id == "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"' "$tmp/out"
name='late readiness within the extended default budget'; READY_AT=10 run --wait-ready; check test "$rc" -eq 0
name='late successful read is rejected'; READ_LATE=1 READY_AT=0 run --wait-ready --wait-ready-timeout 3; check test "$rc" -eq 3
name='stuck send exhausts readiness budget'; STUCK_VERB=send run --wait-ready --wait-ready-timeout 3; check test "$rc" -eq 3
name='stuck read exhausts readiness budget'; STUCK_VERB=read-screen run --wait-ready --wait-ready-timeout 3; check test "$rc" -eq 3
name='stuck cleanup emits owned failure signal'; STUCK_VERB=close-surface READY_AT=999 run --wait-ready --wait-ready-timeout 3; check grep -q 'owned_cleanup_failed surface_id=EEEEEEEE' "$tmp/err"
name='permanent failure returns timeout'; READY_AT=999 run --wait-ready --wait-ready-timeout 3; check test "$rc" -eq 3
name='timeout closes only its own UUID in its workspace'; check grep -Fx 'close-surface --workspace BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB --surface EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE --force' "$tmp/closed"
name='cleanup makes exactly one close and preserves unrelated surfaces'; check test "$(wc -l < "$tmp/closed" | tr -d ' ')" -eq 1
name='failed cleanup preserves UUID for recovery'; CLOSE_FAIL=1 READY_AT=999 run --wait-ready --wait-ready-timeout 3; check grep -q 'surface_id=EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE workspace_id=BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB' "$tmp/err"
name='malformed response refuses without closing by a guessed handle'; CREATE_RESPONSE='not json' run; check test "$rc" -ne 0
name='malformed response preserves unrelated surfaces'; check test ! -s "$tmp/closed"
name='missing UUID refuses without closing by a guessed handle'; CREATE_RESPONSE='{"surface_ref":"surface:3"}' run; check test "$rc" -ne 0
name='missing UUID preserves unrelated surfaces'; check test ! -s "$tmp/closed"
name='new-pane creation UUID survives stale renumbered tree'; ONE_PANE=1 run; check test "$rc" -eq 0
name='new-pane not_found retains diagnostic under nounset'; ONE_PANE=1 CREATE_NOT_FOUND=1 run; check grep -q 'target was pinned explicitly' "$tmp/err"
name='new-pane not_found exits 1'; check test "$rc" -eq 1
ONE_PANE=1 run
name='new-pane targets workspace UUID'; check grep -q 'new-pane .*--workspace BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB' "$tmp/create"
name='new-pane returns creation identity not bystander'; check jq -e '.surface_id == "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"' "$tmp/out"
name='new-pane timeout cleans only owned surface'; ONE_PANE=1 READY_AT=999 run --wait-ready --wait-ready-timeout 3; check test "$rc" -eq 3
name='owned removed while bystander remains'; check test ! -e "$tmp/owned"
name='bystander remains independently'; check test -e "$tmp/bystander"
name='failed cleanup leaves owned and bystander'; ONE_PANE=1 CLOSE_FAIL=1 READY_AT=999 run --wait-ready --wait-ready-timeout 3; check test -e "$tmp/owned"
name='failed cleanup preserves bystander'; check test -e "$tmp/bystander"
name='mismatched workspace refuses'; CREATE_RESPONSE='{"surface_id":"EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE","pane_id":"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD","workspace_id":"FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"}' run; check test "$rc" -eq 4
name='mismatched workspace never closes'; check test ! -s "$tmp/closed"
name='mismatched pane refuses'; CREATE_RESPONSE='{"surface_id":"EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE","pane_id":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","workspace_id":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"}' run; check test "$rc" -eq 4
name='mismatched pane never closes'; check test ! -s "$tmp/closed"
# Exercise the real async caller and real opener together, with a ten-second fake clock.
CALLER="$(cd "$(dirname "$OPENER")/../../../../hotline/skills/dial/scripts" && pwd)/cmux-call-async.sh"
echo 0 > "$tmp/time"; rm -f "$tmp/marker"
late_out=$(READY_AT=10 HOTLINE_OPEN_SIDE_SURFACE="$OPENER" bash "$CALLER" --cwd "$tmp" --prompt test 2>"$tmp/caller_err")
late_dir=$(printf '%s' "$late_out" | jq -r '.call_dir // empty')
name='async caller and real opener accept readiness at fake second ten'; check test -s "$late_dir/surface_ref.txt"
name='async caller targets creation UUID'; check grep -Fx 'EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE' "$late_dir/surface_ref.txt"
[[ -f "$late_dir/launch_script.txt" ]] && rm -f "$(cat "$late_dir/launch_script.txt")"
[[ -n "$late_dir" ]] && rm -rf "$late_dir"
echo "side-surface-creation: $pass passed, $fail failed"
(( fail == 0 ))
