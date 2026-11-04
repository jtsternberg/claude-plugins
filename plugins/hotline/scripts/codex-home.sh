#!/usr/bin/env bash
# Explicit process-account selection. Tool shell policy is not authentication:
# herdr's server launches Codex, so the pane must receive CODEX_HOME at creation.
# No credentials are inspected. Unset leaves every existing launch untouched.
codex_home_validate() { # <agent> <transport> <remote> <resume>
  CODEX_HOME_ERR=""
  [[ ${HOTLINE_CODEX_HOME+x} ]] || return 0
  if [[ "$1" != codex || "$2" != herdr || -n "$3" || -n "$4" \
        || "${HOTLINE_HERDR_PLACEMENT:-split}" == split ]]; then
    CODEX_HOME_ERR='HOTLINE_CODEX_HOME requires a fresh local Codex herdr tab/workspace; split, remote, resume and other transports are unsupported'
    return 1
  fi
  if [[ "$HOTLINE_CODEX_HOME" != /* || "$HOTLINE_CODEX_HOME" == *$'\n'* || "$HOTLINE_CODEX_HOME" == *$'\r'* \
        || ! -d "$HOTLINE_CODEX_HOME" || ! -r "$HOTLINE_CODEX_HOME" || ! -w "$HOTLINE_CODEX_HOME" || ! -x "$HOTLINE_CODEX_HOME" ]]; then
    CODEX_HOME_ERR='HOTLINE_CODEX_HOME must name an absolute, readable, writable directory (no line breaks)'
    return 1
  fi
  HOTLINE_CODEX_HOME=$(cd "$HOTLINE_CODEX_HOME" && pwd -P) || return 1
  export HOTLINE_CODEX_HOME
}
