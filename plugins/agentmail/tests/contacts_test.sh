#!/usr/bin/env bash
# =============================================================================
# Behavioral tests for the contacts store.
#
# The store holds real personal addresses, so every case runs with HOME and
# XDG_CONFIG_HOME redirected into a temp dir. The script derives its path from
# the environment and takes no --store flag on purpose: a path flag is one
# hallucinated argument away from writing an address book into a git worktree.
#
# No API key, no network, no `agentmail` binary — this store is entirely local
# because AgentMail has no contacts resource (0 hits for "contact" across the 82
# paths in its OpenAPI spec).
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTACTS="$PLUGIN_ROOT/scripts/agentmail-contacts.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "      $2"; return 0; }

command -v python3 >/dev/null 2>&1 || { echo "python3 not installed — skipping"; exit 0; }

if [ ! -f "$CONTACTS" ]; then
	echo "  ✗ $CONTACTS does not exist"
	echo "1 passed, 1 failed"; exit 1
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

CASE_N=0
STORE=""

# fresh_case — new empty HOME for the next sequence of calls.
fresh_case() {
	CASE_N=$((CASE_N+1))
	CASE_HOME="$SANDBOX/home-$CASE_N"
	mkdir -p "$CASE_HOME"
	STORE="$CASE_HOME/.config/agentmail/contacts.json"
}

# c — run the contacts script in the current case sandbox.
c() {
	env -i HOME="$CASE_HOME" XDG_CONFIG_HOME="$CASE_HOME/.config" \
		PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
		bash "$CONTACTS" "$@" 2>&1
	return $?
}

perms() { python3 -c "import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))" "$1"; }
valid_json() { python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$1" 2>/dev/null; }

echo "== init =="

fresh_case
out="$(c init)"; rc=$?
[ "$rc" -eq 0 ] && ok "init → exit 0" || bad "init should exit 0, got $rc: $out"
if [ -f "$STORE" ]; then
	ok "init created the store"
	valid_json "$STORE" && ok "the new store is valid JSON" || bad "the new store is not valid JSON"
	[ "$(perms "$STORE")" = "0o600" ] && ok "store is mode 600" \
		|| bad "store is $(perms "$STORE"), expected 0o600 (it holds personal addresses)"
else
	bad "init did not create the store at $STORE"
fi
case "$STORE" in
	"$PLUGIN_ROOT"*) bad "the store was written inside the repo: $STORE" ;;
	*) ok "the store is outside the repository" ;;
esac

c add --name "Keeper" --email keeper@example.com >/dev/null
out="$(c init)"; rc=$?
[ "$rc" -eq 4 ] && ok "init on an existing store → exit 4, refuses" || bad "init should refuse with 4, got $rc"
grep -q 'keeper@example.com' "$STORE" && ok "init did not clobber the existing store" \
	|| bad "init overwrote an existing store — the one thing it must never do"

echo
echo "== add and get =="

fresh_case
out="$(c add --name "JT Sternberg" --email you@example.com --kind human \
	--role "human owner" --notes "Approves anything outward-facing." \
	--alias Justin --alias owner --verified-from "received mail 2026-08-11")"; rc=$?
[ "$rc" -eq 0 ] && ok "add → exit 0" || bad "add should exit 0, got $rc: $out"
valid_json "$STORE" && ok "store is still valid JSON after add" || bad "add produced invalid JSON"

out="$(c get "JT Sternberg" --format json)"; rc=$?
[ "$rc" -eq 0 ] && ok "get by exact name → exit 0" || bad "get by name should exit 0, got $rc"
printf '%s' "$out" | grep -q 'you@example.com' && ok "get returns the email" || bad "get did not return the email"
printf '%s' "$out" | grep -q 'human owner' && ok "get returns the role" || bad "get dropped the role"
printf '%s' "$out" | grep -q 'received mail 2026-08-11' \
	&& ok "get returns verified_from (evidence, not recollection)" || bad "get dropped verified_from"

for q in "jt sternberg" "STERNBERG" "Justin" "owner" "you@example.com" "you@EXAMPLE.com"; do
	out="$(c get "$q")"; rc=$?
	[ "$rc" -eq 0 ] && ok "get matches '$q'" || bad "get failed on '$q' (exit $rc)"
done

out="$(c get "nobody-here")"; rc=$?
[ "$rc" -eq 3 ] && ok "no match → exit 3" || bad "no match should exit 3, got $rc"

# Exact must beat substring, or "JT" silently resolves to whichever contact the
# file happens to list first.
fresh_case
c add --name "Al" --email al@example.com >/dev/null
c add --name "Alberta" --email alberta@example.com >/dev/null
out="$(c get "Al" --format json)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'al@example.com' \
	&& ! printf '%s' "$out" | grep -q 'alberta@example.com'; then
	ok "an exact name match wins over a substring match"
else
	bad "exact match did not win over substring (exit $rc)" "$out"
fi

out="$(c get "Alb")"; rc=$?
[ "$rc" -eq 0 ] && ok "an unambiguous substring still resolves" || bad "substring lookup failed, exit $rc"

echo
echo "== conflicts change nothing =="

fresh_case
c add --name "First" --email dup@example.com >/dev/null
out="$(c add --name "Second" --email dup@example.com)"; rc=$?
[ "$rc" -eq 4 ] && ok "duplicate email → exit 4" || bad "duplicate email should exit 4, got $rc"
count="$(python3 -c "import json;print(len(json.load(open('$STORE'))['contacts']))")"
[ "$count" = "1" ] && ok "the duplicate was not added" || bad "store has $count contacts, expected 1"

fresh_case
c add --name "Ann Adams" --email ann@example.com >/dev/null
c add --name "Ann Archer" --email archer@example.com >/dev/null
out="$(c get "Ann")"; rc=$?
[ "$rc" -eq 4 ] && ok "ambiguous query → exit 4" || bad "ambiguous query should exit 4, got $rc"
printf '%s' "$out" | grep -q 'ann@example.com' && printf '%s' "$out" | grep -q 'archer@example.com' \
	&& ok "an ambiguous query lists the candidates" || bad "ambiguous query did not list candidates" "$out"

out="$(c update "Ann" --role boss)"; rc=$?
[ "$rc" -eq 4 ] && ok "ambiguous update → exit 4" || bad "ambiguous update should exit 4, got $rc"
grep -q 'boss' "$STORE" && bad "an ambiguous update still wrote to the store" \
	|| ok "an ambiguous update changed nothing"

echo
echo "== update merges =="

fresh_case
c add --name "Partner Agent" --email partner-agent@agentmail.to --kind agent \
	--role "peer agent" --notes "original note" >/dev/null
out="$(c update "Partner Agent" --notes "revised note")"; rc=$?
[ "$rc" -eq 0 ] && ok "update → exit 0" || bad "update should exit 0, got $rc: $out"
grep -q 'revised note' "$STORE" && ok "update applied the new value" || bad "update did not apply"
grep -q 'original note' "$STORE" && bad "update kept the stale value too" || ok "update replaced rather than appended"
grep -q 'peer agent' "$STORE" && ok "update preserved fields it was not given" \
	|| bad "update dropped an unset field — a merge, not a replace"
grep -q 'partner-agent@agentmail.to' "$STORE" && ok "update preserved the email" || bad "update lost the email"
valid_json "$STORE" && ok "store is valid JSON after update" || bad "update produced invalid JSON"

out="$(c update "nobody" --role x)"; rc=$?
[ "$rc" -eq 3 ] && ok "update on a missing contact → exit 3" || bad "missing update should exit 3, got $rc"

echo
echo "== remove needs --yes =="

fresh_case
c add --name "Doomed" --email doomed@example.com >/dev/null
out="$(c remove "Doomed")"; rc=$?
[ "$rc" -ne 0 ] && ok "remove without --yes is refused (exit $rc)" || bad "remove without --yes succeeded"
grep -q 'doomed@example.com' "$STORE" && ok "the refused remove changed nothing" \
	|| bad "a refused remove still deleted the contact"

out="$(c remove "Doomed" --yes)"; rc=$?
[ "$rc" -eq 0 ] && ok "remove --yes → exit 0" || bad "remove --yes should exit 0, got $rc: $out"
grep -q 'doomed@example.com' "$STORE" && bad "remove --yes did not delete" || ok "remove --yes deleted the contact"
valid_json "$STORE" && ok "store is valid JSON after remove" || bad "remove produced invalid JSON"

out="$(c remove "Doomed" --yes)"; rc=$?
[ "$rc" -eq 3 ] && ok "removing an absent contact → exit 3" || bad "absent remove should exit 3, got $rc"

echo
echo "== a missing store reads as empty, not as an error =="

fresh_case
out="$(c list --format json)"; rc=$?
[ "$rc" -eq 0 ] && ok "list with no store → exit 0" || bad "list with no store should exit 0, got $rc"
printf '%s' "$out" | python3 -c "
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if d.get('contacts')==[] else 1)" 2>/dev/null \
	&& ok "list with no store returns an empty list" || bad "list with no store is not an empty list" "$out"
[ -f "$STORE" ] && bad "a read created the store" || ok "a read did not create the store"

out="$(c get anyone)"; rc=$?
[ "$rc" -eq 3 ] && ok "get with no store → exit 3" || bad "get with no store should exit 3, got $rc"

echo
echo "== a malformed store is never silently rewritten =="

fresh_case
mkdir -p "$(dirname "$STORE")"
printf '{"version":1,"contacts":[{"name":"broken"' > "$STORE"
before="$(cat "$STORE")"

for args in "list" "get x" "add --name New --email new@example.com" "update x --role y" "remove x --yes"; do
	# shellcheck disable=SC2086
	out="$(c $args)"; rc=$?
	[ "$rc" -eq 5 ] && ok "'$args' on a malformed store → exit 5" || bad "'$args' should exit 5, got $rc"
done
[ "$(cat "$STORE")" = "$before" ] && ok "the malformed store was left byte-identical" \
	|| bad "a malformed store was rewritten — that discards data the user can still fix by hand"

echo
echo "== writes are atomic =="

fresh_case
c add --name "A" --email a@example.com >/dev/null
c add --name "B" --email b@example.com >/dev/null
leftovers="$(find "$(dirname "$STORE")" -name '*.tmp*' -o -name '.contacts*' 2>/dev/null | grep -v 'contacts.json$' || true)"
[ -z "$leftovers" ] && ok "no temp files left behind" || bad "temp files survived a write" "$leftovers"

# A write must land as one rename, so a reader never sees a half-written file.
# Accept either idiom: shell `mv` or python's os.replace.
if grep -qE 'os\.replace|mv[[:space:]]' "$CONTACTS" && grep -qE '\.tmp|mkstemp|mktemp' "$CONTACTS"; then
	ok "the script writes via a temp file and renames it into place"
else
	bad "the script does not write atomically — a crash mid-write loses the address book"
fi

echo
echo "== the store path comes from the environment, not from an argument =="

# Comment lines are excluded: the script's header explains WHY there is no
# --store flag, and banning the explanation would just delete the reasoning.
if grep -vE '^[[:space:]]*#' "$CONTACTS" | grep -qE -- '--store'; then
	bad "the script accepts a --store flag" \
		"One hallucinated path and the address book lands in a git worktree."
else
	ok "no --store flag: the path is derived from XDG_CONFIG_HOME/HOME only"
fi

fresh_case
out="$(c add --name X --email x@example.com --store /tmp/elsewhere.json)"; rc=$?
[ "$rc" -eq 64 ] && ok "an unknown flag → exit 64" || bad "unknown flag should exit 64, got $rc"

echo
echo "== usage errors =="

fresh_case
out="$(c add --name "No Email")"; rc=$?
[ "$rc" -eq 64 ] && ok "add without --email → exit 64" || bad "add without email should exit 64, got $rc"
out="$(c add --email lonely@example.com)"; rc=$?
[ "$rc" -eq 64 ] && ok "add without --name → exit 64" || bad "add without name should exit 64, got $rc"
out="$(c add --name Bad --email "not-an-email")"; rc=$?
[ "$rc" -eq 64 ] && ok "add with a malformed email → exit 64" || bad "malformed email should exit 64, got $rc"
out="$(c add --name Bad --email x@example.com --kind alien)"; rc=$?
[ "$rc" -eq 64 ] && ok "add with an unknown --kind → exit 64" || bad "bad kind should exit 64, got $rc"
out="$(c frobnicate)"; rc=$?
[ "$rc" -eq 64 ] && ok "an unknown subcommand → exit 64" || bad "unknown subcommand should exit 64, got $rc"

echo
echo "== text output is for humans, json output parses =="

fresh_case
c add --name "Reader" --email reader@example.com --kind human --role tester >/dev/null
out="$(c list --format json)"
printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null \
	&& ok "list --format json emits parseable JSON" || bad "list --format json is not parseable" "$out"
out="$(c list)"
printf '%s' "$out" | grep -q 'Reader' && printf '%s' "$out" | grep -q 'reader@example.com' \
	&& ok "the default listing names the contact and address" || bad "the default listing is unhelpful" "$out"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
