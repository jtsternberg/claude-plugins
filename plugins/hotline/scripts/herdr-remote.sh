#!/usr/bin/env bash
# =============================================================================
# herdr remote: the ssh hop that lets a herdr callee live on ANOTHER box, and the
# remote-transcript reader that makes its answer readable from here.
#
# SOURCE this, don't execute it. herdr-state.sh sources it unconditionally and
# routes every `herdr` call through it when a remote target is set, so no other
# script needs to know an ssh hop exists.
#
# WHY SSH AND NOT `herdr --remote`. herdr's own `--remote` attaches the
# interactive TUI to a remote server and NOTHING else: `herdr --remote <host>
# agent list` is rejected outright ("--remote can only be used with the default
# launch command"). So a remote callee is not driven through a remote-aware herdr
# client; it is driven by running the ORDINARY herdr CLI on the remote box,
# against that box's own local server, over ssh. Every verb the local herdr arm
# uses — `pane split`, `agent start`, `agent prompt`, `agent get`, `agent read`,
# `agent wait` — is unchanged; only the transport of the command changes.
#
# THE PAYLOAD NEVER RIDES AN SSH COMMAND LINE. `herdr agent prompt <name> <text>`
# takes its text positionally, and putting a work order into the argv of the LOCAL
# ssh process would publish it to any local `ps` — the exposure cmux was reworked
# to eliminate (claude-plugins-86ka), which §9.1 O8 accepted for herdr only
# because it lasts one sub-second REMOTE process. So a payload-carrying call runs
# a FIXED remote command that reads stdin — `herdr agent prompt <name> "$(cat)"`
# with the file on ssh's stdin — and the bytes travel down the ssh channel
# instead. Verified live against jt-mbp15-linux: the md5 of the payload after the
# round trip equals the local md5 of `$(cat file)`, i.e. byte-identical including
# embedded quotes, backticks, `$VAR` and globs, with trailing newlines stripped
# exactly as the local path's own `$(cat)` strips them.
#
# EVERY HOP IS TIME-BOXED AND NON-INTERACTIVE. `BatchMode=yes` so a hop can never
# sit on a password prompt, and `timeout` around every ssh so it can never sit on
# anything else. That second belt is not paranoia: the target runs TAILSCALE SSH,
# which can be in CHECK MODE — it prints
#   # Tailscale SSH requires an additional check. To authenticate, visit https://…
# before the real output, and when the check period lapses a BatchMode hop BLOCKS
# on an authentication it cannot complete. Unbounded, that is a 30-minute silence
# in the middle of a work order. Bounded, it is an error that names the URL, which
# is the one thing a human can act on. Both halves are handled here: the notice
# lines are FILTERED OUT of every hop's output (nothing downstream may ever parse
# them as data), and their URL is remembered so a timeout can name it.
#
# ONE AUTHENTICATION PER CALL. `ControlMaster=auto` + `ControlPersist` share a
# single connection across the dozen hops one dial makes, so the tailnet check (and
# any key handshake) happens once. The socket lives in a private 0700 directory
# because a ControlPath is a filesystem rendezvous point; it is created SHORT
# because the path is a unix socket address and the kernel caps those at 104 bytes
# — a socket under a long call dir fails EVERY hop with "ControlPath too long",
# which is why this does not simply put it next to the other call-dir state.
#
# THE REMOTE TRANSCRIPT. The callee writes to the REMOTE
# ~/.claude/projects/<encoded realpath>/<session>.jsonl, so both halves of that
# path have to be asked of the remote box rather than assumed: the local $HOME is
# not the remote $HOME, and the encoding is of the path the remote claude
# RESOLVED. Resolved once per process and cached — one ssh hop, not one per poll.
# The reader then FETCHES that file into a local temp and hands the local copy to
# an UNCHANGED transcript-extract.sh, which is the whole reason the answer half of
# hotline needed no remote fork (§8).
# =============================================================================

# --- Where the ssh hop goes, and how ----------------------------------------
# HOTLINE_HERDR_REMOTE is the seam: set it and every herdr call in this process
# goes to that box. Read through a function rather than copied into a global at
# source time, because dial.sh exports it AFTER sourcing in some paths.
hotline_remote_target() { printf '%s' "${HOTLINE_HERDR_REMOTE:-}"; }
hotline_remote_active() { [[ -n "${HOTLINE_HERDR_REMOTE:-}" ]]; }

# Per-hop budget, seconds. Generous by default because a hop is a whole herdr verb
# and some of them (`agent start`) legitimately block; herdr_cli raises it further
# from the herdr `--timeout` it is passing through.
HOTLINE_REMOTE_SSH_TIMEOUT="${HOTLINE_REMOTE_SSH_TIMEOUT:-60}"
# How long the shared connection outlives the last hop. Long enough to cover a
# dial's gap between delivery and the first response poll, short enough that a
# finished call does not leave an authenticated channel open indefinitely.
HOTLINE_REMOTE_SSH_PERSIST="${HOTLINE_REMOTE_SSH_PERSIST:-300}"
HOTLINE_REMOTE_SSH_CONNECT_TIMEOUT="${HOTLINE_REMOTE_SSH_CONNECT_TIMEOUT:-10}"

# The multiplexing socket, or "" when multiplexing had to be given up. Lazily
# created so a process that never makes a remote call creates nothing.
HOTLINE_REMOTE_CONTROL_PATH=""
HOTLINE_REMOTE_CONTROL_DIR=""
HOTLINE_REMOTE_MUX_NOTE=""

# The kernel's sockaddr_un limit. A ControlPath at or past it makes ssh refuse the
# connection outright (rc 255, "ControlPath too long"), so the length is checked
# HERE and multiplexing is dropped rather than allowed to fail every hop. Left a
# little slack: ssh appends nothing, but a caller-supplied dir might.
HOTLINE_REMOTE_CONTROL_PATH_MAX=100

# DETERMINISTIC, PER TARGET, SHARED BETWEEN PROCESSES — not per process. One dial
# is several processes (dial.sh, then wait-for-response.sh, then any follow-up), and
# a socket named after whichever one created it would make each of them authenticate
# again. That is the cost this exists to avoid, and on a tailnet in check mode each
# of those re-authentications is a chance to stall. A per-process path would also
# litter one directory per invocation.
#
# The name is the target, sanitized, plus its checksum. The checksum is not
# decoration: the sanitized part is TRUNCATED to stay under the socket-address cap,
# and two targets sharing a prefix would otherwise share a master connection —
# silently sending one box's herdr commands to another.
hotline_remote_mux_init() {
  [[ -n "$HOTLINE_REMOTE_CONTROL_PATH" || -n "$HOTLINE_REMOTE_MUX_NOTE" ]] && return 0
  local base target slug sum dir
  # /tmp explicitly, NOT $TMPDIR: macOS sets TMPDIR to a ~50-character
  # /var/folders/… path, which alone can push the socket past the 104-byte cap.
  base="${HOTLINE_SSH_CONTROL_HOME:-/tmp}"
  target=$(hotline_remote_target)
  slug=$(printf '%s' "$target" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-24)
  sum=$(printf '%s' "$target" | cksum 2>/dev/null | awk '{print $1}')
  [[ -z "$sum" ]] && sum=0
  dir="$base/hotline-ssh-$slug-$sum"
  if [[ ${#dir} -ge $((HOTLINE_REMOTE_CONTROL_PATH_MAX - 2)) ]]; then
    HOTLINE_REMOTE_MUX_NOTE="control path under $base would exceed the ${HOTLINE_REMOTE_CONTROL_PATH_MAX}-byte unix-socket limit"
    return 0
  fi
  # 0700 at creation, not after: a world-readable window, however brief, is a
  # window in which somebody else can plant the socket path. A pre-existing
  # directory owned by anyone else fails the ownership test below rather than being
  # adopted.
  if [[ ! -d "$dir" ]]; then
    mkdir -m 700 "$dir" 2>/dev/null || {
      HOTLINE_REMOTE_MUX_NOTE="could not create the control directory $dir"
      return 0
    }
  fi
  if [[ ! -O "$dir" ]]; then
    HOTLINE_REMOTE_MUX_NOTE="$dir exists but is not owned by this user, so it will not be used as a control path"
    return 0
  fi
  HOTLINE_REMOTE_CONTROL_DIR="$dir"
  # A one-character name: every byte counts against the socket-address cap.
  HOTLINE_REMOTE_CONTROL_PATH="$dir/s"
  return 0
}

# Tear the shared connection down. Safe to call when none was ever opened.
#
# DELIBERATELY NOT WIRED INTO ANY EXIT PATH. The connection is shared across a
# dial's processes and outliving one of them is the point — closing it when dial.sh
# returns would make the response wait that follows re-authenticate. ControlPersist
# retires it on its own. This exists for an explicit teardown (a test suite, or a
# caller that knows it is done with that box), and it leaves the directory in place
# because the path is deterministic and meant to be reused.
hotline_remote_mux_close() {
  [[ -z "$HOTLINE_REMOTE_CONTROL_PATH" ]] && return 0
  local target
  target=$(hotline_remote_target)
  if [[ -n "$target" && -S "$HOTLINE_REMOTE_CONTROL_PATH" ]]; then
    ssh -o ControlPath="$HOTLINE_REMOTE_CONTROL_PATH" -O exit "$target" >/dev/null 2>&1 || true
  fi
  rm -f "$HOTLINE_REMOTE_CONTROL_PATH" 2>/dev/null || true
  HOTLINE_REMOTE_CONTROL_PATH=""
  HOTLINE_REMOTE_CONTROL_DIR=""
}

# --- Quoting a command for the remote shell ---------------------------------
# ssh joins its command arguments with spaces and hands the result to the remote
# user's shell, so the SHELL is what parses them — argv boundaries do not survive
# the hop. Single-quoting is the only form that survives every shell the remote
# might run: nothing inside '' is special, and an embedded ' is closed, escaped and
# reopened. `printf %q` is deliberately NOT used — it is bash's own dialect and can
# emit `$'…'`, which a POSIX /bin/sh reads as a literal dollar sign.
hotline_remote_shquote() {  # <arg>... → one shell-safe command string
  local out="" a
  for a in "$@"; do
    out+="'${a//\'/\'\\\'\'}' "
  done
  printf '%s' "${out% }"
}

# --- One hop ----------------------------------------------------------------
# HOTLINE_REMOTE_OUT ← the remote command's stdout, tailnet notices filtered out.
# HOTLINE_REMOTE_ERR ← a one-line diagnostic, "" on success.
# HOTLINE_REMOTE_RC  ← ssh's exit status (which is the REMOTE command's status,
#                      except 255 for an ssh-level failure and 124 for our timeout).
#
# hotline_remote_run <remote-command-string> [<stdin-file>]
#   0 — the remote command exited 0
#   1 — it did not, or the hop itself failed; HOTLINE_REMOTE_ERR says which
#
# `-n` when there is no stdin file, and that is load-bearing: without it ssh reads
# the calling script's stdin, so one hop inside a `while read` loop swallows the
# rest of the loop's input.
HOTLINE_REMOTE_OUT=""
HOTLINE_REMOTE_ERR=""
HOTLINE_REMOTE_RC=0
# The remote command's own stderr, filtered, verbatim. Kept separate from
# HOTLINE_REMOTE_ERR (which is this layer's prose about the hop) because a caller
# has to be able to parse it: herdr writes a server error there as JSON, and
# reading it out of a sentence would be reading a diagnostic as data. Live-checked
# on herdr 0.8.2 — `ssh … herdr agent get <missing>` puts
# `{"error":{"code":"agent_not_found"…}}` on STDERR with exit 1, where the local
# CLI puts the same object on stdout with exit 0.
HOTLINE_REMOTE_STDERR=""
# The authentication URL a tailnet check printed, if one ever did. Remembered
# across hops because the hop that STALLS is not the one that printed it.
HOTLINE_REMOTE_AUTH_URL=""
hotline_remote_run() {
  local cmd="$1" stdin_file="${2:-}" target budget rc
  HOTLINE_REMOTE_OUT=""
  HOTLINE_REMOTE_ERR=""
  HOTLINE_REMOTE_STDERR=""
  HOTLINE_REMOTE_RC=0
  target=$(hotline_remote_target)
  if [[ -z "$target" ]]; then
    HOTLINE_REMOTE_ERR="no remote target set (HOTLINE_HERDR_REMOTE is empty)"
    return 1
  fi
  hotline_remote_mux_init
  budget="${HOTLINE_REMOTE_HOP_BUDGET:-$HOTLINE_REMOTE_SSH_TIMEOUT}"

  local -a opts=(
    -o BatchMode=yes
    -o "ConnectTimeout=$HOTLINE_REMOTE_SSH_CONNECT_TIMEOUT"
    -o StrictHostKeyChecking=accept-new
  )
  if [[ -n "$HOTLINE_REMOTE_CONTROL_PATH" ]]; then
    opts+=(-o ControlMaster=auto
           -o "ControlPersist=$HOTLINE_REMOTE_SSH_PERSIST"
           -o "ControlPath=$HOTLINE_REMOTE_CONTROL_PATH")
  fi

  local out_file err_file
  out_file=$(mktemp); err_file=$(mktemp)
  if [[ -n "$stdin_file" ]]; then
    timeout "$budget" ssh "${opts[@]}" "$target" "$cmd" \
      <"$stdin_file" >"$out_file" 2>"$err_file"
    rc=$?
  else
    timeout "$budget" ssh -n "${opts[@]}" "$target" "$cmd" \
      >"$out_file" 2>"$err_file"
    rc=$?
  fi
  HOTLINE_REMOTE_RC=$rc

  # The tailnet notice is stripped from BOTH streams before anything reads them.
  # Which stream it lands on is a Tailscale implementation detail, and a caller
  # that jq'd it as data would report a parse error instead of the real problem.
  local url
  url=$(grep -ho 'https://login\.tailscale\.com/[^[:space:]]*' "$out_file" "$err_file" 2>/dev/null | head -1 || true)
  [[ -n "$url" ]] && HOTLINE_REMOTE_AUTH_URL="$url"
  HOTLINE_REMOTE_OUT=$(grep -v -e '^# Tailscale SSH requires an additional check' \
                               -e '^To authenticate, visit https://login\.tailscale\.com/' \
                          "$out_file" 2>/dev/null || true)
  HOTLINE_REMOTE_STDERR=$(grep -v -e '^# Tailscale SSH requires an additional check' \
                                  -e '^To authenticate, visit https://login\.tailscale\.com/' \
                             "$err_file" 2>/dev/null || true)
  local err_txt="$HOTLINE_REMOTE_STDERR"
  rm -f "$out_file" "$err_file"

  if [[ $rc -eq 0 ]]; then
    return 0
  fi

  # 124 is `timeout`'s. On a tailnet in check mode this is the shape an expired
  # check period takes — a BatchMode hop with nowhere to ask — so the URL leads.
  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
    HOTLINE_REMOTE_ERR="ssh to $target timed out after ${budget}s"
    if [[ -n "$HOTLINE_REMOTE_AUTH_URL" ]]; then
      HOTLINE_REMOTE_ERR+=" — Tailscale SSH wants a browser check first: visit $HOTLINE_REMOTE_AUTH_URL, then re-dial"
    else
      HOTLINE_REMOTE_ERR+=" — if that box uses Tailscale SSH in check mode, an expired check period blocks a non-interactive hop; run \`ssh $target true\` yourself once to re-authenticate, then re-dial"
    fi
    return 1
  fi
  if [[ $rc -eq 255 ]]; then
    HOTLINE_REMOTE_ERR="ssh to $target failed: ${err_txt:-no diagnostic} (rc=255)"
    HOTLINE_REMOTE_ERR=$(printf '%s' "$HOTLINE_REMOTE_ERR" | tr '\n\r\t' '   ' | cut -c1-300)
    return 1
  fi
  HOTLINE_REMOTE_ERR="remote command on $target exited $rc: ${err_txt:-no diagnostic}"
  HOTLINE_REMOTE_ERR=$(printf '%s' "$HOTLINE_REMOTE_ERR" | tr '\n\r\t' '   ' | cut -c1-300)
  return 1
}

# --- The remote box's own answers about itself -------------------------------
# HOTLINE_REMOTE_HOME ← the remote $HOME. Asked, never assumed: a local
# ~/.claude/projects prefix would be right only by coincidence.
# Resolved once per process; every later caller reads the cache.
HOTLINE_REMOTE_HOME=""
hotline_remote_home() {
  [[ -n "$HOTLINE_REMOTE_HOME" ]] && return 0
  hotline_remote_run 'printf %s "$HOME"' || return 1
  HOTLINE_REMOTE_HOME=$(printf '%s' "$HOTLINE_REMOTE_OUT" | tr -d '\r\n')
  if [[ -z "$HOTLINE_REMOTE_HOME" ]]; then
    HOTLINE_REMOTE_ERR="the remote box reported an empty \$HOME, so no transcript path can be derived"
    return 1
  fi
  return 0
}

# HOTLINE_REMOTE_REALCWD ← the remote realpath of a remote directory, and proof
# that it IS a directory. Both in one hop, because both are needed together and a
# second hop is a second chance for the tailnet check to bite.
#
# THE REALPATH IS THE POINT (claude-plugins-7wze.10). Claude Code encodes the cwd
# it actually resolved, so a callee started in a symlinked remote path writes its
# transcript under the resolved spelling. One cwd spelling is not enough, and the
# spelling that matters is the REMOTE box's — deriving it from a local realpath
# would resolve local symlinks against a filesystem the callee never saw.
HOTLINE_REMOTE_REALCWD=""
hotline_remote_realpath_dir() {  # <remote-path>
  HOTLINE_REMOTE_REALCWD=""
  local q
  q=$(hotline_remote_shquote "$1")
  hotline_remote_run "d=$q; [ -d \"\$d\" ] || { echo NOTADIR >&2; exit 3; }; realpath \"\$d\" 2>/dev/null || (cd \"\$d\" && pwd -P)" \
    || return 1
  HOTLINE_REMOTE_REALCWD=$(printf '%s' "$HOTLINE_REMOTE_OUT" | tr -d '\r\n')
  if [[ -z "$HOTLINE_REMOTE_REALCWD" ]]; then
    HOTLINE_REMOTE_ERR="could not resolve $1 on the remote box"
    return 1
  fi
  return 0
}

# Is a command on the REMOTE PATH? The remote `claude` is the one preflight check
# with no local counterpart, and it needs asking: a non-login ssh command runs with
# the remote box's own PATH, which is not the caller's and not necessarily the one
# a human sees after logging in.
hotline_remote_have_cmd() {  # <command>
  local q
  q=$(hotline_remote_shquote "$1")
  hotline_remote_run "command -v $q >/dev/null 2>&1"
}

# --- The remote transcript ----------------------------------------------------
# One path per line, both spellings of the cwd, on the REMOTE filesystem. The
# local twin (hotline_transcript_candidates) exists for the same reason and is
# deliberately not reused: every component here — $HOME, the realpath, the
# existence test — belongs to the other box.
#
# Emits nothing (exit 0) when a component is MISSING, exactly as the local twin
# does: a caller that was never told the callee's cwd or session has no transcript
# to read, and that is an answer rather than an error.
#
# A FAILED HOP IS NOT THAT ANSWER, and returns 1. The local twin cannot fail — it
# reads $HOME and a realpath — but half of this derivation is a question put to
# another machine, and collapsing "that box did not answer" into "there is nothing
# to read" makes the waiter report a missing input while listing all three inputs as
# present. HOTLINE_REMOTE_ERR holds the hop's own diagnostic for the caller to quote.
hotline_remote_transcript_candidates() {  # <remote-cwd> <session-id>
  local cwd="$1" session="$2" spelling encoded seen=""
  [[ -z "$cwd" || -z "$session" ]] && return 0
  hotline_remote_home || return 1
  local resolved=""
  if hotline_remote_realpath_dir "$cwd"; then resolved="$HOTLINE_REMOTE_REALCWD"; fi
  for spelling in "$cwd" "$resolved"; do
    [[ -z "$spelling" ]] && continue
    encoded=$(printf '%s' "$spelling" | sed 's|[^a-zA-Z0-9]|-|g')
    local path="$HOTLINE_REMOTE_HOME/.claude/projects/$encoded/$session.jsonl"
    case "$seen" in *"|$path|"*) continue ;; esac
    seen="$seen|$path|"
    printf '%s\n' "$path"
  done
  return 0
}

# Fetch the first of these remote paths that exists into <local-dest>, and print
# the REMOTE path it came from. One hop for the whole list.
#   0 — fetched; <local-dest> holds the transcript and stdout names its origin
#   1 — none of them exists yet (or the hop failed; HOTLINE_REMOTE_ERR says)
#
# `cat` over ssh rather than scp/rsync: one already-authenticated channel and no
# second tool to require on either end. The transcript is append-only JSONL written
# a whole line at a time, so a fetch that catches a half-written last line is
# unlikely — and NOT tolerated when it happens: transcript-extract.sh slurps the
# whole mirror with `jq -s`, which fails on a truncated line, and
# wait-for-response.sh treats that rc=1 as a read error and exits 1 rather than
# re-reading on its next slice. Unlikely, then, is the whole of the protection.
hotline_remote_fetch_transcript() {  # <local-dest> <remote-path>...
  local dest="$1"; shift
  [[ $# -eq 0 ]] && return 1
  local cmd='for p in' q
  for q in "$@"; do cmd+=" $(hotline_remote_shquote "$q")"; done
  # The chosen path is announced on STDERR so stdout stays pure transcript bytes.
  cmd+='; do if [ -s "$p" ]; then printf %s "$p" >&2; cat "$p"; exit 0; fi; done; exit 9'
  local target budget out_file err_file rc
  target=$(hotline_remote_target)
  [[ -z "$target" ]] && { HOTLINE_REMOTE_ERR="no remote target set"; return 1; }
  hotline_remote_mux_init
  budget="${HOTLINE_REMOTE_HOP_BUDGET:-$HOTLINE_REMOTE_SSH_TIMEOUT}"
  local -a opts=(-o BatchMode=yes -o "ConnectTimeout=$HOTLINE_REMOTE_SSH_CONNECT_TIMEOUT"
                 -o StrictHostKeyChecking=accept-new)
  [[ -n "$HOTLINE_REMOTE_CONTROL_PATH" ]] && \
    opts+=(-o ControlMaster=auto -o "ControlPersist=$HOTLINE_REMOTE_SSH_PERSIST"
           -o "ControlPath=$HOTLINE_REMOTE_CONTROL_PATH")
  local raw_file
  err_file=$(mktemp); raw_file=$(mktemp)
  # Via a temp rather than straight into the mirror, because the notice filter
  # below has to run BETWEEN ssh and the file — and because a filter in the
  # pipeline would put grep's status where pipefail can read it as the hop's.
  timeout "$budget" ssh -n "${opts[@]}" "$target" "$cmd" >"$raw_file" 2>"$err_file"
  rc=$?
  local chosen
  chosen=$(grep -o '^/[^[:space:]]*\.jsonl' "$err_file" 2>/dev/null | head -1 || true)
  local url
  url=$(grep -ho 'https://login\.tailscale\.com/[^[:space:]]*' "$raw_file" "$err_file" 2>/dev/null | head -1 || true)
  [[ -n "$url" ]] && HOTLINE_REMOTE_AUTH_URL="$url"
  rm -f "$err_file"
  if [[ $rc -ne 0 || -z "$chosen" ]]; then
    rm -f "$raw_file"
    HOTLINE_REMOTE_RC=$rc
    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
      HOTLINE_REMOTE_ERR="fetching the remote transcript from $target timed out after ${budget}s"
      [[ -n "$HOTLINE_REMOTE_AUTH_URL" ]] && \
        HOTLINE_REMOTE_ERR+=" — Tailscale SSH wants a browser check first: $HOTLINE_REMOTE_AUTH_URL"
    elif [[ $rc -eq 9 ]]; then
      HOTLINE_REMOTE_ERR="no transcript exists yet at any candidate path on $target"
    else
      HOTLINE_REMOTE_ERR="could not read a remote transcript from $target (rc=$rc)"
    fi
    : > "$dest"
    return 1
  fi
  # THE SAME FILTER EVERY OTHER HOP APPLIES, for a harder reason: this stream is not
  # parsed here, it BECOMES the file transcript-extract.sh slurps. One Tailscale
  # check-mode notice line in the mirror makes its `jq -s` fail, and
  # wait-for-response.sh reports that rc=1 as a read error and exits 1 — a delivered
  # answer reported as a failure. Whole JSONL lines only, therefore, on the way in.
  grep -v -e '^# Tailscale SSH requires an additional check' \
          -e '^To authenticate, visit https://login\.tailscale\.com/' \
       "$raw_file" > "$dest" 2>/dev/null || true
  rm -f "$raw_file"
  printf '%s' "$chosen"
  return 0
}

# Poll the REMOTE transcripts for a delivery nonce, in ONE hop.
#   0 — the nonce is there (the payload landed); 1 — it never appeared in budget
#
# The whole retry loop runs on the far side deliberately. The local twin polls a
# local file N times; doing that from here would be N ssh hops for one question,
# each a fresh chance for the tailnet check to stall, and the answer would arrive
# later than the thing it is timing. The nonce goes on the remote command line —
# it is a per-call random token, not the payload, and the local path already hands
# it to `grep` on an argv.
hotline_remote_confirm_nonce() {  # <nonce> <tries> <sleep> <remote-path>...
  local nonce="$1" tries="$2" nap="$3"
  shift 3
  [[ -z "$nonce" || $# -eq 0 ]] && return 1
  local cmd paths="" q
  for q in "$@"; do paths+=" $(hotline_remote_shquote "$q")"; done
  cmd="n=$(hotline_remote_shquote "$nonce"); i=0; while [ \$i -lt $(hotline_remote_shquote "$tries") ]; do"
  cmd+=" for p in$paths; do if [ -s \"\$p\" ] && grep -qF -- \"\$n\" \"\$p\" 2>/dev/null; then exit 0; fi; done;"
  cmd+=" i=\$((i+1)); sleep $(hotline_remote_shquote "$nap"); done; exit 1"
  # The remote loop's own wall clock plus slack, so the hop budget cannot expire
  # before the poll it is carrying.
  local span rc saved="${HOTLINE_REMOTE_HOP_BUDGET:-}"
  span=$(awk -v t="$tries" -v s="$nap" 'BEGIN{printf "%d", (t*s)+20}' 2>/dev/null || echo 60)
  [[ "$span" =~ ^[0-9]+$ ]] || span=60
  # Set-call-restore rather than an `X=… func` prefix: bash keeps such an
  # assignment in effect after a FUNCTION call returns, which would silently pin
  # every later hop in this process to this poll's budget.
  HOTLINE_REMOTE_HOP_BUDGET="$span"
  hotline_remote_run "$cmd"; rc=$?
  HOTLINE_REMOTE_HOP_BUDGET="$saved"
  return $rc
}
