#!/usr/bin/env bash
#
# tripwire-match_test.sh — behavior suite for the tripwire matcher.
#
# Builds throwaway git repos with a stubbed `bd` (so no real beads db is ever
# touched) and drives scan/check through the anchor ladder. One fixture per
# DIRECTION per anchor kind — hit AND miss — per docs/compounding.md "Accept/
# reject guards get one fixture per direction."

set -u

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MATCH="$TEST_DIR/../scripts/tripwire-match.sh"
ENUMERATE="$TEST_DIR/../scripts/bd-enumerate.sh"

pass=0
fail=0
ok()    { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
notok() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# Skip cleanly if the runtime can't satisfy the suite.
command -v git     >/dev/null 2>&1 || { echo "tripwire-match_test: git not found — SKIP"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "tripwire-match_test: python3 not found — SKIP"; exit 0; }

assert_hit()      { printf '%s' "$1" | grep -q "\"bead_id\": \"$2\"" && ok "$3" || notok "$3"; }
assert_nohit()    { printf '%s' "$1" | grep -q "\"bead_id\": \"$2\"" && notok "$3" || ok "$3"; }
assert_contains() { printf '%s' "$1" | grep -q "$2" && ok "$3" || notok "$3"; }
assert_rc()       { [ "$1" -eq "$2" ] && ok "$3" || notok "$3 (rc=$1, want $2)"; }

# new_repo — fresh git repo + a `bd` stub that prints $BD_STUB_JSON for `bd list`.
# Sets WORK (repo dir). Prepends the stub dir to PATH so `command -v bd` finds it.
new_repo() {
  WORK=$(mktemp -d)
  BINDIR=$(mktemp -d)
  BD_STUB_JSON="$BINDIR/index.json"
  cat >"$BINDIR/bd" <<STUB
#!/usr/bin/env bash
# Stub bd: honor --status so status filtering (self-trip suppression) is real.
if [ "\$1" = "list" ]; then
  shift; want=""
  while [ \$# -gt 0 ]; do case "\$1" in
    --status) want="\$2"; shift 2 ;;
    --status=*) want="\${1#*=}"; shift ;;
    *) shift ;;
  esac; done
  BD_STUB_JSON="$BD_STUB_JSON" WANT="\$want" python3 - <<'PY'
import json, os
beads = json.load(open(os.environ["BD_STUB_JSON"]))
want = os.environ.get("WANT", "")
if want:
    allow = set(want.split(","))
    beads = [b for b in beads if b.get("status") in allow]
print(json.dumps(beads))
PY
  exit 0
fi
exit 0
STUB
  chmod +x "$BINDIR/bd"
  PATH="$BINDIR:$PATH"
  ( cd "$WORK" && git init -q && git config user.email t@t && git config user.name t )
}

# index_json <<'EOF' ... EOF  — write the stubbed tripwire index.
index_json() { cat >"$BD_STUB_JSON"; }

# scan / check in the repo.
scan()  { ( cd "$WORK" && bash "$MATCH" scan --json "$@" 2>/dev/null ); }
scan_err() { ( cd "$WORK" && bash "$MATCH" scan --json "$@" 2>&1 1>/dev/null ); }
check() { ( cd "$WORK" && bash "$MATCH" check "$@" 2>/dev/null ); }

echo "tripwire-match behavior suite"

# --- whole-file anchor: hit + miss ------------------------------------------
new_repo
index_json <<'EOF'
[{"id":"cp-file","status":"open","title":"whole-file watcher","description":"tripwire-paths: foo.txt"}]
EOF
( cd "$WORK" && printf 'a\nb\nc\n' > foo.txt && printf 'x\n' > bar.txt && git add -A && git commit -qm base )
( cd "$WORK" && printf 'a\nB\nc\n' > foo.txt )          # edit the watched file
assert_hit  "$(scan)" cp-file "whole-file: edit to watched file trips it"
( cd "$WORK" && git checkout -q -- foo.txt && printf 'x\ny\n' > bar.txt )  # edit an unwatched file
assert_nohit "$(scan)" cp-file "whole-file: edit to an unwatched file does not"

# --- string anchor: hit + miss ----------------------------------------------
new_repo
index_json <<'EOF'
[{"id":"cp-str","status":"open","title":"string watcher","description":"tripwire-paths: app.py:\"MAGIC_FLAG\""}]
EOF
( cd "$WORK" && printf 'one\ntwo\nthree\n' > app.py && git add -A && git commit -qm base )
( cd "$WORK" && printf 'one\ntwo\nthree\nMAGIC_FLAG = 1\n' > app.py )    # changed line has the string
assert_hit  "$(scan)" cp-str "string: a changed line containing the string trips it"
( cd "$WORK" && printf 'one\nTWO\nthree\n' > app.py )                    # changed line without the string
assert_nohit "$(scan)" cp-str "string: a change elsewhere in the file does not"

# --- comment anchor after LINE DRIFT: hit + miss ----------------------------
# Baseline puts `# tripwire: cp-cmt` at line 30. Both variants insert 10 lines
# at the top so the comment drifts to line 40 — proving the matcher uses the
# comment's CURRENT grep position, never a stored number.
build_commented() {  # $1=dest  $2=comment-suffix
  : > "$1"
  for i in $(seq 1 29); do echo "line$i" >> "$1"; done
  echo "# tripwire: cp-cmt $2" >> "$1"
  for i in $(seq 31 60); do echo "line$i" >> "$1"; done
}
build_drifted() {    # $1=dest  $2=comment-suffix  (10 new lines prepended)
  : > "$1"
  for i in $(seq 1 10); do echo "newtop$i" >> "$1"; done
  for i in $(seq 1 29); do echo "line$i" >> "$1"; done
  echo "# tripwire: cp-cmt $2" >> "$1"
  for i in $(seq 31 60); do echo "line$i" >> "$1"; done
}
new_repo
index_json <<'EOF'
[{"id":"cp-cmt","status":"open","title":"comment watcher","description":"tripwire-paths: file.sh#make_cmux"}]
EOF
( cd "$WORK" && build_commented file.sh "make_cmux" && git add -A && git commit -qm base )
( cd "$WORK" && build_drifted file.sh "make_cmux EDITED" )   # drift AND touch the comment line
assert_hit  "$(scan)" cp-cmt "comment: a hunk touching the drifted comment line trips it"
( cd "$WORK" && git checkout -q -- file.sh && build_drifted file.sh "make_cmux" )  # drift only, comment untouched
assert_nohit "$(scan)" cp-cmt "comment: drift elsewhere leaving the comment untouched does not"

# --- pinned line-range: overlap + miss --------------------------------------
new_repo
( cd "$WORK" && : > data.txt && for i in $(seq 1 20); do echo "data-line-$i" >> data.txt; done && git add -A && git commit -qm base )
REF=$( cd "$WORK" && git rev-parse HEAD )
cat >"$BD_STUB_JSON" <<EOF
[{"id":"cp-pin","status":"open","title":"pinned range watcher","description":"tripwire-paths: data.txt@$REF:L5-7"}]
EOF
( cd "$WORK" && sed -i.bak 's/^data-line-6$/data-line-6-CHANGED/' data.txt && rm -f data.txt.bak )  # touch a pinned line's content
assert_hit  "$(scan)" cp-pin "pinned range: changing a line whose ref-content is in range trips it"
( cd "$WORK" && git checkout -q -- data.txt && sed -i.bak 's/^data-line-15$/data-line-15-CHANGED/' data.txt && rm -f data.txt.bak )
assert_nohit "$(scan)" cp-pin "pinned range: changing a line outside the pinned content does not"

# --- UNPINNED line-range is rejected, never matched -------------------------
new_repo
index_json <<'EOF'
[{"id":"cp-unpin","status":"open","title":"unpinned range (bug)","description":"tripwire-paths: data.txt:L5-7"}]
EOF
( cd "$WORK" && : > data.txt && for i in $(seq 1 20); do echo "data-line-$i" >> data.txt; done && git add -A && git commit -qm base )
( cd "$WORK" && sed -i.bak 's/^data-line-6$/data-line-6-CHANGED/' data.txt && rm -f data.txt.bak )
out=$(scan)
assert_nohit  "$out" cp-unpin "unpinned range: never matches"
assert_contains "$out" "unpinned" "unpinned range: warns that it was rejected"

# --- in_progress bead self-suppresses (Q5) ----------------------------------
# The matcher enumerates open,blocked only. The bead you're editing a file to
# fix is in_progress, so its own tripwire must not fire on you.
new_repo
index_json <<'EOF'
[{"id":"cp-inprog","status":"in_progress","title":"the bead you are fixing","description":"tripwire-paths: foo.txt"}]
EOF
( cd "$WORK" && printf 'a\nb\n' > foo.txt && git add -A && git commit -qm base && printf 'a\nB\n' > foo.txt )
assert_nohit "$(scan)" cp-inprog "self-suppress: an in_progress bead's tripwire does not fire"
# Sanity: the SAME watcher, left open, DOES fire — so the miss above is the
# status filter, not a broken fixture.
index_json <<'EOF'
[{"id":"cp-inprog","status":"open","title":"the same bead, still open","description":"tripwire-paths: foo.txt"}]
EOF
assert_hit "$(scan)" cp-inprog "self-suppress: the same watcher left open still fires"

# --- check mode: comment present trips; unrelated file silent ---------------
new_repo
index_json <<'EOF'
[{"id":"cp-chk","status":"open","title":"check-mode watcher","description":"tripwire-paths: mod.sh#sym"}]
EOF
( cd "$WORK" && printf 'alpha\n# tripwire: cp-chk sym\nbeta\n' > mod.sh && printf 'z\n' > other.sh && git add -A && git commit -qm base )
chk=$(check mod.sh)
printf '%s' "$chk" | grep -q "cp-chk" && ok "check: an edited file carrying the comment fires" || notok "check: an edited file carrying the comment fires"
chk2=$(check other.sh)
[ -z "$chk2" ] && ok "check: an edited file no bead watches is silent" || notok "check: an edited file no bead watches is silent"

# --- graceful degrade: bd list fails → scan exits 0, matches nothing --------
new_repo
cat >"$BINDIR/bd" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "list" ]; then echo "boom" >&2; exit 1; fi
exit 0
STUB
chmod +x "$BINDIR/bd"
( cd "$WORK" && printf 'a\n' > foo.txt && git add -A && git commit -qm base && printf 'b\n' > foo.txt )
( cd "$WORK" && bash "$MATCH" scan --json >/dev/null 2>&1 ); assert_rc $? 0 "degrade: a failing bd list exits 0 (never blocks an edit/review)"

# --- graceful degrade: bd genuinely absent → bd-enumerate exits 127 ---------
PATH= bash "$ENUMERATE" --status open >/dev/null 2>&1; assert_rc $? 127 "degrade: bd absent from PATH → bd-enumerate exits 127"

# --- not a git repo → scan exits 0 ------------------------------------------
NG=$(mktemp -d); ( cd "$NG" && bash "$MATCH" scan --json >/dev/null 2>&1 ); assert_rc $? 0 "degrade: outside a git repo, scan exits 0"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
