#!/usr/bin/env bash
# Which Claude account a claude callee runs on. Sourced.
#
# HOTLINE_CLAUDE_CONFIG_DIR names the callee's config dir; dial.sh defaults it to
# the dialer's own $CLAUDE_CONFIG_DIR, so a callee runs on its caller's account.
# Unset on both leaves every launch exactly as before: no CLAUDE_CONFIG_DIR is set,
# and the callee gets whatever its host (herdr server, cmux app) carries.
#
# It must reach claude as a PROCESS env var (herdr --env, a cmux launch-script
# export, the headless process env), never as `--settings '{"env":…}'`: claude
# picks its config dir before it reads settings, so a settings env block would
# leave the callee on the default account without a word.
#
# The value is passed VERBATIM, never canonicalized. Claude keys its keychain login
# on sha256 of the raw string, so `~/.claude-alt` reached through a symlink or with
# a trailing slash is a different, logged-out account. Canonical forms are only for
# comparing two spellings of one dir.

claude_config_dir_validate() { # <dir> <name-for-errors>
  CLAUDE_CONFIG_DIR_ERR=""
  local d="$1"
  if [[ "$d" != /* || "$d" == *$'\n'* || "$d" == *$'\r'* || ! -d "$d" || ! -r "$d" || ! -w "$d" || ! -x "$d" ]]; then
    CLAUDE_CONFIG_DIR_ERR="$2 must name an absolute, readable, writable directory (no line breaks), got '$d'"
    return 1
  fi
}

claude_config_dir_same() { # <a> <b> — one dir by two spellings; empty only matches empty
  [[ -z "$1" || -z "$2" ]] && { [[ "$1" == "$2" ]]; return; }
  local a b
  a=$(cd -P "$1" 2>/dev/null && pwd -P) || a="${1%/}"
  b=$(cd -P "$2" 2>/dev/null && pwd -P) || b="${2%/}"
  [[ "$a" == "$b" ]]
}

# The launch record waiters and cache writers read. Absent = no dir was set.
claude_config_dir_record() { # <call-dir> <agent-kind>
  [[ "$2" == claude && -n "${HOTLINE_CLAUDE_CONFIG_DIR:-}" && -d "$1" ]] || return 0
  printf '%s\n' "$HOTLINE_CLAUDE_CONFIG_DIR" > "$1/claude_config_dir.txt"
}

# A waiter is its own process with only the call dir, so the recorded dir — not
# the waiter's env — decides where the callee's transcript is (transcript-path.sh).
claude_config_dir_adopt() { # <call-dir>
  [[ -n "${1:-}" && -s "$1/claude_config_dir.txt" ]] || return 0
  HOTLINE_CLAUDE_CONFIG_DIR=$(cat "$1/claude_config_dir.txt")
  export HOTLINE_CLAUDE_CONFIG_DIR
}
