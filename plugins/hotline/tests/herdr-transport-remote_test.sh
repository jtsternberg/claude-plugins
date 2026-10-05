#!/usr/bin/env bash
# =============================================================================
# herdr transport regression tests: remote callees (--remote): the same verbs, one
# ssh hop away (section 9).
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
echo "9. Remote callees (--remote) — the same verbs, one ssh hop away:"
# ===========================================================================
# Phase 3b's whole claim is that a remote callee needs no second implementation:
# `HOTLINE_HERDR_REMOTE` makes herdr_cli run `ssh <target> herdr …` and everything
# downstream is the local arm. These cases pin the four places that CANNOT come
# along for free, because each one is a fact about the other box:
#
#   1. PREFLIGHT ASKS THAT BOX, not this one — and gains a check with no local
#      counterpart (`claude` on a non-login remote PATH). HERDR_ENV=1 is
#      deliberately NOT accepted as proof of a server there.
#   2. THE PAYLOAD RIDES STDIN. A work order substituted into the ssh command line
#      would move the `ps` window from the box running it onto the caller's own
#      machine, which is where claude-plugins-86ka's threat actually lives.
#   3. THE TRANSCRIPT IS REMOTE. Both halves of its path — $HOME and the realpath
#      of the cwd — belong to the far side and are asked for, never assumed
#      (claude-plugins-7wze.10); the file is then fetched into a local mirror and
#      read by an UNCHANGED transcript-extract.sh.
#   4. TAILSCALE SSH CAN TALK. Its check-mode notice must never be parsed as data,
#      and when the check period lapses the resulting stall must surface as an
#      error naming the URL rather than as silence.

remote_env() {  # remote_env — a scratch env plus the ssh target every case uses
  local t
  t=$(new_env)
  # The "remote" claude, so preflight's last check passes. Its content is
  # irrelevant: nothing here ever runs it, `command -v` is the whole question.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$t/bin/claude"
  chmod +x "$t/bin/claude"
  printf '%s' "$t"
}

# Every remote case runs with the same env shape; RTARGET is the target string, and
# it is deliberately one that would NEVER resolve if a stub were missing.
RTARGET="tester@no-such-box.invalid"

rcheck() {  # rcheck <scratch> <extra-env...> -- <script> <args...>
  local t="$1"; shift
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" SSH_LOG="$t/ssh.log" \
      HOTLINE_HERDR_REMOTE="$RTARGET" \
      ${envs[@]+"${envs[@]}"} bash "$@" 2>"$t/err.txt"
}

# The waiter's variant, and the difference is the point: it runs with NO
# HOTLINE_HERDR_REMOTE in the environment, because wait-for-response.sh is a
# separate process that inherits nothing and must learn the target from
# remote_target.txt alone. Handing it the variable would make a waiter that ignored
# that file pass anyway — which is exactly how the first version of these cases
# proved nothing.
wcheck() {  # wcheck <scratch> <extra-env...> -- <script> <args...>
  local t="$1"; shift
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" SSH_LOG="$t/ssh.log" \
      HOTLINE_HERDR_REMOTE= \
      ${envs[@]+"${envs[@]}"} bash "$@" 2>"$t/err.txt"
}

# --- Preflight, asked of the far side ---------------------------------------

t=$(remote_env)
out=$(rcheck "$t" "SSH_STUB_FAIL=1" -- "$CHECK_HERDR"); rc=$?
[[ $rc -ne 0 && "$(jq -r '.usable' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"could not be reached over ssh"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"NON-INTERACTIVELY"* ]]
check "an unreachable target fails preflight on the HOP, before anything about herdr" $? \
  "rc=$rc out=$out"
[[ ! -s "$t/herdr.log" ]]
check "…and no herdr question is asked of a box we could not reach" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

t=$(remote_env)
out=$(rcheck "$t" "SSH_STUB_NO_HERDR=1" -- "$CHECK_HERDR"); rc=$?
[[ $rc -ne 0 && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"not on PATH on $RTARGET"* ]]
check "herdr missing on the TARGET names the target, not the caller's own install" $? \
  "rc=$rc out=$out"

t=$(remote_env)
out=$(rcheck "$t" "HERDR_STUB_SESSION_RC=1" -- "$CHECK_HERDR"); rc=$?
[[ $rc -ne 0 && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"no server answered"* ]] \
  && [[ "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"$RTARGET"* ]]
check "no herdr server THERE is reported as that, and names which box" $? "rc=$rc out=$out"

# The carve-out that matters: being inside a herdr pane proves a server is hosting
# THIS process, which says nothing about the box the callee will live on. Accepting
# it would skip the only check that catches a stopped remote server.
t=$(remote_env)
out=$(rcheck "$t" "HERDR_STUB_SESSION_RC=1" "HERDR_ENV=1" "HERDR_PANE_ID=w9:p1" \
        -- "$CHECK_HERDR"); rc=$?
[[ $rc -ne 0 && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"no server answered"* ]]
check "HERDR_ENV=1 is NOT proof of a server on the remote box" $? "rc=$rc out=$out"

t=$(remote_env)
out=$(rcheck "$t" "HERDR_STUB_NO_PANES=1" -- "$CHECK_HERDR"); rc=$?
[[ $rc -ne 0 && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"no pane could be resolved"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"HOTLINE_HERDR_REMOTE_PANE"* ]]
check "no remote pane points at HOTLINE_HERDR_REMOTE_PANE, not the local override" $? \
  "rc=$rc out=$out"

# The one check with no local counterpart. A non-login `ssh host cmd` gets that
# box's own PATH, so a claude under ~/.local/bin may simply not resolve there.
t=$(remote_env)
out=$(rcheck "$t" "SSH_STUB_NO_CLAUDE=1" -- "$CHECK_HERDR"); rc=$?
[[ $rc -ne 0 && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"claude is not on the PATH"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"command -v claude"* ]]
check "claude missing from the REMOTE non-login PATH is its own failure, with its own fix" $? \
  "rc=$rc out=$out"

t=$(remote_env)
out=$(rcheck "$t" "HERDR_STUB_PANE=w7:p2" -- "$CHECK_HERDR"); rc=$?
[[ $rc -eq 0 && "$(jq -r '.usable' <<<"$out" 2>/dev/null)" == "true" \
   && "$(jq -r '.pane' <<<"$out" 2>/dev/null)" == "w7:p2" \
   && "$(jq -r '.remote' <<<"$out" 2>/dev/null)" == "$RTARGET" ]]
check "a healthy remote reports usable:true with the REMOTE pane and .remote" $? \
  "rc=$rc out=$out"

# HOTLINE_HERDR_REMOTE_PANE overrides; $HERDR_PANE_ID (the CALLER's own pane, on
# this machine) must never be applied to another box's layout.
t=$(remote_env)
out=$(rcheck "$t" "HOTLINE_HERDR_REMOTE_PANE=w4:p1" "HERDR_PANE_ID=w9:p9" \
        "HOTLINE_HERDR_PANE=w8:p8" -- "$CHECK_HERDR"); rc=$?
[[ $rc -eq 0 && "$(jq -r '.pane' <<<"$out" 2>/dev/null)" == "w4:p1" ]]
check "HOTLINE_HERDR_REMOTE_PANE wins, and the LOCAL pane vars are ignored remotely" $? \
  "rc=$rc out=$out"

# --- The ControlMaster directory: a rendezvous point, never adopted blindly --
# The socket lives in a private directory because anyone who can write that path can
# put a socket there and be handed an authenticated connection. Two rules, and `-d`
# quietly breaks the second: it FOLLOWS a symlink, so a pre-planted link passed the
# directory test, skipped the mkdir, and relocated the socket to wherever it pointed
# — with the ownership test then answering for the link's target, not the link.
mux_state() {  # mux_state <control-home> → socket path on line 1, the note on line 2
  env HOTLINE_HERDR_REMOTE="$RTARGET" HOTLINE_SSH_CONTROL_HOME="$1" \
    bash -c 'source "$1/scripts/herdr-remote.sh"; hotline_remote_mux_init
             printf "%s\n%s\n" "$HOTLINE_REMOTE_CONTROL_PATH" "$HOTLINE_REMOTE_MUX_NOTE"' \
    _ "$HOTLINE_DIR"
}
t=$(remote_env)
CTRL_HOME="$HOTLINE_SSH_CONTROL_HOME/test-ctrl"; mkdir -p "$CTRL_HOME"
MUX=$(mux_state "$CTRL_HOME")
CTRL_PATH=$(sed -n '1p' <<<"$MUX")
CTRL_DIR=""
if [[ -n "$CTRL_PATH" ]]; then
  CTRL_DIR=$(dirname "$CTRL_PATH")
fi
# `ls -ld`, not `stat`: GNU `stat -f` is `--file-system` and SUCCEEDS on a directory
# with filesystem info, so a `stat -f … || stat -c …` fallback never reaches the GNU
# form and this case failed on the ubuntu runner alone.
MODE=""
if [[ -n "$CTRL_DIR" ]]; then
  MODE=$(ls -ld "$CTRL_DIR" 2>/dev/null | cut -c1-10)
fi
[[ -n "$CTRL_PATH" && -d "$CTRL_DIR" && "$MODE" == "drwx------" ]]
check "the control directory is created 0700 — no window in which to plant the socket" $? \
  "mux=$MUX mode=$MODE"

mkdir -p "$t/elsewhere"
if [[ -n "$CTRL_DIR" ]]; then
  rm -rf "$CTRL_DIR"
  ln -s "$t/elsewhere" "$CTRL_DIR"
fi
MUX=$(mux_state "$CTRL_HOME")
[[ -z "$(sed -n '1p' <<<"$MUX")" && "$MUX" == *"symlink"* ]]
check "a SYMLINKED control dir is refused, not adopted: the -d test follows a link" $? \
  "mux=$MUX"
# And the consequence a hop actually sees: multiplexing is GIVEN UP rather than
# pointed at the link's target. Every hop then re-authenticates, which is a cost —
# and the right one to pay next to handing a rendezvous socket to a path somebody
# else chose.
out=$(rcheck "$t" "HOTLINE_SSH_CONTROL_HOME=$CTRL_HOME" "HERDR_STUB_PANE=w2:p2" \
        -- "$CHECK_HERDR"); rc=$?
[[ $rc -eq 0 ]] && ! grep -qF -- '-o ControlPath=' "$t/ssh.log.argv"
check "…and the hops that follow carry no ControlPath at all, rather than that one" $? \
  "rc=$rc argv: $(cat "$t/ssh.log.argv" 2>/dev/null)"

# --- Tailscale SSH, which talks ---------------------------------------------
# Its check-mode notice arrives ahead of the real output on either stream. Parsed as
# data it would break every JSON read; the layer filters it out of both.
t=$(remote_env)
out=$(rcheck "$t" "SSH_STUB_TAILSCALE=1" "HERDR_STUB_PANE=w2:p2" -- "$CHECK_HERDR"); rc=$?
[[ $rc -eq 0 && "$(jq -r '.pane' <<<"$out" 2>/dev/null)" == "w2:p2" ]]
check "Tailscale's check-mode notice is filtered, not parsed — preflight still reads the pane" $? \
  "rc=$rc out=$out"
[[ "$out" != *"login.tailscale.com"* ]]
check "…and it does not leak into the emitted JSON" $? "out=$out"

# And when the check period has lapsed, the BatchMode hop blocks on an
# authentication it cannot perform. Bounded, that is an error naming the URL; the
# alternative is a silent half-hour in the middle of a work order.
# The margin is sized for the slowest scheduling, not the fastest: the stub prints
# the notice before it stalls, but it is a separate process, and a 1s budget can
# expire before its first write is even scheduled when the suite runs several jobs
# wide. That reads as "the error lost the URL" — a false red, reproduced at 2 of 4
# concurrent runs. Keep sleep >> timeout so the kill still happens, and keep the
# timeout clear of scheduling jitter.
t=$(remote_env)
out=$(rcheck "$t" "SSH_STUB_SLEEP=10" "SSH_STUB_TAILSCALE=1" "HOTLINE_REMOTE_SSH_TIMEOUT=3" \
        -- "$CHECK_HERDR"); rc=$?
[[ $rc -ne 0 && "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"timed out"* ]] \
  && [[ "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"login.tailscale.com/a/f00dcafe"* ]]
check "a stalled hop times out and the error NAMES the tailnet check URL" $? "rc=$rc out=$out"

# --- Delivery: the payload rides stdin --------------------------------------

# One remote first-contact delivery, end to end through herdr-prompt.sh, against a
# transcript the stub writes exactly as a callee would.
# THE REMOTE $HOME IS NOT THE LOCAL ONE, and these cases insist on it. The stub
# runs the remote command in this shell, so without an override the two coincide —
# and then a reader that skipped the ssh hop and used the caller's own $HOME would
# derive exactly the right path and every assertion below would still pass. The
# transcript therefore lives under $t/remote-home, which nothing local points at.
remote_delivery_env() {
  local t
  t=$(remote_env)
  mkdir -p "$t/remote-home"
  # The stub cannot precompute the transcript path (it learns the session id from
  # `agent start`), so a thin wrapper fills it in — the callee recording the turn
  # it actually received, which is the only tier a delivery is confirmed by.
  cat > "$t/bin/herdr" <<STUBW
#!/usr/bin/env bash
if [[ "\$1 \${2:-}" == "agent prompt" ]]; then
  export HERDR_STUB_TRANSCRIPT="$t/remote-home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/remote-sess-1.jsonl"
fi
exec bash "$t/bin/herdr-real" "\$@"
STUBW
  chmod +x "$t/bin/herdr"
  mkdir -p "$t/binsrc"; make_herdr_stub "$t/binsrc"; mv "$t/binsrc/herdr" "$t/bin/herdr-real"
  printf '%s' "$t"
}

t=$(remote_delivery_env)
# A payload with every character that shell quoting gets wrong: single quotes,
# double quotes, `$VAR`, backticks, a glob, and a newline.
printf '%s\n' "[CALL_ID: rmt-nonce-1] it's \"quoted\" \$VAR \`tick\` * and more" > "$t/payload.md"
out=$(rcheck "$t" "HERDR_STUB_AGENT_ANY=1" "HERDR_STUB_OBSERVED_SID=remote-sess-1" \
        "SSH_STUB_HOME=$t/remote-home" \
        -- "$HERDR_PROMPT" --agent p3b-agent --payload-file "$t/payload.md" \
           --call-id rmt-nonce-1 --cwd "$t/target" --session remote-sess-1)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "true" \
   && "$(jq -r '.confirmed' <<<"$out" 2>/dev/null)" == "transcript" ]]
check "a remote delivery is confirmed by the nonce in the REMOTE transcript" $? \
  "out=$out stderr=$(cat "$t/err.txt") ssh=$(cat "$t/ssh.log" 2>/dev/null)"

grep -q "'agent' 'prompt' .*\"\$(cat)\"" "$t/ssh.log"
check "…submitted through a FIXED remote command that reads stdin" $? \
  "ssh hops: $(cat "$t/ssh.log" 2>/dev/null)"
# `and more` deliberately, not the quote-heavy part of the payload: single-quoting
# rewrites `it's` as it'\''s, so grepping for THAT passed even with the whole
# payload sitting in the log. The assertion has to look for text quoting leaves alone.
! grep -q 'and more' "$t/ssh.log"
check "…so the work order never appears in the LOCAL ssh process's argv (86ka)" $? \
  "ssh hops: $(cat "$t/ssh.log" 2>/dev/null)"

# --- The hop's own OPTIONS, pinned ------------------------------------------
# Read off the argv log, because the parsed log above cannot see them. Each of
# these is load-bearing and each fails silently when dropped: BatchMode is what
# keeps a hop from sitting on a password prompt, ConnectTimeout what keeps it from
# sitting on an unreachable box, and the shared ControlPath is the whole reason a
# dial authenticates to a tailnet once instead of a dozen times.
ARGV="$t/ssh.log.argv"
HOPS=$(grep -c '' "$ARGV" 2>/dev/null || echo 0)
[[ $HOPS -ge 2 ]] \
  && [[ "$(grep -cF -- '-o BatchMode=yes' "$ARGV")" -eq "$HOPS" ]] \
  && [[ "$(grep -cF -- '-o ConnectTimeout=' "$ARGV")" -eq "$HOPS" ]] \
  && [[ "$(grep -cF -- '-o ControlMaster=auto' "$ARGV")" -eq "$HOPS" ]] \
  && [[ "$(grep -cF -- '-o ControlPath=' "$ARGV")" -eq "$HOPS" ]]
check "every ssh hop carries BatchMode, a ConnectTimeout and the shared ControlPath" $? \
  "$HOPS hops: $(cat "$ARGV" 2>/dev/null)"
# `-n` ON EVERY HOP THAT CARRIES NO PAYLOAD: without it ssh reads the calling
# script's stdin, so one hop inside a `while read` loop swallows the rest of that
# loop's input. And NOT on the delivery hop, whose stdin IS the payload — `-n`
# there would submit an empty prompt and confirm nothing.
NO_N=$(grep -v '^-n ' "$ARGV" 2>/dev/null || true)
[[ -n "$NO_N" ]] \
  && [[ "$(grep -c '' <<<"$NO_N")" -eq "$(grep -cF -- '"$(cat)"' <<<"$NO_N")" ]] \
  && [[ "$(grep -c '^-n ' "$ARGV")" -ge 1 ]]
check "…with -n on every hop but the payload one, whose stdin is the work order" $? \
  "hops without -n: $NO_N · hops with: $(grep -c '^-n ' "$ARGV")"

# The bytes have to survive the hop intact, not merely arrive. The stub writes what
# the callee received; compare it to what `$(cat)` of the payload would be locally,
# which is the same trailing-newline-stripped form the local arm delivers.
GOT=$(jq -r 'select(.type=="user") | .message.content' \
        "$t/remote-home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/remote-sess-1.jsonl" 2>/dev/null | tail -1)
[[ "$GOT" == "$(cat "$t/payload.md")" ]]
check "…and the payload arrives byte-identical through the quoting and the wire" $? \
  "got: $GOT"

# The remote transcript's path is derived from the REMOTE \$HOME and the REMOTE
# realpath of the cwd (claude-plugins-7wze.10). Proof: the confirmation found it at
# the REALPATH encoding while the cwd it was handed was the /tmp spelling.
grep -qF -- "$(encode_cwd "$(cd "$t/target" && pwd -P)")" "$t/ssh.log"
check "…at a path derived from the remote \$HOME and the remote realpath, asked over ssh" $? \
  "ssh hops: $(cat "$t/ssh.log" 2>/dev/null | tail -3)"

# THE TRUST DIALOG, one hop away. The screen probe runs over ssh and refuses with
# sent:false naming the remote directory — exactly as it does locally, because
# `agent read` sees just as little of an alternate-screen TUI from either side.
t=$(remote_delivery_env)
printf 'Do you trust the files in this folder?\n\n%s\n\n1. Yes, proceed\n2. No, exit\n' "$t/target" \
  > "$t/screen.txt"
printf '/hotline:hotline-ringing [MODE: work_order]\n[CALL_ID: rmt-nonce-2] go\n' > "$t/payload2.md"
out=$(rcheck "$t" "HERDR_STUB_AGENT_ANY=1" "HERDR_STUB_SCREEN=$t/screen.txt" \
        "SSH_STUB_HOME=$t/remote-home" \
        -- "$HERDR_PROMPT" --agent p3b-agent --payload-file "$t/payload2.md" \
           --call-id rmt-nonce-2 --cwd "$t/target" --session remote-sess-1 --first-contact)
[[ "$(jq -r '.delivered' <<<"$out" 2>/dev/null)" == "false" \
   && "$(jq -r '.sent' <<<"$out" 2>/dev/null)" == "false" ]] \
  && [[ "$(jq -r '.reason' <<<"$out" 2>/dev/null)" == *"$t/target"* ]]
check "a remote TRUST DIALOG refuses with sent:false, naming the remote directory" $? \
  "out=$out"
! grep -q 'agent prompt' "$t/ssh.log"
check "…and nothing was submitted, so re-dialing that box is safe" $? \
  "ssh hops: $(cat "$t/ssh.log" 2>/dev/null)"

# --- The response wait: fetch, then the UNCHANGED extractor ------------------

t=$(remote_env)
mkdir -p "$t/remote-home"
cd_path=$(mktemp -d "$HOTLINE_CALL_HOME/hotline-call-XXXXX")
echo herdr             > "$cd_path/transport.txt"
echo p3b-remote-agent  > "$cd_path/herdr_agent.txt"
echo "$RTARGET"        > "$cd_path/remote_target.txt"
echo "$t/target"       > "$cd_path/cwd.txt"
echo remote-sess-2     > "$cd_path/session_id.txt"
echo rmt-nonce-3       > "$cd_path/call_id.txt"
# Under the REMOTE $HOME, and deliberately NOT under the local one: a waiter that
# ignored remote_target.txt would derive a local path with nothing at it, which is
# what makes this case prove the routing rather than assume it.
transcript_with \
  "$t/remote-home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/remote-sess-2.jsonl" \
  rmt-nonce-3 WORK_COMPLETE "the remote callee answered"
out=$(wcheck "$t" "HERDR_STUB_AGENT_ANY=1" "HOTLINE_POLL_SLEEP=0" \
        "SSH_STUB_HOME=$t/remote-home" \
        -- "$WAIT_RESPONSE" "$cd_path" --timeout 20); rc=$?
[[ $rc -eq 0 && "$(jq -r '.response' <<<"$out" 2>/dev/null)" == *"the remote callee answered"* \
   && "$(jq -r '.session_id' <<<"$out" 2>/dev/null)" == "herdr-sess" ]]
check "the wait reads a REMOTE transcript and extracts it with the unchanged extractor" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"
[[ -s "$cd_path/remote_transcript.jsonl" ]]
check "…via a local mirror in the call dir, so what it read is inspectable" $? \
  "call dir: $(ls "$cd_path" | tr '\n' ' ')"
grep -q 'cat "\$p"' "$t/ssh.log"
check "…fetched with one \`cat\` over the already-authenticated hop" $? \
  "ssh hops: $(cat "$t/ssh.log" 2>/dev/null | tail -2)"

# AND CARRYING THE SAME OPTIONS, asserted here because this hop is built by the
# OTHER caller of hotline_remote_ssh_opts: the delivery block's identical assertion
# never sees it (nothing in a dial fetches a transcript — the waiter does), so for a
# while `-o BatchMode=yes` could be deleted from this site with the whole suite
# still green. It is the hop that repeats every poll, i.e. the likeliest of all to
# sit on a lapsed tailnet check. The `cat "$p"` grep is what keeps this from passing
# vacuously over hops that are not the fetch.
ARGV="$t/ssh.log.argv"
HOPS=$(grep -c '' "$ARGV" 2>/dev/null || echo 0)
[[ $HOPS -ge 2 ]] \
  && grep -qF -- 'cat "$p"' "$ARGV" \
  && [[ "$(grep -cF -- '-o BatchMode=yes' "$ARGV")" -eq "$HOPS" ]] \
  && [[ "$(grep -cF -- '-o ConnectTimeout=' "$ARGV")" -eq "$HOPS" ]] \
  && [[ "$(grep -cF -- '-o ControlMaster=auto' "$ARGV")" -eq "$HOPS" ]] \
  && [[ "$(grep -cF -- '-o ControlPath=' "$ARGV")" -eq "$HOPS" ]]
check "…with the same BatchMode/ConnectTimeout/ControlPath every other hop carries" $? \
  "$HOPS hops: $(cat "$ARGV" 2>/dev/null)"

# THE FETCH HOP IS FILTERED TOO, and it is the one hop where a notice line is not
# merely misparsed but FATAL: its stdout becomes the mirror, transcript-extract.sh
# slurps the whole mirror with `jq -s`, and one `# Tailscale SSH requires…` line
# makes that fail — which the waiter reports as a read error and exits 1 on. A
# delivered answer, reported as a failure, on any box whose tailnet is in check mode.
t=$(remote_env)
mkdir -p "$t/remote-home"
cd_path=$(mktemp -d "$HOTLINE_CALL_HOME/hotline-call-XXXXX")
echo herdr             > "$cd_path/transport.txt"
echo p3b-remote-agent  > "$cd_path/herdr_agent.txt"
echo "$RTARGET"        > "$cd_path/remote_target.txt"
echo "$t/target"       > "$cd_path/cwd.txt"
echo remote-sess-2     > "$cd_path/session_id.txt"
echo rmt-nonce-7       > "$cd_path/call_id.txt"
transcript_with \
  "$t/remote-home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/remote-sess-2.jsonl" \
  rmt-nonce-7 WORK_COMPLETE "answered through the check-mode notice"
out=$(wcheck "$t" "HERDR_STUB_AGENT_ANY=1" "HOTLINE_POLL_SLEEP=0" \
        "SSH_STUB_HOME=$t/remote-home" "SSH_STUB_TAILSCALE=1" \
        -- "$WAIT_RESPONSE" "$cd_path" --timeout 20); rc=$?
[[ $rc -eq 0 && "$(jq -r '.response' <<<"$out" 2>/dev/null)" == *"answered through the check-mode notice"* ]]
check "a Tailscale check-mode notice on the FETCH hop does not fail a delivered answer" $? \
  "rc=$rc out=$out stderr=$(cat "$t/err.txt")"
[[ -s "$cd_path/remote_transcript.jsonl" ]] \
  && ! grep -qv '^{' "$cd_path/remote_transcript.jsonl"
check "…because the mirror holds JSONL lines only, the notice stripped on the way in" $? \
  "mirror: $(head -3 "$cd_path/remote_transcript.jsonl" 2>/dev/null | cut -c1-60)"

# remote_target.txt is the ONLY thing that tells this separate process the agent
# lives elsewhere. Without it the LOCAL herdr is asked, answers "no such agent",
# and the waiter reports a working callee as dead — so its absence must not be
# silently survivable, and its presence must be what routes the probe.
t=$(remote_env)
mkdir -p "$t/remote-home"
cd_path=$(mktemp -d "$HOTLINE_CALL_HOME/hotline-call-XXXXX")
echo herdr            > "$cd_path/transport.txt"
echo p3b-gone-agent   > "$cd_path/herdr_agent.txt"
echo "$RTARGET"       > "$cd_path/remote_target.txt"
echo "$t/target"      > "$cd_path/cwd.txt"
echo remote-sess-3    > "$cd_path/session_id.txt"
echo rmt-nonce-4      > "$cd_path/call_id.txt"
# --timeout has to outlast the waiter's own file-absence grace (10s), or the budget
# expires first and the honest "no transcript anywhere" report never runs.
out=$(wcheck "$t" "HERDR_STUB_AGENT_ANY=1" "HOTLINE_POLL_SLEEP=0" \
        "SSH_STUB_HOME=$t/remote-home" \
        -- "$WAIT_RESPONSE" "$cd_path" --timeout 30 2>&1); rc=$?
ERRTXT=$(cat "$t/err.txt")
[[ $rc -ne 0 && "$ERRTXT" == *"No transcript"* ]] \
  && [[ "$ERRTXT" == *"$t/remote-home/.claude/projects/"* ]]
check "a missing remote transcript names the REMOTE candidate paths it looked at" $? \
  "rc=$rc err=$ERRTXT"
# The liveness probe went over the wire — which is the fact remote_target.txt
# exists to establish. (It cannot be checked by HERDR_LOG's absence: the ssh stub
# evals the remote command in this shell, so a remote `herdr` reaches the same stub
# and logs there too. The hop log is the only witness that distinguishes them.)
grep -q "herdr 'agent' 'get'" "$t/ssh.log"
check "…having asked the REMOTE herdr about the agent, over the hop" $? \
  "ssh hops: $(cat "$t/ssh.log" 2>/dev/null | tail -2)"

# A BOX THAT WENT AWAY IS ITS OWN ERROR. Half the transcript-path derivation is a
# question put to that box, so an unreachable one produced zero candidates — and the
# zero-candidate report is written for a missing input: it blamed the call dir while
# listing session_id, call_id and cwd as present. Two opposite fixes, one message.
t=$(remote_env)
cd_path=$(mktemp -d "$HOTLINE_CALL_HOME/hotline-call-XXXXX")
echo herdr            > "$cd_path/transport.txt"
echo p3b-gone-box     > "$cd_path/herdr_agent.txt"
echo "$RTARGET"       > "$cd_path/remote_target.txt"
echo "$t/target"      > "$cd_path/cwd.txt"
echo remote-sess-5    > "$cd_path/session_id.txt"
echo rmt-nonce-6      > "$cd_path/call_id.txt"
out=$(wcheck "$t" "HERDR_STUB_AGENT_ANY=1" "HOTLINE_POLL_SLEEP=0" "SSH_STUB_FAIL=1" \
        -- "$WAIT_RESPONSE" "$cd_path" --timeout 20 2>&1); rc=$?
ERRTXT=$(cat "$t/err.txt")
[[ $rc -ne 0 && "$ERRTXT" == *"has to be derived ON $RTARGET"* \
   && "$ERRTXT" == *"Could not resolve hostname"* ]]
check "an UNREACHABLE box during the transcript derivation is reported as the hop" $? \
  "rc=$rc err=$ERRTXT"
[[ "$ERRTXT" != *"Needed: session_id"* && "$ERRTXT" == *"The call dir is fine"* ]]
check "…and not as a missing call-dir input, which is the opposite fix" $? \
  "err=$ERRTXT"

# --- dial.sh: --remote picks the transport and the placement -----------------

remote_dial() {  # remote_dial <scratch> <extra-env...> -- <dial args...>
  local t="$1"; shift
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  env PATH="$t/bin:$PATH" HOME="$t/home" HERDR_LOG="$t/herdr.log" \
      HERDR_STATE="$t/state" CMUX_LOG="$t/cmux.log" SSH_LOG="$t/ssh.log" \
      HOTLINE_CALLER_SESSION_ID="caller-remote-1" \
      HOTLINE_PENDING_DIR="$t/pending" \
      ${envs[@]+"${envs[@]}"} bash "$DIAL" --label "probe label" "$@" 2>"$t/err.txt"
}

# --- The target is resolved on the REMOTE box ---------------------------------
# resolve-workspace.sh is local by construction — `realpath`, the local session
# cache, the local dirmap — so running it against another box's path either refuses
# a good dial ("Path does not exist") or, worse, resolves a same-named LOCAL
# directory and dials a callee into the wrong tree. A remote dial asks that box.

t=$(remote_env)
out=$(remote_dial "$t" -- --target "dotfiles" --mode work_order --prompt "hi" \
        --remote "$RTARGET")
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" \
   && "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "resolve" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"needs an absolute path on $RTARGET"* ]]
check "a fuzzy --remote target is refused: dirmap and fuzzy matching are local knowledge" $? \
  "out=$out"

t=$(remote_env)
out=$(remote_dial "$t" -- --target "/nope/p3b-not-there" --mode work_order --prompt "hi" \
        --remote "$RTARGET")
[[ "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "resolve" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"is not a directory on $RTARGET"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"ssh $RTARGET ls -d"* ]]
check "…and a missing one names the BOX it was looked for on, not this machine" $? \
  "out=$out"
grep -q 'realpath' "$t/ssh.log"
check "…having asked over the hop, so resolution never consulted the local tree" $? \
  "ssh hops: $(cat "$t/ssh.log" 2>/dev/null)"

# TWO FAILURES, ONE EXIT STATUS, OPPOSITE FIXES. A path that is not there and a box
# that is not reachable both come back from the same hop, and leading with "not a
# directory" for an unreachable box sends the reader to check a path that is fine.
t=$(remote_env)
out=$(remote_dial "$t" "SSH_STUB_FAIL=1" -- --target "/some/where" --mode work_order \
        --prompt "hi" --remote "$RTARGET")
[[ "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "transport" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"could not be reached over ssh"* ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" != *"not a directory"* ]]
check "an UNREACHABLE box during resolve is reported as the hop, not as a bad path" $? \
  "out=$out"

# --refresh-identity would run a headless claude HERE against a path that is not
# here. Refused up front rather than attempted and degraded: it is an explicit ask
# for an expensive action that cannot work.
t=$(remote_env)
out=$(remote_dial "$t" -- --target "$t/target" --mode work_order --prompt "hi" \
        --remote "$RTARGET" --refresh-identity)
[[ "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "args" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"--refresh-identity cannot run against a --remote target"* ]]
check "--refresh-identity with --remote is refused, not attempted locally" $? "out=$out"

# A remote dial, end to end. The stub wrapper supplies the transcript, as the
# local end-to-end case above does — under the REMOTE $HOME, so the delivery
# confirmation has to have asked that box where its projects live.
t=$(remote_env)
mkdir -p "$t/remote-home"
cat > "$t/bin/herdr" <<STUBW
#!/usr/bin/env bash
if [[ "\$1 \${2:-}" == "agent prompt" ]]; then
  SID=\$(cat "\$HERDR_STATE/session_id" 2>/dev/null || echo unknown)
  export HERDR_STUB_TRANSCRIPT="$t/remote-home/.claude/projects/$(encode_cwd "$(cd "$t/target" && pwd -P)")/\$SID.jsonl"
fi
exec bash "$t/bin/herdr-real" "\$@"
STUBW
chmod +x "$t/bin/herdr"
mkdir -p "$t/binsrc"; make_herdr_stub "$t/binsrc"; mv "$t/binsrc/herdr" "$t/bin/herdr-real"
out=$(remote_dial "$t" "HERDR_STUB_NEW_PANE=w4:p9" "SSH_STUB_HOME=$t/remote-home" \
        -- --target "$t/target" --mode work_order --prompt "run it over there" \
           --remote "$RTARGET" --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r '.transport' <<<"$out" 2>/dev/null)" == "herdr" \
   && "$(jq -r '.placement' <<<"$out" 2>/dev/null)" == "detached" ]]
check "--remote alone selects herdr and defaults placement to detached" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.remote_target' <<<"$out" 2>/dev/null)" == "$RTARGET" \
   && "$(jq -r '.remote_pane' <<<"$out" 2>/dev/null)" == "w4:p9" ]]
check "…and the emitted JSON carries .remote_target and .remote_pane for the teardown" $? \
  "out=$out"
[[ "$(jq -r '.surface_ref' <<<"$out" 2>/dev/null)" == hotline-* \
   && -n "$(jq -r '.remote_session_id // empty' <<<"$out" 2>/dev/null)" \
   && -n "$(jq -r '.call_id // empty' <<<"$out" 2>/dev/null)" ]]
check "…with the contract's own keys unchanged in shape (host ref, session, nonce)" $? "out=$out"
# A REMOTE callee's slug carries the BOX as well as the directory: two machines hold
# the same directory names, and the agent name is the only handle either callee has.
# "tester@no-such-box.invalid" + "target" → DIRECTORY FIRST, then the host with the
# login user dropped and the domain trimmed, 8 + 1 + 5 inside herdr's 14.
[[ "$(jq -r '.surface_ref' <<<"$out" 2>/dev/null)" == "hotline-target-no-su-"* ]]
check "…and a remote agent's slug names the DIRECTORY plus the host, minus the login user" $? \
  "surface_ref=$(jq -r '.surface_ref' <<<"$out" 2>/dev/null) (expected hotline-target-no-su-*)"
[[ ! -s "$t/cmux.log" ]]
check "…and no cmux call: a remote dial never consults the local multiplexer" $? \
  "cmux calls: $(cat "$t/cmux.log" 2>/dev/null)"
# The call dir has to carry the target too. wait-for-response.sh runs as a separate
# process handed nothing else, and without this it asks the LOCAL herdr about a
# remote agent, is told "no such agent", and reports a working callee as dead.
CALLDIR=$(jq -r '.call_dir' <<<"$out" 2>/dev/null)
[[ "$(cat "$CALLDIR/remote_target.txt" 2>/dev/null)" == "$RTARGET" ]]
check "…and the call dir records the target, for the separate waiter process" $? \
  "call dir: $(ls "$CALLDIR" 2>/dev/null | tr '\n' ' ')"
CACHED=$(jq -r --arg t "$(cd "$t/target" && pwd -P)" '.connections[$t]' \
           "$t/home/.agents-hotline/sessions/caller-remote-1.json" 2>/dev/null)
[[ "$(jq -r '.transport' <<<"$CACHED" 2>/dev/null)" == "herdr" \
   && "$(jq -r '.remote' <<<"$CACHED" 2>/dev/null)" == "$RTARGET" ]]
check "…and the cache records WHICH backend and WHICH box the host handle belongs to" $? \
  "cached=$CACHED"

# A LONG HOST MUST NOT EAT THE DIRECTORY. Joined as `<host>-<dir>` under one 14-char
# cut, every host of 13 characters or more — which a tailnet FQDN always is — left a
# host-only name: jt@jt-mbp14.taile1234.ts.net + lindris-frontend minted
# hotline-jt-mbp14-taile-*, and the directory the slug exists to name was gone.
t=$(remote_env)
mkdir -p "$t/lindris-frontend" "$t/remote-home"
LONG_RTARGET="jt@jt-mbp14.taile1234.ts.net"
cat > "$t/bin/herdr" <<STUBW
#!/usr/bin/env bash
if [[ "\$1 \${2:-}" == "agent prompt" ]]; then
  SID=\$(cat "\$HERDR_STATE/session_id" 2>/dev/null || echo unknown)
  export HERDR_STUB_TRANSCRIPT="$t/remote-home/.claude/projects/$(encode_cwd "$(cd "$t/lindris-frontend" && pwd -P)")/\$SID.jsonl"
fi
exec bash "$t/bin/herdr-real" "\$@"
STUBW
chmod +x "$t/bin/herdr"
mkdir -p "$t/binsrc"; make_herdr_stub "$t/binsrc"; mv "$t/binsrc/herdr" "$t/bin/herdr-real"
out=$(remote_dial "$t" "HERDR_STUB_NEW_PANE=w4:p9" "SSH_STUB_HOME=$t/remote-home" \
        -- --target "$t/lindris-frontend" --mode work_order --prompt "run it over there" \
           --remote "$LONG_RTARGET" --boot-timeout 5)
LONG_REF=$(jq -r '.surface_ref' <<<"$out" 2>/dev/null)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" && "$LONG_REF" == *"lindris"* ]]
check "a 28-char remote host still leaves the DIRECTORY in the agent name" $? \
  "surface_ref=$LONG_REF stderr=$(cat "$t/err.txt")"
[[ "$LONG_REF" == "hotline-lindris-jt-mb-"* ]]
check "…with the host beside it, short-hostname only (8 for the dir, 5 for the box)" $? \
  "surface_ref=$LONG_REF (expected hotline-lindris-jt-mb-*)"
# herdr's own constraint: [a-z][a-z0-9_-]{0,31}. The per-half budget must not have
# bought legibility by overrunning it.
[[ ${#LONG_REF} -le 32 && "$LONG_REF" =~ ^[a-z][a-z0-9_-]*$ ]]
check "…and still inside herdr's 32-char name shape" $? "surface_ref=$LONG_REF len=${#LONG_REF}"

# A LOCAL dial's emitted contract is untouched: neither new key appears, so a
# consumer cannot tell a Phase-3b hotline from the one before it.
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
out=$(remote_dial "$t" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode work_order --prompt "run it here" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" ]] \
  && [[ "$(jq -r 'has("remote_target")' <<<"$out" 2>/dev/null)" == "false" \
     && "$(jq -r 'has("remote_pane")' <<<"$out" 2>/dev/null)" == "false" ]]
check "a LOCAL herdr dial emits neither remote key — the contract is additive only" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ ! -e "$t/ssh.log" ]]
check "…and makes no ssh hop at all" $? "ssh hops: $(cat "$t/ssh.log" 2>/dev/null)"

# AN AMBIENT HOTLINE_HERDR_REMOTE DOES NOT HALF-ROUTE A LOCAL DIAL. Nine scripts
# read that variable, so a value left in the environment by a previous remote dial
# (or exported as a default) would send preflight, the launch and the delivery over
# ssh while the target resolved HERE, the JSON carried no remote_target, and the
# cache entry said local — a state no flag asked for and nothing reports. dial.sh
# is the seam's sole authority, so the local path unsets it.
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
out=$(remote_dial "$t" "HERDR_PANE_ID=w1:p1" "HOTLINE_HERDR_REMOTE=$RTARGET" \
        -- --target "$t/target" --mode work_order --prompt "run it here" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" \
   && "$(jq -r 'has("remote_target")' <<<"$out" 2>/dev/null)" == "false" ]]
check "a local dial with an ambient HOTLINE_HERDR_REMOTE still connects locally" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ ! -e "$t/ssh.log" ]]
check "…making no ssh hop: dial.sh decides the seam in BOTH directions" $? \
  "ssh hops: $(cat "$t/ssh.log" 2>/dev/null)"

# --- The cache cannot confuse two hosts (claude-plugins-7wze.11) -------------
# surface_ref is an opaque string, so a herdr agent name on another box looks
# exactly like a local one. Re-addressing the wrong one is told "no such agent",
# falls back to a fresh callee and re-keys the cache to it — stranding the real
# conversation on the other box with nothing pointing at it.
#
# WHICH IS WHY A BOX MISMATCH IS A REFUSAL, not a fallback. Declining the reuse and
# starting a fresh callee here leaves the remote one running, and the cache write
# REPLACES the entry that named it — so the fallback's own advice ("re-dial with the
# same --remote to continue") could not be taken: the second dial mismatches too and
# starts a third callee. The refusal is the only outcome that keeps the remote
# conversation reachable, and --fresh is how a caller says to abandon it anyway.

# One scratch env whose cache already holds a callee on a named host. Only the host
# claim varies between the cases below; the herdr stub is the transcript-aware
# wrapper every dial case in this file uses.
mismatch_env() {  # mismatch_env <transport> <remote|''> <agent> <call-id>
  local t tgt
  t=$(remote_env)
  mkdir -p "$t/home/.agents-hotline/sessions"
  tgt=$(cd "$t/target" && pwd -P)
  jq -n --arg t "$tgt" --arg tr "$1" --arg rm "$2" --arg ag "$3" --arg cid "$4" \
    '{caller:"/caller", caller_session_id:"caller-remote-1",
      connections: {($t): ({session_id:"prev-sess-9", started:1, last_contact:1,
        mode:"work_order", exchange_count:1, surface_ref:$ag, last_call_id:$cid,
        transport:$tr} + (if $rm == "" then {} else {remote:$rm} end))}}' \
    > "$t/home/.agents-hotline/sessions/caller-remote-1.json"
  cat > "$t/bin/herdr" <<STUBW
#!/usr/bin/env bash
if [[ "\$1 \${2:-}" == "agent prompt" ]]; then
  SID=\$(cat "\$HERDR_STATE/session_id" 2>/dev/null || echo unknown)
  export HERDR_STUB_TRANSCRIPT="$t/home/.claude/projects/$(encode_cwd "$tgt")/\$SID.jsonl"
fi
exec bash "$t/bin/herdr-real" "\$@"
STUBW
  chmod +x "$t/bin/herdr"
  mkdir -p "$t/binsrc"; make_herdr_stub "$t/binsrc"; mv "$t/binsrc/herdr" "$t/bin/herdr-real"
  printf '%s' "$t"
}

OTHERBOX="tester@other-box.invalid"

# remote → local. The callee is on another box and this dial names none.
t=$(mismatch_env herdr "$OTHERBOX" hotline-elsewhere-abc mm-nonce-1)
# The pane that closes that callee lives in the CALL DIR, not the cache, so the
# recovery can only name it if it looks there — matched on the cached AGENT NAME and
# the cached box, both of which the launch dir records alongside the pane.
PANEDIR=$(mktemp -d "$HOTLINE_CALL_HOME/hotline-call-XXXXX")
echo mm-nonce-1          > "$PANEDIR/call_id.txt"
echo hotline-elsewhere-abc > "$PANEDIR/herdr_agent.txt"
echo "$OTHERBOX"         > "$PANEDIR/remote_target.txt"
echo w4:p7               > "$PANEDIR/herdr_pane.txt"
out=$(remote_dial "$t" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode work_order --prompt "follow up" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "error" \
   && "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "transport" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"herdr agent hotline-elsewhere-abc on $OTHERBOX"* ]]
check "a cached callee on ANOTHER BOX is REFUSED, not quietly replaced" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"--remote $OTHERBOX"* \
   && "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"--fresh"* ]]
check "…offering exactly two moves: --remote <that box> to continue, --fresh to abandon" $? \
  "recovery=$(jq -r '.recovery' <<<"$out" 2>/dev/null)"
[[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"ssh $OTHERBOX herdr pane close w4:p7"* ]]
check "…and the pane that closes the abandoned one, read out of its call dir" $? \
  "recovery=$(jq -r '.recovery' <<<"$out" 2>/dev/null)"

# AFTER A FOLLOW-UP, the pane is still named. Every follow-up re-keys the cache's
# last_call_id to its own reuse call dir, which records the agent and the box and no
# pane — so a lookup keyed on the nonce found nothing from the second exchange
# onward, and the hint silently degraded to `agent list` for exactly the caller who
# had been talking to that callee longest (claude-plugins-cedc).
t=$(mismatch_env herdr "$OTHERBOX" hotline-elsewhere-fu mm-nonce-fu2)
LAUNCHDIR=$(mktemp -d "$HOTLINE_CALL_HOME/hotline-call-XXXXX")
echo mm-nonce-fu1          > "$LAUNCHDIR/call_id.txt"
echo hotline-elsewhere-fu  > "$LAUNCHDIR/herdr_agent.txt"
echo "$OTHERBOX"           > "$LAUNCHDIR/remote_target.txt"
echo w6:p3                 > "$LAUNCHDIR/herdr_pane.txt"
REUSEDIR=$(mktemp -d "$HOTLINE_CALL_HOME/hotline-call-XXXXX")
echo mm-nonce-fu2          > "$REUSEDIR/call_id.txt"
echo hotline-elsewhere-fu  > "$REUSEDIR/herdr_agent.txt"
echo "$OTHERBOX"           > "$REUSEDIR/remote_target.txt"
out=$(remote_dial "$t" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode work_order --prompt "follow up again" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"ssh $OTHERBOX herdr pane close w6:p3"* ]]
check "…and a FOLLOW-UP's mismatch still names the pane, from the launch dir" $? \
  "recovery=$(jq -r '.recovery' <<<"$out" 2>/dev/null)"

# A SAME-NAMED AGENT ON ANOTHER BOX IS NOT THAT PANE. herdr names are unique per
# server, not across servers, so closing the pane a different box happens to have
# under the same name kills an unrelated callee.
t=$(mismatch_env herdr "$OTHERBOX" hotline-twoboxes mm-nonce-tb)
WRONGBOX=$(mktemp -d "$HOTLINE_CALL_HOME/hotline-call-XXXXX")
echo mm-nonce-tb      > "$WRONGBOX/call_id.txt"
echo hotline-twoboxes > "$WRONGBOX/herdr_agent.txt"
echo "$RTARGET"       > "$WRONGBOX/remote_target.txt"
echo w9:p9            > "$WRONGBOX/herdr_pane.txt"
out=$(remote_dial "$t" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode work_order --prompt "follow up" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" != *"w9:p9"* \
   && "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"herdr agent list"* ]]
check "…and a same-named agent on a DIFFERENT box is not offered as that pane" $? \
  "recovery=$(jq -r '.recovery' <<<"$out" 2>/dev/null)"
! grep -q 'agent start' "$t/herdr.log" 2>/dev/null
check "…having started NO second callee: nothing to strand and nothing to close" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"
[[ "$(jq -r --arg t "$(cd "$t/target" && pwd -P)" '.connections[$t].session_id' \
       "$t/home/.agents-hotline/sessions/caller-remote-1.json" 2>/dev/null)" == "prev-sess-9" ]]
check "…and the cache still points at the remote callee, so the offered re-dial works" $? \
  "cache=$(cat "$t/home/.agents-hotline/sessions/caller-remote-1.json" 2>/dev/null)"
! grep -q 'hotline-elsewhere-abc' <(tr -d '\\' < "$t/herdr.log")
check "…and that foreign agent name is never handed to the local herdr" $? \
  "herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

# --fresh is the caller saying "abandon it". The dial proceeds — and the entry names
# the agent and the box, because that string is the only record they get of a
# process no local cleanup will ever reach.
#
# ITS OWN AGENT NAME, deliberately: the pane lookup is keyed on that name, so reusing
# the one above would find the call dir staged there and this case is the one where
# NO dir remembers a pane.
t=$(mismatch_env herdr "$OTHERBOX" hotline-nopane-abc mm-nonce-2)
out=$(remote_dial "$t" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode work_order --prompt "follow up" \
           --transport herdr --detached --fresh --boot-timeout 5)
[[ "$(jq -r '.status' <<<"$out" 2>/dev/null)" == "connected" ]] \
  && [[ "$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)" \
        == *"abandoned-callee(herdr agent hotline-nopane-abc on $OTHERBOX"* ]]
check "…while --fresh proceeds, naming the abandoned agent AND its box" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)" == *"ssh $OTHERBOX herdr agent list"* ]]
check "…and how to find it, when no call dir still remembers its pane" $? \
  "fallbacks=$(jq -r '.fallbacks | join(\" \")' <<<"$out" 2>/dev/null)"

# local → remote, the same rule mirrored: the callee is HERE and the dial names a
# box, so the move that continues it is dropping --remote.
t=$(mismatch_env herdr "" hotline-right-here-abc mm-nonce-3)
out=$(remote_dial "$t" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode work_order --prompt "follow up" \
           --remote "$RTARGET" --boot-timeout 5)
[[ "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "transport" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"herdr agent hotline-right-here-abc on this box"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"no --remote"* ]]
check "the mirror image is refused too: a LOCAL callee and a --remote dial" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"herdr agent list"* \
   && "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" != *"ssh "* ]]
check "…and its close command carries no ssh: that pane is in this machine's herdr" $? \
  "recovery=$(jq -r '.recovery' <<<"$out" 2>/dev/null)"

# box A → box B. Neither is local, and the refusal names the box that HAS the
# conversation rather than the one this dial asked for.
t=$(mismatch_env herdr "$OTHERBOX" hotline-on-a-abc mm-nonce-4)
out=$(remote_dial "$t" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode work_order --prompt "follow up" \
           --remote "$RTARGET" --boot-timeout 5)
[[ "$(jq -r '.stage' <<<"$out" 2>/dev/null)" == "transport" ]] \
  && [[ "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"on $OTHERBOX"* \
     && "$(jq -r '.detail' <<<"$out" 2>/dev/null)" == *"names $RTARGET"* ]] \
  && [[ "$(jq -r '.recovery' <<<"$out" 2>/dev/null)" == *"--remote $OTHERBOX"* ]]
check "box A → box B is the same refusal, naming the box that HAS the conversation" $? \
  "out=$out stderr=$(cat "$t/err.txt")"
[[ ! -e "$t/ssh.log" ]] || ! grep -q 'agent start' "$t/ssh.log"
check "…and no callee is started on either box" $? \
  "ssh hops: $(cat "$t/ssh.log" 2>/dev/null)"

# The transport half of the same rule: a cmux surface handle is not a herdr agent.
t=$(new_env)
mkdir -p "$t/home/.agents-hotline/sessions"
TGT_REAL=$(cd "$t/target" && pwd -P)
jq -n --arg t "$TGT_REAL" \
  '{caller:"/caller", caller_session_id:"caller-remote-1",
    connections: {($t): {session_id:"cmux-sess-9", started:1, last_contact:1,
      mode:"work_order", exchange_count:1, surface_ref:"surface-uuid-1234",
      transport:"cmux"}}}' \
  > "$t/home/.agents-hotline/sessions/caller-remote-1.json"
cat > "$t/bin/herdr" <<STUBW
#!/usr/bin/env bash
if [[ "\$1 \${2:-}" == "agent prompt" ]]; then
  SID=\$(cat "\$HERDR_STATE/session_id" 2>/dev/null || echo unknown)
  export HERDR_STUB_TRANSCRIPT="$t/home/.claude/projects/$(encode_cwd "$TGT_REAL")/\$SID.jsonl"
fi
exec bash "$t/bin/herdr-real" "\$@"
STUBW
chmod +x "$t/bin/herdr"
mkdir -p "$t/binsrc"; make_herdr_stub "$t/binsrc"; mv "$t/binsrc/herdr" "$t/bin/herdr-real"
out=$(remote_dial "$t" "HERDR_PANE_ID=w1:p1" \
        -- --target "$t/target" --mode work_order --prompt "follow up" \
           --transport herdr --detached --boot-timeout 5)
[[ "$(jq -r '.fallbacks | join(" ")' <<<"$out" 2>/dev/null)" == *"transport cmux→herdr"* ]]
check "a cached CMUX surface handle is not re-addressed as a herdr agent either" $? \
  "out=$out stderr=$(cat "$t/err.txt")"

# --- HOTLINE_CALLEE_ENV over the hop ------------------------------------------
# The env block is JSON — quotes, braces, colons — riding a command line that is
# shell-quoted for ssh and re-parsed on the far side. The far herdr must get it
# byte-for-byte, which the stub's %q log lets us read back.
t=$(remote_env)
out=$(rcheck "$t" HERDR_PANE_ID="w1:p1" HOTLINE_CALLEE_ENV="AGENTIC_DEV_ROLE=builder AGENTIC_DEV_RUN=42" \
      -- "$HERDR_ASYNC" --cwd "$t/target" --prompt "hi")
line=$(grep 'agent start' "$t/herdr.log" 2>/dev/null | tail -1)
settings=""; prev=""
eval "argv=($line)"
for a in ${argv[@]+"${argv[@]}"}; do [[ "$prev" == "--settings" ]] && settings="$a"; prev="$a"; done
jq -e '.env == {AGENTIC_DEV_ROLE:"builder", AGENTIC_DEV_RUN:"42"}' <<<"$settings" >/dev/null 2>&1
check "HOTLINE_CALLEE_ENV crosses the ssh hop intact as the remote \`agent start\`'s --settings" $? \
  "out=$out settings=$settings herdr calls: $(cat "$t/herdr.log" 2>/dev/null)"

herdr_suite_finish
