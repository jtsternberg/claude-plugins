#!/bin/bash
# qa-cleanup.sh must delete the epic's children, including closed ones.
# bd is stubbed via PATH; the stub only answers a list that asks for the
# epic's children with closed included and no row cap.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../skills/qa-walkthrough-pr/scripts/qa-cleanup.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "  want: $3"; echo "  got:  $2"; fi; }

mkdir "$TMP/bin"
cat > "$TMP/bin/bd" <<'STUB'
#!/bin/bash
case "$1" in
  list)
    args=" $* "
    if [[ "$args" == *" --parent qt-e "* && "$args" == *" --all "* && "$args" == *" --limit 0 "* ]]; then
      echo '[{"id":"qt-e.1","status":"closed"},{"id":"qt-e.2","status":"open"}]'
    else
      echo '[]'
    fi ;;
  delete) shift; echo "$*" > "$BD_DELETE_LOG"; exit "${BD_DELETE_EXIT:-0}" ;;
esac
STUB
chmod +x "$TMP/bin/bd"
export PATH="$TMP/bin:$PATH" BD_DELETE_LOG="$TMP/deleted"

out=$(bash "$SCRIPT" qt-e --dry-run)
check "dry-run lists children and epic" "$(echo "$out" | grep -c '  - ')" "3"
check "dry-run deletes nothing" "$([[ -e $TMP/deleted ]] && echo yes || echo no)" "no"

bash "$SCRIPT" qt-e 2>/dev/null
check "deletes closed + open children and epic" "$(cat "$TMP/deleted")" "qt-e.1 qt-e.2 qt-e --force"

BD_DELETE_EXIT=1 bash "$SCRIPT" qt-e 2>/dev/null; rc=$?
check "bd delete failure propagates" "$rc" "1"

echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
