#!/usr/bin/env bash
# =============================================================================
# Doc canary: the "a trailing \n does not submit into a TUI/Ink REPL" mechanism
# must stay stated correctly in BOTH places that describe it.
#
# Why a string-match test and not a behavior test: the behavior is already
# pinned by plugins/hotline/tests/cmux-reuse-surface_test.sh, which asserts the
# script sends text and `send-key Enter` as two steps with no bundled newline.
# What drifted was the PROSE — dial/SKILL.md claimed for 13 days after the fix
# that an embedded newline "would submit early", the exact reverse of the
# verified mechanism (claude-plugins-5zhp / -zree). A caller believed the prose,
# concluded its message was correct-by-construction, and chased a
# content/escaping explanation for a transport failure.
#
# So this is deliberately a canary at string altitude: it catches the claim
# being reversed or the diagnostic being dropped. It does not simulate cmux.
# Keep it that way — the behavior test is the other file's job.
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CMUX_DOC="$ROOT/plugins/cmux-cli/skills/using-cmux-cli/SKILL.md"
DIAL_DOC="$ROOT/plugins/hotline/skills/dial/SKILL.md"
GOTCHA_ANCHOR="gotcha-a-trailing-n-does-not-submit-into-a-tuiink-repl"

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() {
  FAIL=$((FAIL + 1)); FAILED_CASES+=("$1"); echo "  ✗ $1"
  [[ -n "${2:-}" ]] && echo "    $2"
}

for f in "$CMUX_DOC" "$DIAL_DOC"; do
  [[ -f "$f" ]] || { fail "doc exists: ${f#$ROOT/}" "file not found"; }
done
[[ -f "$CMUX_DOC" && -f "$DIAL_DOC" ]] || {
  echo ""; echo "newline-submit-docs: $PASS passed, $FAIL failed"; exit 1
}

# --- 1. The reversed claim must not come back -------------------------------
# The correct prose mentions "submit early" only to negate it ("does NOT submit
# early"). A line asserting it positively is the regression. Match any line with
# the phrase that carries no negation.
BAD_SUBMIT_EARLY=$(grep -niE 'submits? early' "$CMUX_DOC" "$DIAL_DOC" \
  | grep -viE "\b(not|n't|never|isn|doesn|wouldn)\b" || true)
if [[ -z "$BAD_SUBMIT_EARLY" ]]; then
  pass "no un-negated 'submit early' claim in either doc"
else
  fail "no un-negated 'submit early' claim in either doc" \
    "the reversed-mechanism regression is back:"$'\n'"$BAD_SUBMIT_EARLY"
fi

# --- 2. Both docs state the real mechanism ----------------------------------
for f in "$CMUX_DOC" "$DIAL_DOC"; do
  rel="${f#$ROOT/}"
  grep -qiE 'literal line break' "$f" \
    && pass "$rel states the literal-line-break mechanism" \
    || fail "$rel states the literal-line-break mechanism" \
            "expected the phrase 'literal line break'"

  grep -qi 'bracketed paste' "$f" \
    && pass "$rel names bracketed paste as the cause" \
    || fail "$rel names bracketed paste as the cause"

  grep -q 'send-key' "$f" && grep -qi 'Enter' "$f" \
    && pass "$rel points at the separate send-key Enter submit" \
    || fail "$rel points at the separate send-key Enter submit"
done

# --- 3. The symptom + the diagnostic (what cost session e1df4967 time) ------
# Escaping is the wrong conclusion an outside caller reaches; both docs must say
# so, and both must name read-screen as the check.
for f in "$CMUX_DOC" "$DIAL_DOC"; do
  rel="${f#$ROOT/}"
  # Phrasing-tolerant on purpose: the two docs word this differently
  # ("Escaping is almost never…" vs "Escaping/quoting of the message body is…").
  # Assert the claim is present, not how it reads.
  grep -qiE 'escap[a-z]*.*almost never the cause' "$f" \
    && pass "$rel rules out escaping as the cause" \
    || fail "$rel rules out escaping as the cause" \
            "expected an explicit 'escaping is almost never the cause'"

  grep -q 'read-screen' "$f" \
    && pass "$rel names read-screen as the check" \
    || fail "$rel names read-screen as the check"
done

# --- 4. cmux-cli must OVERRIDE its own inlined help, not sit beside it -------
# using-cmux-cli inlines `cmux send --help` live via a ```! block, so the
# reader sees cmux's unconditional "\n and \r send Enter" and our caveat in the
# same page. Ours has to name the conflict (claude-plugins-3naq).
grep -qiE 'unconditional' "$CMUX_DOC" \
  && pass "cmux-cli doc names the inlined help's unconditional claim" \
  || fail "cmux-cli doc names the inlined help's unconditional claim" \
          "the override must contradict the inlined --help, not merely sit next to it"

grep -qE '^#### Gotcha: a trailing' "$CMUX_DOC" \
  && pass "cmux-cli doc has the canonical gotcha heading" \
  || fail "cmux-cli doc has the canonical gotcha heading"

# --- 5. The pointers into that canonical block still resolve ----------------
# Three sites link to it (the rule under --help, the shell-startup sibling, and
# the natural-language table). A renamed heading silently breaks all three.
LINK_COUNT=$(grep -c "#$GOTCHA_ANCHOR" "$CMUX_DOC" || true)
if [[ "$LINK_COUNT" -ge 3 ]]; then
  pass "cmux-cli doc cross-references the gotcha from every generic-rule site ($LINK_COUNT)"
else
  fail "cmux-cli doc cross-references the gotcha from every generic-rule site" \
    "found $LINK_COUNT links to #$GOTCHA_ANCHOR, expected >= 3"
fi

# Derive the GitHub anchor slug from the actual heading and confirm it matches
# what those links point at.
DERIVED=$(grep -E '^#### Gotcha: a trailing' "$CMUX_DOC" \
  | head -1 \
  | sed -e 's/^#*[[:space:]]*//' \
        -e 's/[`\\]//g' \
        -e 's/[^[:alnum:][:space:]-]//g' \
        -e 's/[[:space:]]\{1,\}/-/g' \
  | tr '[:upper:]' '[:lower:]')
if [[ "$DERIVED" == "$GOTCHA_ANCHOR" ]]; then
  pass "gotcha heading slug matches the anchor the links use"
else
  fail "gotcha heading slug matches the anchor the links use" \
    "heading slugifies to '$DERIVED' but links point at '$GOTCHA_ANCHOR'"
fi

echo ""
echo "newline-submit-docs: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
