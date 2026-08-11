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
#
# It has since grown to pin the three corrections that followed, because each
# one replaced a WRONG-but-plausible sentence and could plausibly come back:
#   - no ~269-byte fragmentation threshold: fragmentation and silent byte loss
#     are sporadic and not size-gated, so delivery must be verified (-8bfd)
#   - `cmux send` rewrites a literal \n/\r/\t in the payload and has no
#     backslash escape, so "escaping is never the cause" must be scoped to
#     plain text (-nofy)
#   - a busy REPL enqueues the message, so neither a missing user record nor
#     text sitting in the input box proves a failed send (-1jpz)
# =============================================================================
set -u

PASS=0
FAIL=0
FAILED_CASES=()
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CMUX_DOC="$ROOT/plugins/cmux-cli/skills/using-cmux-cli/SKILL.md"
# The hotline-side home of this prose is the dial skill's error-recovery
# reference, not its SKILL.md. SKILL.md used to carry the whole flow inline; once
# dial.sh took over the mechanics, the transport forensics moved to the file the
# caller is sent to when a call misbehaves. The canary follows the prose — what
# it guards is that the facts stay stated somewhere a caller will actually read,
# not that they live at one particular path.
DIAL_DOC="$ROOT/plugins/hotline/skills/dial/references/error-recovery.md"
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
# so, and both must name read-screen as the check. But the claim has to be
# SCOPED: `cmux send` really does rewrite a literal \n/\r/\t in the payload
# (claude-plugins-nofy, commit 896e860), so a blanket "escaping is almost never
# the cause" is now false. Require every such sentence to say "plain text".
for f in "$CMUX_DOC" "$DIAL_DOC"; do
  rel="${f#$ROOT/}"
  # Phrasing-tolerant on purpose: the two docs word this differently.
  # Assert the claim is present, not how it reads.
  CAUSE_LINES=$(grep -niE 'never the cause' "$f" || true)
  if printf '%s' "$CAUSE_LINES" | grep -qiE 'escap'; then
    pass "$rel rules out escaping as the cause"
  else
    fail "$rel rules out escaping as the cause" \
      "expected an explicit 'escaping … never the cause'"
  fi

  UNSCOPED=$(printf '%s' "$CAUSE_LINES" | grep -iE 'escap' | grep -viE 'plain text' || true)
  if [[ -z "$UNSCOPED" ]]; then
    pass "$rel scopes that claim to plain text"
  else
    fail "$rel scopes that claim to plain text" \
      "cmux DOES rewrite a literal \\n/\\r/\\t in the payload:"$'\n'"$UNSCOPED"
  fi

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

# Naming it is not enough — the prose has to say cmux's sentence is WRONG for a
# REPL, so a reader who sees both in one page knows which one loses.
grep -qiE '(is|are) (wrong|false|incorrect|not true) for a' "$CMUX_DOC" \
  && pass "cmux-cli doc declares the inlined help wrong for a TUI/Ink REPL" \
  || fail "cmux-cli doc declares the inlined help wrong for a TUI/Ink REPL" \
          "expected prose stating cmux's own sentence is wrong/false for a REPL target"

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

# --- 6. No size threshold may come back (claude-plugins-8bfd) ---------------
# An intermediate reading of the forensics claimed multi-line payloads over
# ~269 bytes FRAGMENT into many submitted turns. A controlled run refuted it: 0
# fragmentation in 12 sends, 507B-16KB. ~269 was just the label of the smallest
# failing rung, with size and line count confounded. The docs must frame both
# fragmentation and byte loss as SPORADIC and not size-gated, and must tell the
# reader to verify delivery rather than trust exit 0.
for f in "$CMUX_DOC" "$DIAL_DOC"; do
  rel="${f#$ROOT/}"

  THRESHOLD=$(grep -niE '(~|over |above |than )269|269[ -]?(byte|b\b)' "$f" || true)
  if [[ -z "$THRESHOLD" ]]; then
    pass "$rel encodes no ~269-byte threshold"
  else
    fail "$rel encodes no ~269-byte threshold" \
      "refuted by 12 controlled sends (507B-16KB, 0 fragmentation):"$'\n'"$THRESHOLD"
  fi

  grep -qiE 'no size threshold|(never|not|no|neither|nor|isn.t|aren.t)[^.]*size[- ]gated' "$f" \
    && pass "$rel says the failure is not size-gated" \
    || fail "$rel says the failure is not size-gated" \
            "expected 'no size threshold' / 'not size-gated'"

  grep -qi 'sporadic' "$f" \
    && pass "$rel frames the failure as sporadic, not deterministic" \
    || fail "$rel frames the failure as sporadic, not deterministic"

  grep -qiE 'fragment' "$f" \
    && pass "$rel documents the fragmentation-into-multiple-turns mode" \
    || fail "$rel documents the fragmentation-into-multiple-turns mode"

  grep -qiE '(lost|loss of|silent[a-z]* lost) [0-9,]* ?(contiguous )?(middle )?bytes|byte loss' "$f" \
    && pass "$rel documents the silent byte-loss mode" \
    || fail "$rel documents the silent byte-loss mode"

  grep -qi 'nonce' "$f" \
    && pass "$rel tells the caller to verify delivery with a nonce" \
    || fail "$rel tells the caller to verify delivery with a nonce"
done

# --- 7. The literal \n/\r/\t payload hazard (claude-plugins-nofy) ------------
# `cmux send` interprets those two-char sequences in its argument and has NO
# backslash escape, so a payload CONTAINING one is mangled by design. Both docs
# must say so, and cmux-cli must carry the canonical block the others point at.
for f in "$CMUX_DOC" "$DIAL_DOC"; do
  rel="${f#$ROOT/}"
  grep -qE 'no backslash escape|offers NO backslash|two backslashes' "$f" \
    && pass "$rel states there is no backslash escape" \
    || fail "$rel states there is no backslash escape" \
            "expected the '\\\\ arrives as two backslashes' fact"

  grep -qiE 'split[a-z]* the payload' "$f" \
    && pass "$rel names the split-the-payload workaround" \
    || fail "$rel names the split-the-payload workaround"
done

BS_ANCHOR="gotcha-cmux-rewrites-a-literal-backslash-n-in-your-payload"
grep -qE '^#### Gotcha: cmux rewrites a literal backslash-n' "$CMUX_DOC" \
  && pass "cmux-cli doc has the canonical backslash-rewrite gotcha heading" \
  || fail "cmux-cli doc has the canonical backslash-rewrite gotcha heading"

BS_DERIVED=$(grep -E '^#### Gotcha: cmux rewrites a literal backslash-n' "$CMUX_DOC" \
  | head -1 \
  | sed -e 's/^#*[[:space:]]*//' \
        -e 's/[`\\]//g' \
        -e 's/[^[:alnum:][:space:]-]//g' \
        -e 's/[[:space:]]\{1,\}/-/g' \
  | tr '[:upper:]' '[:lower:]')
if [[ "$BS_DERIVED" == "$BS_ANCHOR" ]]; then
  pass "backslash-rewrite heading slug matches the anchor the links use"
else
  fail "backslash-rewrite heading slug matches the anchor the links use" \
    "heading slugifies to '$BS_DERIVED' but links point at '$BS_ANCHOR'"
fi

BS_LINKS=$(grep -c "#$BS_ANCHOR" "$CMUX_DOC" || true)
if [[ "$BS_LINKS" -ge 2 ]]; then
  pass "cmux-cli doc cross-references the backslash-rewrite gotcha ($BS_LINKS)"
else
  fail "cmux-cli doc cross-references the backslash-rewrite gotcha" \
    "found $BS_LINKS links to #$BS_ANCHOR, expected >= 2"
fi

# --- 8. Queued delivery: absence of a user record proves nothing -------------
# A message sent into a BUSY repl is enqueued and may be injected into the
# running turn as a queued_command attachment — no user record is ever written
# (claude-plugins-1jpz / commit 5a1e6dc). Both docs must stop treating "no user
# event" and "text in the box" as proof of a failed send.
for f in "$CMUX_DOC" "$DIAL_DOC"; do
  rel="${f#$ROOT/}"
  grep -qE 'queued_command' "$f" \
    && pass "$rel names the queued_command attachment path" \
    || fail "$rel names the queued_command attachment path"

  grep -qiE 'Press up to edit queued|queued message is (also )?drawn|drawn (there|in the box)' "$f" \
    && pass "$rel warns a queued message renders in the input box too" \
    || fail "$rel warns a queued message renders in the input box too"
done

echo ""
echo "newline-submit-docs: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILED_CASES[@]}"
  exit 1
fi
exit 0
