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

# One account by two spellings. Empty (no CLAUDE_CONFIG_DIR) IS the default
# account, ~/.claude.
_claude_config_dir_key() {
  local d="${1:-$HOME/.claude}"
  (cd -P "$d" 2>/dev/null && pwd -P) || printf '%s\n' "${d%/}"
}
claude_config_dir_same() { # <a> <b>
  [[ "$(_claude_config_dir_key "$1")" == "$(_claude_config_dir_key "$2")" ]]
}

# The default dir means the default account, which claude reaches with
# CLAUDE_CONFIG_DIR UNSET: setting it to ~/.claude, even verbatim, keys a different
# keychain entry. Launchers unset it for this dir instead of exporting it.
claude_config_dir_is_default() { # <dir>
  claude_config_dir_same "$1" ""
}

# Whether <dir> holds session <id>: its transcript, or a live registry entry for a
# session that has not written one yet.
claude_config_dir_holds() { # <dir> <session-id>
  local d="${1:-$HOME/.claude}" f
  for f in "$d"/projects/*/"$2".jsonl; do [[ -f "$f" ]] && return 0; done
  grep -lsF "\"sessionId\":\"$2\"" "$d"/sessions/*.json >/dev/null 2>&1
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
