#!/usr/bin/env bash
# HOTLINE_CALLEE_ENV="KEY=VALUE KEY2=VALUE2" — variables a dialed callee should see.
#
# Delivered as a claude settings `env` block on the callee's own command line
# (`claude --settings '{"env":{...}}'`), never by exporting into a shell: a herdr
# callee is started in a pane spawned by the herdr SERVER, and a cmux callee in a
# surface whose shell is the cmux app's, so a dialer's export reaches neither.
# The flag does, on every transport, because every transport launches claude with
# argv hotline builds. Settings `env` is applied to the process claude runs, and its
# Bash tool inherits it (verified on CC 2.1.289).
#
# Inline JSON rather than a settings file: a herdr --remote callee runs on another
# box, where a local file path means nothing, and argv already crosses that hop
# shell-quoted. The values are on argv, so `ps` shows them — the knob is for markers
# (a pipeline role, a run id), not secrets, and the dial skill says so.
#
# Only a FRESH claude process receives it. A follow-up typed into a live callee does
# not, because a running process's environment is fixed; a launch that `--resume`s
# (headless follow-ups, a cmux relaunch) is a fresh process and does.
#
# Sourced. Two functions:
#   callee_env_validate        — 0 if unset/blank or well-formed; else 1 with the
#                                reason in CALLEE_ENV_ERR
#   callee_env_settings_json   — prints {"env":{...}}, or nothing when unset/blank

callee_env_validate() {
  CALLEE_ENV_ERR=""
  local tok key seen=" "
  # zsh-proof and glob-proof: split on whitespace with read -a, never an unquoted
  # expansion (a value of `*` would otherwise glob against the cwd).
  local -a toks=()
  read -r -a toks <<<"${HOTLINE_CALLEE_ENV:-}"
  for tok in ${toks[@]+"${toks[@]}"}; do
    if [[ "$tok" != *=* ]]; then
      CALLEE_ENV_ERR="'$tok' is not KEY=VALUE"; return 1
    fi
    key="${tok%%=*}"
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      CALLEE_ENV_ERR="'$key' is not a valid variable name (letters, digits, underscore; not starting with a digit)"; return 1
    fi
    if [[ -z "${tok#*=}" ]]; then
      CALLEE_ENV_ERR="'$key' has an empty value"; return 1
    fi
    if [[ "$seen" == *" $key "* ]]; then
      CALLEE_ENV_ERR="'$key' is set twice"; return 1
    fi
    seen+="$key "
  done
  return 0
}

callee_env_settings_json() {
  local -a toks=()
  read -r -a toks <<<"${HOTLINE_CALLEE_ENV:-}"
  (( ${#toks[@]} )) || return 0
  printf '%s\n' "${toks[@]}" \
    | jq -Rnc '{env: (reduce inputs as $t ({}; . + {($t | split("=")[0]): ($t | sub("^[^=]*="; ""))}))}'
}
