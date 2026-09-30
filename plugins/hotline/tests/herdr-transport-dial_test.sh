#!/usr/bin/env bash
# =============================================================================
# herdr transport regression tests: dial.sh selection and refusals, and follow-ups
# that reuse the named agent (sections 5, 6).
#
# One shard of the herdr-transport suite. What the suite pins, the stubs and
# their knobs live in lib/herdr-transport-harness.sh; the sibling
# herdr-transport-*_test.sh shards hold the other sections.
# =============================================================================
set -u
# shellcheck source=lib/herdr-transport-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/herdr-transport-harness.sh"

# ===========================================================================
echo ""
echo "5. dial.sh selection and refusals:"
# ===========================================================================

# SIDE IS ACCEPTED, because it is what herdr already does: every callee is hosted
# in a pane split off the caller's own. The word only changes what `.placement`
# reports — same launch either way (Phase 3a, T2).
t=$(new_env)
wrap_herdr_transcript "$t" unused
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" -- --target "$t/target" --mode work_order \
        --prompt "hi" --transport herdr --placement side --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "herdr" \
   && "$(jq -r '.placement' <<<"$out" 2>/dev/null)" == "side" ]]
check "--transport herdr --placement side CONNECTS, reporting placement=side" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# …and a herdr dial that names NO placement reports SIDE, exactly as the identical
# flagless dial does over cmux. `side` is dial.sh's default placement and it is the
# true one here: the callee is a pane split off the caller's own. There is no
# legacy flagless herdr dial to stay compatible with — before side was accepted, a
# flagless `--transport herdr` was REFUSED (T1).
t=$(new_env)
wrap_herdr_transcript "$t" unused
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" -- --target "$t/target" --mode work_order \
        --prompt "hi" --transport herdr --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.placement' <<<"$out" 2>/dev/null)" == "side" ]]
check "…while a herdr dial naming no placement reports side, as cmux does" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# WINDOW IS STILL REFUSED, and the refusal names the missing feature (hotline
# creates no herdr workspaces) rather than a phase — there is no phase pending.
t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" \
        --transport herdr --window lindris)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"side and detached, not window"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"--placement side"* ]]
check "--transport herdr --window is refused, naming what herdr does place instead" $? \
  "out=$out"
[[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" != *"session attach"* ]]
check "…and no longer points at \`herdr session attach\` as the answer" $? "out=$out"

# --- conference on herdr: the pane IS the deliverable -----------------------
# Split beside the caller (which is what herdr always does), deliver, then FOCUS —
# the one call in hotline that moves the user. And no response wait: a conference is
# handed to the human, so awaiting_response is false exactly as it is on cmux.
t=$(new_env)
wrap_herdr_transcript "$t" unused
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" -- --target "$t/target" --mode conference \
        --prompt "pair with me on this" --transport herdr --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.mode' <<<"$out" 2>/dev/null)" == "conference_call" \
   && "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "herdr" ]]
check "--mode conference --transport herdr CONNECTS instead of being refused" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.awaiting_response' <<<"$out" 2>/dev/null)" == "false" ]]
check "…with awaiting_response FALSE: the session is the user's now, not the caller's" $? \
  "out=$out"
CONF_AGENT=$(jq -r '.surface_ref // empty' <<<"$out" 2>/dev/null)
grep -q "agent focus $CONF_AGENT" <(tr -d '\\' < "$t/herdr.log")
check "…and the callee's pane is FOCUSED, by agent name" $? \
  "agent=$CONF_AGENT herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
# Ordering matters: focusing before the payload is confirmed would put the user in a
# pane while the delivery is still typing into it.
[[ "$(grep -n 'agent focus' <(tr -d '\\' < "$t/herdr.log") | head -1 | cut -d: -f1)" \
   -gt "$(grep -n 'agent prompt' <(tr -d '\\' < "$t/herdr.log") | head -1 | cut -d: -f1)" ]]
check "…focused AFTER the prompt was delivered, never before" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
# The cmux conference path records the surface so a follow-up finds it; the herdr
# path gets the same thing from register-call.sh, and this is what proves it.
[[ "$(jq -r --arg t "$(cd "$t/target" && pwd -P)" '.connections[$t].surface_ref // empty' \
      "$t/home/.agents-hotline/sessions/caller-dial-1.json" 2>/dev/null)" == "$CONF_AGENT" ]]
check "…and the session cache holds the agent, so a conference follow-up re-targets it" $? \
  "cache=$(cat "$t/home/.agents-hotline/sessions/caller-dial-1.json" 2>/dev/null)"

# A WORK ORDER NEVER FOCUSES. Background work that steals the user's cursor lands
# their next keystrokes in a callee's REPL, which is why the split is --no-focus.
t=$(new_env)
wrap_herdr_transcript "$t" unused
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" -- --target "$t/target" --mode work_order \
        --prompt "run the suite" --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" ]] \
  && ! grep -q 'agent focus' <(tr -d '\\' < "$t/herdr.log")
check "a herdr WORK ORDER never focuses the callee — only a conference does" $? \
  "out=$out herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ "$(jq -r '.awaiting_response' <<<"$out" 2>/dev/null)" == "true" ]]
check "…and it still awaits a response, unlike the conference" $? "out=$out"

# A focus that fails is a FALLBACK, not an error: the callee is live and holds the
# prompt, so the call succeeded — the user just has to walk to the pane.
t=$(new_env)
wrap_herdr_transcript "$t" unused
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_FOCUS_FAIL=1" \
        -- --target "$t/target" --mode conference --prompt "pair with me" \
           --transport herdr --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" ]] \
  && [[ "$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)" == *"herdr-conference-focus-failed"* ]]
check "a conference whose focus fails still CONNECTS, with the failure in .fallbacks" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# --remote is a TRANSPORT CHOICE, not an option on one: only herdr can host a callee
# anywhere but here. Naming an incompatible transport alongside it is two explicit
# asks, so it is refused rather than resolved in either flag's favour.
t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" \
        --transport cmux --remote box.local)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"cannot host one"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"herdr-only"* ]]
check "--remote with a non-herdr --transport is an args error, naming both asks" $? "out=$out"

# ssh HAS NO `--`, so a --remote value starting with a dash is parsed as an ssh
# OPTION wherever it lands — `-oProxyCommand=…` is a command of the caller's
# choosing on every hop of the dial. Quoting cannot fix it (the remote layer quotes
# for the REMOTE shell, not for the local ssh's own argv parse), so it is refused
# where a destination is the only thing the value can be.
t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" \
        --remote "-oProxyCommand=touch /tmp/hotline-pwned")
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" \
   && "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "args" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"cannot begin with '-'"* ]]
check "a --remote value starting with '-' is refused: ssh would read it as an option" $? \
  "out=$out"
[[ ! -e "$t/ssh.log" && ! -e /tmp/hotline-pwned ]]
check "…before any hop, so the option never reaches an ssh argv" $? \
  "ssh hops: $(cat "$t/ssh.log" 2>/dev/null)"

# The transport list a caller is handed has to describe the transport they get:
# herdr stopped being local-only when --remote landed, and detached-only when Phase
# 3a accepted side placement.
t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" --transport nope)
[[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"--remote"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"side or detached"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" != *"detached, local, opt-in"* ]]
check "the --transport list calls herdr neither local-only nor detached-only" $? \
  "recovery=$(jq -r '.recovery' <<<"$out" 2>/dev/null)"

# Side placement is the one refusal --remote owns. Locally, side and detached are
# the same herdr launch, so herdr accepts both; a pane on another box is beside
# nothing here, and reporting `side` for it would be a lie. Every OTHER placement
# herdr cannot host (`window`) is still refused by herdr's own validation rather
# than a second copy of it, which is why --remote resolves the transport BEFORE
# that block runs.
t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" \
        --remote box.local --placement side)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"detached only"* ]]
check "--remote with an EXPLICIT --placement side is refused, not silently overridden" $? "out=$out"
[[ ! -s "$t/ssh.log" ]] 2>/dev/null || [[ ! -e "$t/ssh.log" ]]
check "…before any ssh hop is made: an args error costs no network" $? \
  "ssh hops: $(cat "$t/ssh.log" 2>/dev/null)"

t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" \
        --transport herdr --detached --resume some-session)
[[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"--resume"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"re-dial the same target"* ]]
check "--transport herdr --resume is refused, pointing at the flagless follow-up instead" $? "out=$out"

t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" --transport nope)
[[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"Unknown --transport"* ]]
check "an unknown --transport is refused with the valid list" $? "out=$out"

# Two explicit, incompatible backends. Silently honouring either would discard a
# flag the caller typed on purpose.
t=$(new_env)
out=$(dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" \
        --transport herdr --detached --headless)
[[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"ask for different backends"* ]]
check "--headless together with --transport herdr is refused, not silently resolved" $? "out=$out"

# A failed herdr preflight is an ERROR. Not cmux (the caller wanted persistence),
# not headless (no live host to follow up into) — and the reason is preflight's own.
t=$(new_env)
out=$(dial "$t" HERDR_STUB_SESSION_RC=1 -- --target "$t/target" --mode work_order \
        --prompt "hi" --transport herdr --detached)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" \
   && "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "transport" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"no server answered"* ]]
check "a failed herdr preflight is an ERROR at stage=transport, carrying preflight's reason" $? \
  "out=$out"
[[ "$(jq -r '.fallbacks | length' <<<"$out" 2>/dev/null)" == "0" ]] \
  && ! grep -q 'new-workspace' "$t/cmux.log" 2>/dev/null
check "…and it NEVER silently degrades to cmux or headless" $? \
  "out=$out cmux calls: $(cat "$t/cmux.log" 2>/dev/null)"

# herdr is available AND the caller is sitting inside a herdr pane — and it is still
# not selected. The ambient signal only ENABLES the option; selecting takes an
# opt-in, because flipping the default on the environment alone would surprise
# every interactive local caller.
t=$(new_env)
stub_headless_claude "$t"
out=$(dial "$t" "HERDR_ENV=1" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode quick --prompt "hi")
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" != "herdr" ]]
check "HERDR_ENV=1 alone never SELECTS herdr — the default stays cmux's chain" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ ! -s "$t/herdr.log" ]]
check "…and no herdr preflight is even run without the explicit flag" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# ---------------------------------------------------------------------------
# HOTLINE_TRANSPORT_AUTO — the opt-in that lets the ambient signal decide.
#
# FOUR conditions, all required, and the tests below take one away at a time. The
# point of the guard is that neither half selects alone: the setting is deliberate
# but says nothing about where the caller is, and HERDR_ENV says where they are but
# nobody chose it.
# ---------------------------------------------------------------------------
t=$(new_env)
stub_headless_claude "$t"
out=$(dial "$t" "HOTLINE_TRANSPORT_AUTO=1" \
        -- --target "$t/target" --mode quick --prompt "hi")
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" != "herdr" ]] && [[ ! -s "$t/herdr.log" ]]
check "AUTO=1 OUTSIDE a herdr pane does not select herdr (no HERDR_ENV, no preflight)" $? \
  "out=$out herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

t=$(new_env)
wrap_herdr_transcript "$t" unused
out=$(dial "$t" "HOTLINE_TRANSPORT_AUTO=1" "HERDR_ENV=1" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode work_order --prompt "run the suite" \
           --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "herdr" ]]
check "AUTO=1 + HERDR_ENV=1 + a usable preflight SELECTS herdr with no --transport" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.placement' <<<"$out" 2>/dev/null)" == "side" ]] \
  && [[ ! -s "$t/cmux.log" ]]
check "…reporting side, the placement a flagless dial reports, and never touching cmux" $? \
  "out=$out cmux calls: $(cat "$t/cmux.log" 2>/dev/null)"

# The auto path's failure is a DEGRADE, not an error — the opposite of the explicit
# flag, because nothing was asked for. It must still be visible: a dial that quietly
# lands somewhere else is the thing .fallbacks exists for.
t=$(new_env)
stub_headless_claude "$t"
out=$(dial "$t" "HOTLINE_TRANSPORT_AUTO=1" "HERDR_ENV=1" "HERDR_STUB_NO_PANES=1" \
        -- --target "$t/target" --mode quick --prompt "hi")
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.transport' <<<"$out" 2>/dev/null)" != "herdr" ]]
check "AUTO=1 with an UNUSABLE herdr degrades to the cmux default instead of erroring" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)" == *"transport-auto→cmux("* ]] \
  && [[ "$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)" == *"no pane could be resolved"* ]]
check "…recording the degrade in .fallbacks, carrying preflight's own reason" $? "out=$out"

# An explicit --transport is the caller's answer; AUTO does not get to overrule it.
t=$(new_env)
stub_headless_claude "$t"
out=$(dial "$t" "HOTLINE_TRANSPORT_AUTO=1" "HERDR_ENV=1" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode quick --prompt "hi" --transport cmux)
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" != "herdr" ]] && [[ ! -s "$t/herdr.log" ]]
check "AUTO=1 + an explicit --transport cmux stays on cmux's chain" $? \
  "out=$out herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

t=$(new_env)
stub_headless_claude "$t"
out=$(dial "$t" "HOTLINE_TRANSPORT_AUTO=1" "HERDR_ENV=1" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode quick --prompt "hi" --headless)
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "headless" ]] && [[ ! -s "$t/herdr.log" ]]
check "AUTO=1 + --headless goes headless, and never preflights herdr" $? \
  "out=$out herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# HOTLINE_FORCE_HEADLESS is the ambient form of the same instruction. It is read by
# check-cmux.sh, so without its own clause here the auto path would have selected
# herdr before that variable was ever consulted.
t=$(new_env)
stub_headless_claude "$t"
out=$(dial "$t" "HOTLINE_TRANSPORT_AUTO=1" "HERDR_ENV=1" "HERDR_PANE_ID=w1:p1" \
        "HOTLINE_FORCE_HEADLESS=1" -- --target "$t/target" --mode quick --prompt "hi")
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "headless" ]] && [[ ! -s "$t/herdr.log" ]]
check "AUTO=1 + HOTLINE_FORCE_HEADLESS=1 goes headless too" $? \
  "out=$out herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# EXACTLY '1'. A looser test would let a `HOTLINE_TRANSPORT_AUTO=0` left in a
# profile enable the very thing it was written to turn off.
t=$(new_env)
stub_headless_claude "$t"
out=$(dial "$t" "HOTLINE_TRANSPORT_AUTO=0" "HERDR_ENV=1" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode quick --prompt "hi")
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" != "herdr" ]] && [[ ! -s "$t/herdr.log" ]]
check "HOTLINE_TRANSPORT_AUTO=0 does not enable it (the opt-in is exactly '1')" $? \
  "out=$out herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# --transport headless is just another way to say --headless.
t=$(new_env)
stub_headless_claude "$t"
out=$(dial "$t" -- --target "$t/target" --mode quick --prompt "hi" --transport headless)
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "headless" ]]
check "--transport headless routes exactly where --headless does" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ ! -s "$t/herdr.log" ]]
check "…and never touches herdr" $? "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# --- end to end through dial.sh: the callee never records the prompt ---------
# The plain stub submits without the callee writing anything, which is exactly the
# shape of a delivery that cannot be confirmed. That must be an ERROR: the agent is
# live and was told nothing we can prove, so "connected" would leave the caller
# waiting on a response to a message that may not exist.
t=$(new_env)
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_NEW_PANE=w1:p8" \
        -- --target "$t/target" --mode work_order --prompt "run the suite" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" \
   && "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "deliver" ]]
check "an unconfirmable herdr delivery errors at stage=deliver, never reports connected" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
# `sent` FORWARDED into the error, because the recovery text tells the model to read it
# — and an error that dropped it left that advice unactionable on the one failure where
# double-delivery is the risk (claude-plugins-zh7p).
[[ "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "true" ]]
check "…carrying the delivery's own \`sent\`, which decides whether re-dialing is safe" $? \
  "out=$out"
[[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"\`sent\` field is true"* ]]
check "…and a recovery that states the value rather than pointing at a result the model never sees" $? \
  "out=$out"
call_dir=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$call_dir" && "$(cat "$call_dir/transport.txt" 2>/dev/null)" == "herdr" \
   && -s "$call_dir/herdr_agent.txt" && -s "$call_dir/pending_paste.md" ]]
check "…leaving the payload in pending_paste.md for recovery, as the cmux path does" $? \
  "call_dir: $(ls "$call_dir" 2>/dev/null | tr '\n' ' ')"
grep -q 'agent start' <(tr -d '\\' < "$t/herdr.log")
check "…having really run launch → boot → deliver in order" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ ! -s "$t/cmux.log" ]]
check "…and made no cmux call: an explicit herdr dial never consults cmux" $? \
  "cmux calls: $(cat "$t/cmux.log" 2>/dev/null)"

# The same field on a PRE-SUBMIT refusal: sent:false, so the caller is free to re-dial.
# Hardcoding it either way would make it worse than absent.
t=$(new_env)
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_NEW_PANE=w1:p8" "HERDR_STUB_GET_READY=false" \
        -- --target "$t/target" --mode work_order --prompt "run the suite" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "deliver" \
   && "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" ]]
check "a pre-submit refusal reports sent:FALSE on the same error field" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# THE WHOLE REASON REACHES .detail. A refusal states the remedy and the diagnosis,
# and dial.sh used to forward both through reason_of's 300-character cut — which is
# a summary-line budget, right for a fallbacks entry and wrong for the error report
# itself. The trust-dialog refusal runs past 590 characters and lost its closing
# "trust is not a permission mode" every time (claude-plugins-e3xr).
t=$(new_env)
trust_dialog_screen "$t/screen.txt" "$(cd "$t/target" && pwd -P)"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_NEW_PANE=w1:p8" \
        "HERDR_STUB_SCREEN=$t/screen.txt" \
        -- --target "$t/target" --mode work_order --prompt "run the suite" \
           --transport herdr --detached --boot-timeout 5)
DETAIL=$(jq -r '.detail // empty' <<<"$out" 2>/dev/null)
[[ "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "deliver" && ${#DETAIL} -gt 300 ]]
check "a >300-char refusal reason reaches .detail without a cut" $? \
  "len=${#DETAIL} out=$out stderr=$(cat "$t/err.txt")"
[[ "$DETAIL" == *"trust that directory"* \
   && "$DETAIL" == *"HOTLINE_DANGEROUSLY_SKIP_PERMISSIONS does not cover this gate"* \
   && "$DETAIL" == *"directory trust is not a permission mode"* ]]
check "…including its LAST sentence, the half a cut always took" $? "detail=$DETAIL"

# --- a refused first contact leaves NO cache entry (claude-plugins-63om) -----
# register-call.sh writes the entry at boot-confirm, one step before delivery. When
# that delivery is refused the entry names a callee that never received the opening
# prompt — and a callee whose delivery failed because it died is gone by then — so
# the re-dial the error asks for used to arrive as a FOLLOW-UP into it: told "no such
# agent", falling back to a fresh callee, and reporting a lost conversation there
# never was.
t=$(new_env)
cat > "$t/bin/herdr" <<STUBW
#!/usr/bin/env bash
if [[ "\$1 \${2:-}" == "agent prompt" ]]; then
  SID=\$(cat "\$HERDR_STATE/session_id" 2>/dev/null || echo unknown)
  export HERDR_STUB_TRANSCRIPT="$t/home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/\$SID.jsonl"
fi
exec bash "$t/bin/herdr-real" "\$@"
STUBW
chmod +x "$t/bin/herdr"
mkdir -p "$t/binsrc"; make_herdr_stub "$t/binsrc"; mv "$t/binsrc/herdr" "$t/bin/herdr-real"
trust_dialog_screen "$t/screen.txt" "$(cd "$t/target" && pwd -P)"
CACHE_FILE="$t/home/.agents-hotline/sessions/caller-dial-1.json"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_NEW_PANE=w1:p8" \
        "HERDR_STUB_SCREEN=$t/screen.txt" \
        -- --target "$t/target" --mode work_order --prompt "first try" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "deliver" ]]
check "a first contact refused at delivery fails at stage=deliver" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ -z "$(jq -r --arg tp "$(cd "$t/target" && pwd -P)" '.connections[$tp] // empty' \
          "$CACHE_FILE" 2>/dev/null)" ]]
check "…and its cache entry is GONE, not left naming a callee that was never rung" $? \
  "cache: $(cat "$CACHE_FILE" 2>/dev/null)"

# THE CONSEQUENCE, which is the whole point: the re-dial is a clean first contact.
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_NEW_PANE=w1:p8" \
        -- --target "$t/target" --mode work_order --prompt "second try" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.first_contact' <<<"$out" 2>/dev/null)" == "true" ]]
check "…so the re-dial connects as a FIRST CONTACT, not a follow-up" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -c '.fallbacks' <<<"$out" 2>/dev/null)" != *"herdr-agent-reuse→fresh"* ]]
check "…with no exited-agent fallback reporting a conversation that never started" $? \
  "fallbacks=$(jq -c '.fallbacks' <<<"$out" 2>/dev/null)"

# --- end to end through dial.sh: the callee DOES record it -------------------
# The plain stub cannot precompute the transcript path (it does not know the session
# id until `agent start` hands it one), so a thin wrapper fills that in — modelling
# the callee writing the prompt it received to its own transcript, which is the tier
# a live delivery is confirmed by.
t=$(new_env)
# The REALPATH spelling of the cwd, deliberately: dial.sh resolves its target
# through resolve-workspace.sh, and a callee under /tmp on macOS actually writes to
# the /private/tmp encoding. Confirmation checks both spellings of whatever cwd it
# is given, so writing the realpath one is correct either way.
cat > "$t/bin/herdr" <<STUBW
#!/usr/bin/env bash
if [[ "\$1 \${2:-}" == "agent prompt" ]]; then
  SID=\$(cat "\$HERDR_STATE/session_id" 2>/dev/null || echo unknown)
  export HERDR_STUB_TRANSCRIPT="$t/home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/\$SID.jsonl"
fi
exec bash "$t/bin/herdr-real" "\$@"
STUBW
chmod +x "$t/bin/herdr"
mkdir -p "$t/binsrc"; make_herdr_stub "$t/binsrc"; mv "$t/binsrc/herdr" "$t/bin/herdr-real"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_NEW_PANE=w1:p8" \
        -- --target "$t/target" --mode work_order --prompt "run the suite" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" ]]
check "a confirmed herdr delivery reports status=connected" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "herdr" \
   && "$(jq -r '.placement' <<<"$out" 2>/dev/null)" == "detached" ]]
check "…with transport=herdr and placement=detached" $? "out=$out"
[[ "$(jq -r '.surface_ref' <<<"$out" 2>/dev/null)" == hotline-* ]]
check "…and the herdr AGENT NAME in the stable host-ref field (.surface_ref)" $? "out=$out"
# The name SAYS WHERE THE CALLEE IS. It is the only handle `herdr agent list` gives
# a human looking for a stuck callee, and slugging the session name instead made
# every one of them hotline-hotline-* (claude-plugins-hukk).
[[ "$(jq -r '.surface_ref' <<<"$out" 2>/dev/null)" == "hotline-$(basename "$t/target")-"* ]]
check "…slugged from the TARGET's directory, not from the session name" $? \
  "surface_ref=$(jq -r '.surface_ref' <<<"$out" 2>/dev/null) (expected hotline-$(basename "$t/target")-*)"
[[ -n "$(jq -r '.remote_session_id // empty' <<<"$out" 2>/dev/null)" \
   && -n "$(jq -r '.call_id // empty' <<<"$out" 2>/dev/null)" ]]
check "…and the contract's .remote_session_id / .call_id unchanged in shape" $? "out=$out"
call_dir=$(jq -r '.call_dir' <<<"$out" 2>/dev/null)
[[ ! -f "$call_dir/pending_paste.md" ]]
check "…and the delivered payload is removed (the transcript is the record now)" $? \
  "call_dir: $(ls "$call_dir" 2>/dev/null | tr '\n' ' ')"
[[ "$(jq -r '.fallbacks | length' <<<"$out" 2>/dev/null)" == "0" ]]
check "…with no fallbacks: the session id herdr observed matched the one we preset" $? "out=$out"

# --- a preset/observed session-id disagreement reaches the emitted JSON ------
# It is the single most diagnostic signal when a herdr dial later goes quiet, and a
# fact recorded only in a temp dir is a fact nobody reads. The call still SUCCEEDS —
# the launcher adopts herdr's observed id, which is the correct one — so this is a
# fallback note rather than an error.
t=$(new_env)
OBS_SID="eeeeeeee-2222-4222-8222-333333333333"
cat > "$t/bin/herdr" <<STUBW
#!/usr/bin/env bash
if [[ "\$1 \${2:-}" == "agent prompt" ]]; then
  export HERDR_STUB_TRANSCRIPT="$t/home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/$OBS_SID.jsonl"
fi
exec bash "$t/bin/herdr-real" "\$@"
STUBW
chmod +x "$t/bin/herdr"
mkdir -p "$t/binsrc"; make_herdr_stub "$t/binsrc"; mv "$t/binsrc/herdr" "$t/bin/herdr-real"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_OBSERVED_SID=$OBS_SID" \
        -- --target "$t/target" --mode work_order --prompt "run the suite" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.remote_session_id' <<<"$out" 2>/dev/null)" == "$OBS_SID" ]]
check "an observed session id different from the preset still connects, on the OBSERVED id" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)" == *"herdr-session-id-mismatch(preset="* ]]
check "…and the disagreement is reported in .fallbacks, not just left in the call dir" $? "out=$out"

# ===========================================================================
echo ""
echo "6. Follow-ups (reuse) — the named agent IS the session:"
# ===========================================================================
# A herdr follow-up re-targets the agent the cache already holds. It must NOT
# launch anything: a second callee would have none of the prior conversation, and
# a second host for a live session is exactly the surface-stacking the cmux reuse
# path exists to prevent.

# The caller-side cache dial.sh reads: one connection for $t/target, keyed by the
# REALPATH (which is what session-cache.sh canonicalizes to).
stage_cache() {  # stage_cache <scratch> <session-id> <host-handle|''>
  local t="$1" sid="$2" handle="$3"
  mkdir -p "$t/home/.agents-hotline/sessions"
  jq -nc --arg t "$(cd "$t/target" && pwd -P)" --arg s "$sid" --arg h "$handle" \
    '{caller_session_id:"caller-dial-1",
      connections:{($t): ({session_id:$s, mode:"work_order", started:1,
                           last_contact:1, exchange_count:1,
                           last_call_id:"prior-nonce"}
        + (if $h == "" then {} else {surface_ref:$h} end))}}' \
    > "$t/home/.agents-hotline/sessions/caller-dial-1.json"
}

CACHED_AGENT="hotline-target-a1b2c3"
CACHED_SID="prior-session-1"

# --- the happy path, end to end through dial.sh -----------------------------
t=$(new_env)
stage_cache "$t" "$CACHED_SID" "$CACHED_AGENT"
wrap_herdr_transcript "$t" "$CACHED_SID"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_AGENT_ANY=1" \
        -- --target "$t/target" --mode work_order --prompt "and now step 2" \
           --transport herdr --detached)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.first_contact' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "herdr" ]]
check "a herdr dial into an already-cached session CONNECTS as a follow-up" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

log=$(tr -d '\\' < "$t/herdr.log")
[[ "$log" == *"agent prompt $CACHED_AGENT"* ]]
check "…delivered by \`agent prompt <cached-name>\`, re-targeting the live agent" $? \
  "herdr calls: $log"
! grep -qE 'agent start|pane split' <(printf '%s' "$log")
check "…and NOT by a fresh \`agent start\` / \`pane split\` (no second callee, no lost context)" $? \
  "herdr calls: $log"
! grep -q 'pane close' <(printf '%s' "$log")
check "…with no superseded-host cleanup: the same agent is reused, so nothing is orphaned" $? \
  "herdr calls: $log"

[[ "$(jq -r '.surface_ref' <<<"$out" 2>/dev/null)" == "$CACHED_AGENT" \
   && "$(jq -r '.remote_session_id' <<<"$out" 2>/dev/null)" == "$CACHED_SID" \
   && -n "$(jq -r '.call_id // empty' <<<"$out" 2>/dev/null)" ]]
check "…keeping .surface_ref / .remote_session_id / .call_id stable in shape" $? "out=$out"
[[ "$(jq -r '.fallbacks | length' <<<"$out" 2>/dev/null)" == "0" ]]
check "…and working nothing around: no fallbacks at all" $? "out=$out"
# The proof tier herdr-reuse-agent.sh reported, forwarded like the cmux twin's. A
# reader comparing the two transports cannot tell a dropped field from a delivery
# nothing could prove.
[[ "$(jq -r '.confirmed // "<absent>"' <<<"$out" 2>/dev/null)" == "transcript" ]]
check "…and forwarding the delivery's proof tier (.confirmed), as the cmux path does" $? "out=$out"

# The [FOLLOW_UP] ringing invocation, split like first contact: the invocation line
# alone via `pane send-text`, the message via `agent prompt`. Submitted as one
# atomic `agent prompt`, a multi-line follow-up reaches the callee as a
# <pasted_content> block the harness tells it not to take instructions from
# (claude-plugins-2i6g); through the command, the message lands in command-args.
DELIVERED="$t/home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/$CACHED_SID.jsonl"
DELIVERED_TEXT=$(jq -r 'select(.type=="user") | .message.content' "$DELIVERED" 2>/dev/null | tail -c 2000)
[[ "$DELIVERED_TEXT" == '/hotline:hotline-ringing [CALL_ID: '*'] [FOLLOW_UP] [MODE: work_order] [CALLER: '*'] [SESSION: caller-dial-1]'$'\n''and now step 2' ]]
check "…delivering the follow-up as a [FOLLOW_UP] ringing invocation with the message beneath" $? \
  "delivered: $(printf '%q' "$DELIVERED_TEXT")"
grep -q 'pane send-text [^ ]* /hotline:hotline-ringing \[CALL_ID: [0-9a-z-]*\] \[FOLLOW_UP\]' <<<"$log"
check "…with the invocation line placed alone by \`pane send-text\` (the split delivery)" $? \
  "herdr calls: $log"

NEW_NONCE=$(jq -r '.call_id' <<<"$out" 2>/dev/null)
[[ -n "$NEW_NONCE" && "$NEW_NONCE" != "prior-nonce" ]] \
  && grep -qF "[CALL_ID: $NEW_NONCE]" "$DELIVERED" 2>/dev/null
check "…led by a FRESH nonce, so the prior exchange's STATUS lines cannot be read as this turn's" $? \
  "call_id=$NEW_NONCE prior=prior-nonce delivered=$(head -c 200 "$DELIVERED" 2>/dev/null)"

REG="$t/home/.agents-hotline/sessions/caller-dial-1.json"
conn() { jq -r --arg t "$(cd "$t/target" && pwd -P)" ".connections[\$t].$1 // \"<absent>\"" "$REG" 2>/dev/null; }
[[ "$(conn exchange_count)" == "2" && "$(conn session_id)" == "$CACHED_SID" \
   && "$(conn surface_ref)" == "$CACHED_AGENT" && "$(conn last_call_id)" == "$NEW_NONCE" ]]
check "…and the cache bumps the exchange while keeping the same session and agent" $? \
  "registry: $(cat "$REG" 2>/dev/null)"

# --- a follow-up's --label is IGNORED, and nothing is renamed -----------------
# The callee keeps the name first contact gave it: a label typed against "and now
# step 2" is worse than the one chosen when the job was described in full. And the
# tab could not be renamed safely in any case — herdr's default placement is a
# SPLIT, whose pane sits in the CALLER's tab, so a rename off the live agent would
# retitle the caller's own work.
t=$(new_env)
stage_cache "$t" "$CACHED_SID" "$CACHED_AGENT"
wrap_herdr_transcript "$t" "$CACHED_SID"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_AGENT_ANY=1" \
        "HERDR_STUB_AGENT_TAB=w1:t9" "HERDR_STUB_TAB_PANE_COUNT=1" \
        -- --target "$t/target" --mode work_order --prompt "and now step 2" \
           --transport herdr --detached --label "step 2 of 3")
log=$(tr -d '\\' < "$t/herdr.log")
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" ]]
check "a herdr follow-up carrying --label still connects" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
# Dropped SILENTLY — `.fallbacks` logs workarounds, and a clean reuse worked around
# nothing. An entry here would fire on every follow-up.
[[ "$(jq -r '.fallbacks | length' <<<"$out" 2>/dev/null)" == "0" ]]
check "…recording nothing about the ignored label: a clean reuse stays fallbacks:[]" $? "out=$out"
# CONTRACT GUARD. The rename plumbing is gone, so this absence IS the feature: it
# passes today and fails the moment a follow-up rename comes back. The stub is
# staged with a rename-able tab (pane_count 1) on purpose, so nothing but the code
# under test can make this pass.
! grep -qE 'tab rename|tab get' <(printf '%s' "$log")
check "…renaming nothing, and not even asking herdr about the tab" $? "herdr calls: $log"

# A follow-up with NO --label never reaches the reuse path: the args gate refuses it
# first, because whether a dial is first contact is not known when argv is read.
t=$(new_env)
stage_cache "$t" "$CACHED_SID" "$CACHED_AGENT"
wrap_herdr_transcript "$t" "$CACHED_SID"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" CMUX_LOG="$t/cmux.log" SSH_LOG="$t/ssh.log" \
      HOTLINE_CALLER_SESSION_ID="caller-dial-1" HOTLINE_PENDING_DIR="$t/pending" \
      bash "$DIAL" --target "$t/target" --mode work_order --prompt "and now step 2" \
        --transport herdr --detached 2>"$t/err.txt")
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" \
   && "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "args" ]]
check "a herdr follow-up with no --label is refused at the args gate" $? "out=$out"
[[ ! -s "$t/herdr.log" ]]
check "…reaching no herdr call at all, so re-running the fixed command is safe" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# --- the cached agent has died → a fresh launch, said out loud ---------------
t=$(new_env)
stage_cache "$t" "$CACHED_SID" "$CACHED_AGENT"
wrap_herdr_transcript "$t" "$CACHED_SID"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_AGENT_ANY=1" \
        "HERDR_STUB_GONE_NAMES=$CACHED_AGENT" "HERDR_STUB_NEW_PANE=w1:p7" \
        -- --target "$t/target" --mode work_order --prompt "and now step 2" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" ]]
check "a cached agent that no longer resolves falls back to a fresh launch" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
fb=$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)
[[ "$fb" == *"herdr-agent-reuse→fresh"* && "$fb" == *"no live herdr agent answers"* ]]
check "…recording the fallback with herdr's own reason" $? "fallbacks=$fb"
[[ "$fb" == *"WITHOUT the prior context"* ]]
check "…and stating the cost outright: herdr cannot re-host a session, so the callee is amnesiac" $? \
  "fallbacks=$fb"
grep -qE 'agent start' <(tr -d '\\' < "$t/herdr.log")
check "…having actually started a new agent" $? "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
! grep -q 'pane close' <(tr -d '\\' < "$t/herdr.log")
check "…and closed nothing: a dead agent leaves nothing live to supersede" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

NEW_AGENT=$(jq -r '.surface_ref' <<<"$out" 2>/dev/null)
NEW_SID=$(jq -r '.remote_session_id' <<<"$out" 2>/dev/null)
[[ "$NEW_AGENT" == hotline-* && "$NEW_AGENT" != "$CACHED_AGENT" \
   && -n "$NEW_SID" && "$NEW_SID" != "$CACHED_SID" ]]
check "…reporting the NEW agent name and the NEW callee session" $? \
  "surface_ref=$NEW_AGENT session=$NEW_SID"
[[ "$fb" == *"callee-session-changed(${CACHED_SID}→${NEW_SID}"* ]]
check "…and the session change itself is reported, not just implied" $? "fallbacks=$fb"
REG="$t/home/.agents-hotline/sessions/caller-dial-1.json"
[[ "$(conn session_id)" == "$NEW_SID" && "$(conn surface_ref)" == "$NEW_AGENT" ]]
check "…with the cache re-keyed, so the NEXT follow-up addresses the live callee" $? \
  "registry: $(cat "$REG" 2>/dev/null)"

# THE PAYLOAD IS RE-RENDERED AS FIRST CONTACT. This callee is brand new: it never
# loaded the ringing skill, so the follow-up-shaped prompt the reuse path would have
# sent lands as prose — no STATUS line ever emitted, and the caller's waiter spends
# its whole budget on a protocol nobody engaged. cmux never reaches this state (its
# fresh launch --resumes the same session); herdr cannot re-host a session at all.
FRESH_DELIVERED="$t/home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/$NEW_SID.jsonl"
grep -q 'hotline-ringing' "$FRESH_DELIVERED" 2>/dev/null
check "…and the fresh callee is RUNG: its delivered prompt carries the ringing invocation" $? \
  "delivered: $(head -c 400 "$FRESH_DELIVERED" 2>/dev/null)"
grep -q 'and now step 2' "$FRESH_DELIVERED" 2>/dev/null \
  && grep -q 'MODE: work_order' "$FRESH_DELIVERED" 2>/dev/null
check "…with the follow-up message and the protocol tags beneath it" $? \
  "delivered: $(head -c 400 "$FRESH_DELIVERED" 2>/dev/null)"
# .first_contact still answers "did this dial have a cached session to work from",
# and this one did. Only the prompt shape changed.
[[ "$(jq -r '.first_contact' <<<"$out" 2>/dev/null)" == "false" ]]
check "…while the emitted first_contact stays false: the cache entry was real" $? "out=$out"
# The agent name names the TARGET, on this fallback launch as on a first contact.
# It used to be slugged from the session name ("hotline: a → b (mode)"), which
# basenames to itself, so every agent in `herdr agent list` read hotline-hotline-*
# and none of them said which directory its callee was sitting in
# (claude-plugins-hukk).
[[ "$NEW_AGENT" == "hotline-$(basename "$t/target")-"* ]]
check "…and the new agent is named off the TARGET's cwd slug, not the session name" $? \
  "agent=$NEW_AGENT (expected hotline-$(basename "$t/target")-*)"

# --- a RESHAPED follow-up whose delivery is refused ------------------------
# The 63om state, reached from the other side. This follow-up's cached agent is
# gone, so it reshapes as a first contact and launches a fresh callee — and
# register-call.sh's `set` REPLACES the cache entry with that callee at
# boot-confirm. When the delivery is then refused, the entry names an agent that
# never got its opening prompt, exactly as on a first contact; the prior exchange
# it used to describe is no longer in there to protect. The forget gate read
# $FIRST_CONTACT alone, which is false here, so the entry survived.
t=$(new_env)
stage_cache "$t" "$CACHED_SID" "$CACHED_AGENT"
wrap_herdr_transcript "$t" "$CACHED_SID"
trust_dialog_screen "$t/screen.txt" "$(cd "$t/target" && pwd -P)"
REG="$t/home/.agents-hotline/sessions/caller-dial-1.json"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_AGENT_ANY=1" \
        "HERDR_STUB_GONE_NAMES=$CACHED_AGENT" "HERDR_STUB_NEW_PANE=w1:p7" \
        "HERDR_STUB_SCREEN=$t/screen.txt" \
        -- --target "$t/target" --mode work_order --prompt "and now step 2" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "deliver" ]] \
  && [[ "$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)" == *"herdr-agent-reuse→fresh"* ]]
check "a reshaped follow-up refused at delivery fails at stage=deliver" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ -z "$(jq -r --arg tp "$(cd "$t/target" && pwd -P)" '.connections[$tp] // empty' \
          "$REG" 2>/dev/null)" ]]
check "…and its cache entry is GONE too, not left naming the fresh callee that was never rung" $? \
  "cache: $(cat "$REG" 2>/dev/null)"

# THE CONSEQUENCE, same as the first-contact case: the re-dial starts clean instead
# of arriving as a follow-up into an agent that never existed.
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_NEW_PANE=w1:p9" \
        -- --target "$t/target" --mode work_order --prompt "and now step 2" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.first_contact' <<<"$out" 2>/dev/null)" == "true" \
   && "$(jq -c '.fallbacks' <<<"$out" 2>/dev/null)" != *"herdr-agent-reuse"* ]]
check "…so the re-dial connects as a FIRST CONTACT, with no reuse fallback at all" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# --- a follow-up into a BLOCKED cached agent, THROUGH dial.sh ----------------
# The orphan the direct-script tests above cannot see: dial.sh used to answer a
# refused reuse by starting a SECOND callee and re-keying the cache to it, leaving
# the blocked agent live, holding the only copy of the conversation, and no longer
# addressable through hotline (claude-plugins-7wze.13). It fails the dial instead.
t=$(new_env)
stage_cache "$t" "$CACHED_SID" "$CACHED_AGENT"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_AGENT_ANY=1" "HERDR_STUB_STATUS=blocked" \
        -- --target "$t/target" --mode work_order --prompt "step 2" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" \
   && "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "transport" ]]
check "a follow-up into a BLOCKED herdr agent FAILS the dial (stage=transport)" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
log=$(tr -d '\\' < "$t/herdr.log")
! grep -qE 'agent start|pane split' <(printf '%s' "$log")
check "…starting no second callee, so the blocked agent is not orphaned" $? \
  "herdr calls: $log"
! grep -q 'agent prompt' <(printf '%s' "$log")
check "…and submitting nothing into the gate it is sitting on" $? "herdr calls: $log"
REG="$t/home/.agents-hotline/sessions/caller-dial-1.json"
[[ "$(conn surface_ref)" == "$CACHED_AGENT" && "$(conn session_id)" == "$CACHED_SID" \
   && "$(conn exchange_count)" == "1" ]]
check "…leaving the cache pointed at the blocked agent, NOT re-keyed to a new one" $? \
  "registry: $(cat "$REG" 2>/dev/null)"

# The actionable half of the reason has to SURVIVE. dial.sh's forwarding used to cut
# at 140, which severed `herdr agent attach <name>` off the end — the one thing a
# reader of this error can act on.
[[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"herdr agent attach $CACHED_AGENT"* ]]
check "…with the attach hint intact in .detail (nothing severs it now)" $? \
  "detail=$(jq -r '.detail' <<<"$out" 2>/dev/null)"
[[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"re-dial exactly as you just did"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"context intact"* ]]
check "…and a recovery that says the context is still there once a human clears it" $? \
  "recovery=$(jq -r '.recovery' <<<"$out" 2>/dev/null)"

# A BLINK must not fail the dial: blocked on the first read, clear on the confirming
# one, and the follow-up lands in the same agent as though nothing happened.
t=$(new_env)
stage_cache "$t" "$CACHED_SID" "$CACHED_AGENT"
wrap_herdr_transcript "$t" "$CACHED_SID"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_AGENT_ANY=1" "HERDR_STUB_BLOCKED_ONCE=1" \
        -- --target "$t/target" --mode work_order --prompt "step 2" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.surface_ref' <<<"$out" 2>/dev/null)" == "$CACHED_AGENT" ]]
check "a blocked BLINK on a follow-up neither fails the dial nor starts a second callee" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
! grep -qE 'agent start|pane split' <(tr -d '\\' < "$t/herdr.log")
check "…reusing the cached agent, exactly as it would have without the blink" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# --- a cached session with no host handle at all -----------------------------
# A prior headless exchange leaves no host to re-target. Fresh launch, and the
# fallback says the context is gone rather than letting a caller assume continuity.
t=$(new_env)
stage_cache "$t" "$CACHED_SID" ""
wrap_herdr_transcript "$t" "$CACHED_SID"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_AGENT_ANY=1" \
        -- --target "$t/target" --mode work_order --prompt "step 2" \
           --transport herdr --detached --boot-timeout 5)
fb=$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$fb" == *"herdr-agent-reuse-skipped(no-cached-host-handle"* ]]
check "a cached session with no host handle → fresh launch, with the skip recorded" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.first_contact' <<<"$out" 2>/dev/null)" == "false" ]] \
  && [[ "$fb" == *"without the prior context"* ]]
check "…still first_contact:false (the cache entry is real; only the host is missing), and the loss is named" $? \
  "out=$out"
# The reuse script is never invoked here, so nothing probes an agent BEFORE the
# launch: every `agent get` in this log belongs to the fresh call (the launcher's
# name-collision check, then delivery's own liveness check).
! grep -q 'agent get' <(sed -n '1,/pane split/p' <(tr -d '\\' < "$t/herdr.log")) \
  && grep -q 'agent start' <(tr -d '\\' < "$t/herdr.log")
check "…and no liveness probe was made before the launch: there was no handle to probe" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# --- herdr-reuse-agent.sh directly ------------------------------------------
# A BLOCKED agent refuses the reuse. This is the herdr analogue of cmux's
# post-interrupt refusal: a work order submitted into a permission gate ANSWERS
# the gate instead of starting a turn.
#
# And it is NOT fallback:fresh (claude-plugins-7wze.13). That agent is live and
# holds the only copy of this conversation, so answering with a fresh callee
# strands it — see TWO STATES REFUSE THE REUSE in the script.
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=blocked \
      bash "$HERDR_REUSE" --agent hotline-b-1 --session s-b --prompt "next thing" \
        --cwd "$t/target" 2>/dev/null)
[[ "$(jq -r '.blocked' <<<"$out" 2>/dev/null)" == "true" \
   && "$(jq -r '.agent' <<<"$out" 2>/dev/null)" == "hotline-b-1" \
   && "$(jq -r '.fallback // "none"' <<<"$out" 2>/dev/null)" == "none" ]]
check "reuse into a BLOCKED agent → blocked:true, NOT fallback:fresh (a fresh callee would strand it)" $? \
  "out=$out"
! grep -q 'agent prompt' "$t/herdr.log" 2>/dev/null
check "…before submitting anything" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ "$(grep -c 'agent get hotline-b-1' <(tr -d '\\' < "$t/herdr.log"))" -ge 2 ]]
check "…and only after a CONFIRMING second read, so a blink cannot fail a good follow-up" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# The blink itself: blocked on the first read, clear on the confirming one. The
# follow-up proceeds, because nothing was ever actually wrong with it.
t=$(new_env)
wrap_herdr_transcript "$t" "blink-sess"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_BLOCKED_ONCE=1 \
      bash "$HERDR_REUSE" --agent hotline-b-2 --session blink-sess --prompt "next thing" \
        --cwd "$t/target" 2>/dev/null)
[[ "$(jq -r '.delivery' <<<"$out" 2>/dev/null)" == "prompt" \
   && "$(jq -r '.blocked // false' <<<"$out" 2>/dev/null)" == "false" ]]
check "a blocked BLINK the confirming read refutes → the follow-up goes through" $? "out=$out"

# Blocked, then gone: it exited while waiting on that input. Nothing live holds the
# context any more, so this IS a legitimate fallback rather than a dial failure.
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 HERDR_STUB_STATUS=blocked \
      HERDR_STUB_GONE_AFTER=1 \
      bash "$HERDR_REUSE" --agent hotline-b-3 --session s-b3 --prompt "next" \
        --cwd "$t/target" 2>/dev/null)
[[ "$(jq -r '.fallback' <<<"$out" 2>/dev/null)" == "fresh" \
   && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"exited while waiting"* ]]
check "an agent that was blocked and has since EXITED falls back (nothing live to strand)" $? \
  "out=$out"

t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_GONE=1 \
      bash "$HERDR_REUSE" --agent hotline-g-1 --session s-g --prompt "next" \
        --cwd "$t/target" 2>/dev/null)
[[ "$(jq -r '.fallback' <<<"$out" 2>/dev/null)" == "fresh" ]] \
  && [[ "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"exited"* ]]
check "reuse into a GONE agent refuses with fallback:fresh, naming the exit" $? "out=$out"
! grep -q 'agent prompt' "$t/herdr.log" 2>/dev/null
check "…and submits nothing" $? "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# The call-dir contract of a reused call: identical to a launched one, minus the
# launch — so every downstream reader treats it the same.
t=$(new_env)
wrap_herdr_transcript "$t" "reuse-sess-1"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 \
      bash "$HERDR_REUSE" --agent hotline-r-live --session reuse-sess-1 \
        --prompt "the follow-up" --cwd "$t/target" 2>/dev/null)
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ -n "$cd_path" && "$(jq -r '.confirmed' <<<"$out" 2>/dev/null)" == "transcript" \
   && "$(jq -r '.delivery' <<<"$out" 2>/dev/null)" == "prompt" ]]
check "a live agent → a call_dir with the delivery confirmed by transcript" $? "out=$out"
[[ "$(cat "$cd_path/transport.txt" 2>/dev/null)" == "herdr" \
   && "$(cat "$cd_path/herdr_agent.txt" 2>/dev/null)" == "hotline-r-live" \
   && "$(cat "$cd_path/keep_workspace.txt" 2>/dev/null)" == "true" \
   && "$(cat "$cd_path/session_id.txt" 2>/dev/null)" == "reuse-sess-1" ]]
check "…wired like the launcher's call dir (transport / agent / keep / session)" $? \
  "call_dir: $(ls "$cd_path" 2>/dev/null | tr '\n' ' ')"
[[ ! -f "$cd_path/herdr_pane.txt" && ! -f "$cd_path/surface_ref.txt" \
   && ! -f "$cd_path/workspace_ref.txt" ]]
check "…and names no pane and no cmux handle (it placed no host)" $? \
  "call_dir: $(ls "$cd_path" 2>/dev/null | tr '\n' ' ')"
[[ ! -f "$cd_path/pending_paste.md" ]]
check "…with the delivered payload removed once confirmed" $? \
  "call_dir: $(ls "$cd_path" 2>/dev/null | tr '\n' ' ')"

# The same canonicalization the launcher does, and for the same reason: Claude Code
# encodes the cwd it RESOLVED, and every consumer derives the transcript path from
# this file.
t=$(new_env)
ln -s "$t/target" "$t/linked"
wrap_herdr_transcript "$t" "reuse-sess-2"
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 \
      bash "$HERDR_REUSE" --agent hotline-r-link --session reuse-sess-2 \
        --prompt "hi" --cwd "$t/linked" 2>/dev/null)
cd_path=$(jq -r '.call_dir // empty' <<<"$out" 2>/dev/null)
[[ "$(cat "$cd_path/cwd.txt" 2>/dev/null)" == "$(cd "$t/target" && pwd -P)" ]]
check "reuse canonicalizes cwd.txt too, so a symlinked target still resolves" $? \
  "cwd.txt='$(cat "$cd_path/cwd.txt" 2>/dev/null)' want='$(cd "$t/target" && pwd -P)'"

# Submitted and unconfirmable is NOT a fallback: the payload may already be queued,
# so re-delivering it into a fresh callee would run the work order twice.
t=$(new_env)
out=$(env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" HERDR_STUB_AGENT_ANY=1 \
      bash "$HERDR_REUSE" --agent hotline-r-unconf --session reuse-sess-3 \
        --prompt "hi" --cwd "$t/target" 2>/dev/null)
[[ "$(jq -r '.undelivered' <<<"$out" 2>/dev/null)" == "true" \
   && "$(jq -r '.fallback // empty' <<<"$out" 2>/dev/null)" == "" ]]
check "submitted but unconfirmed → undelivered:true, never fallback:fresh (no double-run)" $? \
  "out=$out"
pf=$(jq -r '.prompt_file // empty' <<<"$out" 2>/dev/null)
[[ -s "$pf" ]] && grep -q 'hi' "$pf"
check "…keeping the only copy of the prompt on disk for recovery" $? "prompt_file=$pf"

# …and dial.sh turns that into a stage=deliver ERROR with an explicit do-not-re-dial.
t=$(new_env)
stage_cache "$t" "$CACHED_SID" "$CACHED_AGENT"
out=$(dial "$t" "HERDR_PANE_ID=w1:p1" "HERDR_STUB_AGENT_ANY=1" \
        -- --target "$t/target" --mode work_order --prompt "step 2" \
           --transport herdr --detached)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" \
   && "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "deliver" ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"Do NOT re-dial"* ]]
check "an unconfirmable FOLLOW-UP errors at stage=deliver, telling the caller not to re-dial" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
! grep -qE 'agent start|pane split' <(tr -d '\\' < "$t/herdr.log")
check "…and never launches a second callee behind it" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

herdr_suite_finish
