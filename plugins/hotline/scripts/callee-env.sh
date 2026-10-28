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
# Two more knobs feed the same block, for values that grammar cannot carry (an
# empty value, a space) and that only the dialer's own environment knows:
#
# HOTLINE_CALLEE_ENV_FORWARD="NAME NAME2" — each name SET in the dialer's
#   environment is copied verbatim; an unset one is skipped, so one setting can
#   serve dialers that do and do not carry the variable.
# HOTLINE_CALLEE_GIT_CONFIG="<key-glob> ..." — the dialer's GIT_CONFIG_KEY_n/VALUE_n
#   entries whose key matches a glob, in order, renumbered from 0 with their own
#   GIT_CONFIG_COUNT. A filter rather than a copy because a dialer's block can hold
#   another tool's entries (a signing key in a per-process /tmp dir) that must not
#   follow it. Matched author.*/committer.* name/email entries are ALSO set as
#   GIT_AUTHOR_*/GIT_COMMITTER_*: git ranks those env vars above config, and the
#   callee's host (a herdr server's unit) may set them to a fallback identity that
#   would otherwise win. Settings env cannot unset a variable, and git refuses an
#   empty ident, so overriding is the only way past it.
#
# Precedence, last wins: forwarded, then git config, then HOTLINE_CALLEE_ENV pairs.
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
  local -a names=()
  read -r -a names <<<"${HOTLINE_CALLEE_ENV_FORWARD:-}"
  for key in ${names[@]+"${names[@]}"}; do
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      CALLEE_ENV_ERR="HOTLINE_CALLEE_ENV_FORWARD: '$key' is not a valid variable name"; return 1
    fi
  done
  if [[ -n "${HOTLINE_CALLEE_GIT_CONFIG:-}" && -n "${HOTLINE_CALLEE_GIT_CONFIG//[[:space:]]/}" && -n "${GIT_CONFIG_COUNT:-}" ]]; then
    if [[ ! "$GIT_CONFIG_COUNT" =~ ^[0-9]+$ ]]; then
      CALLEE_ENV_ERR="HOTLINE_CALLEE_GIT_CONFIG: the dialer's GIT_CONFIG_COUNT '$GIT_CONFIG_COUNT' is not a number"; return 1
    fi
    local i kvar
    for (( i = 0; i < GIT_CONFIG_COUNT; i++ )); do
      kvar="GIT_CONFIG_KEY_$i"
      if [[ -z "${!kvar:-}" ]]; then
        CALLEE_ENV_ERR="HOTLINE_CALLEE_GIT_CONFIG: GIT_CONFIG_COUNT is $GIT_CONFIG_COUNT but $kvar is unset"; return 1
      fi
    done
  fi
  return 0
}

# Every forwarded and git-config pair as NUL-separated key, value, key, value… —
# NUL because a forwarded value may hold any other byte, newlines included.
_callee_env_derived_pairs() {
  local -a names=() globs=()
  local name i n=0 key val kvar vvar g ident
  read -r -a names <<<"${HOTLINE_CALLEE_ENV_FORWARD:-}"
  for name in ${names[@]+"${names[@]}"}; do
    [[ -n "${!name+set}" ]] && printf '%s\0%s\0' "$name" "${!name}"
  done
  read -r -a globs <<<"${HOTLINE_CALLEE_GIT_CONFIG:-}"
  (( ${#globs[@]} )) && [[ "${GIT_CONFIG_COUNT:-}" =~ ^[0-9]+$ ]] || return 0
  local -a kept=()
  for (( i = 0; i < GIT_CONFIG_COUNT; i++ )); do
    kvar="GIT_CONFIG_KEY_$i"; vvar="GIT_CONFIG_VALUE_$i"
    key="${!kvar:-}"; val="${!vvar-}"
    for g in "${globs[@]}"; do
      # shellcheck disable=SC2053  # $g is a glob on purpose
      if [[ "$key" == $g ]]; then
        printf 'GIT_CONFIG_KEY_%s\0%s\0GIT_CONFIG_VALUE_%s\0%s\0' "$n" "$key" "$n" "$val"
        n=$((n + 1))
        case "$key" in
          author.name)     ident=GIT_AUTHOR_NAME ;;
          author.email)    ident=GIT_AUTHOR_EMAIL ;;
          committer.name)  ident=GIT_COMMITTER_NAME ;;
          committer.email) ident=GIT_COMMITTER_EMAIL ;;
          *)               ident="" ;;
        esac
        [[ -n "$ident" ]] && kept+=("$ident" "$val")
        break
      fi
    done
  done
  (( n )) || return 0
  printf 'GIT_CONFIG_COUNT\0%s\0' "$n"
  (( ${#kept[@]} )) && printf '%s\0' "${kept[@]}"
  return 0
}

callee_env_settings_json() {
  local -a toks=()
  local derived explicit
  read -r -a toks <<<"${HOTLINE_CALLEE_ENV:-}"
  derived=$(_callee_env_derived_pairs | jq -Rsc 'split("\u0000") | .[:-1]
    | [range(0; length; 2) as $i | {(.[$i]): .[$i + 1]}] | add // {}')
  explicit="{}"
  if (( ${#toks[@]} )); then
    explicit=$(printf '%s\n' "${toks[@]}" \
      | jq -Rnc 'reduce inputs as $t ({}; . + {($t | split("=")[0]): ($t | sub("^[^=]*="; ""))})')
  fi
  jq -nc --argjson d "$derived" --argjson e "$explicit" \
    'if ($d + $e) == {} then empty else {env: ($d + $e)} end'
}
