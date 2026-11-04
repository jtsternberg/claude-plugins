#!/usr/bin/env bash
# Reproduce blocked-start and screen settling without models, real sleeps or
# servers. The native smoke's agent_not_ready response and current visible
# snapshots are independent: a stale gate word is not a human trust decision.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/codex-transport-harness.sh"
REAL_DATE_BIN=$(command -v date)
for scenario in ${CODEX_STARTUP_CASES:-transient stale gate overlay pending lost delivery false-ready false-gate resolution header spent long-poll}; do
  t=$(new_env); codex_env "$t"; mkdir -p "$t/work"
  printf '1000\n' > "$t/state/clock"
  mv "$t/bin/herdr" "$t/bin/herdr-codex"
  cat > "$t/bin/date" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == '+%s' ]]; then cat "$HERDR_STATE/clock"; else exec "$REAL_DATE_BIN" "$@"; fi
STUB
  cat > "$t/bin/sleep" <<'STUB'
#!/usr/bin/env bash
# Fake clock advances on positive naps; zero settle delays remain zero.
printf '%s\n' "${1:-0}" >> "$HERDR_STATE/naps"
if awk -v n="${1:-0}" 'BEGIN{exit !(n>0)}'; then
  now=$(cat "$HERDR_STATE/clock"); echo $((now+1)) > "$HERDR_STATE/clock"
fi
STUB
  cat > "$t/bin/herdr" <<'STUB'
#!/usr/bin/env bash
inner="$(dirname "$0")/herdr-codex"
mode="$STARTUP_SCENARIO"; elapsed=$(($(cat "$HERDR_STATE/clock")-1000))
if [[ "$1 ${2:-}" == 'agent start' ]]; then
  bash "$inner" "$@" >/dev/null
  [[ "$mode" != spent ]] || printf '1005\n' > "$HERDR_STATE/clock"
  if [[ "$mode" == false-ready || "$mode" == false-gate ]]; then
    echo '{"result":{"agent":{"interactive_ready":false,"agent_status":"unknown"}}}'; exit 0
  fi
  [[ "$mode" == delivery || "$mode" == resolution ]] && { echo '{"result":{"agent":{"interactive_ready":true,"agent_status":"idle"}}}'; exit 0; }
  echo '{"error":{"code":"agent_not_ready","message":"agent is blocked during startup and is not ready for prompts"}}' >&2
  exit 1
fi
if [[ "$1 ${2:-}" == 'agent get' && -s "$HERDR_STATE/started" ]]; then
  if [[ "$mode" == resolution && $elapsed == 0 ]]; then
    echo '{"error":{"code":"agent_not_found","message":"startup registration pending"}}' >&2; exit 1
  fi
  value=$(bash "$inner" "$@")
  status=idle; ready=true
  if [[ "$mode" == gate || "$mode" == header || "$mode" == spent || "$mode" == false-gate || ( "$mode" == transient && $elapsed -lt 2 ) || ( "$mode" == false-ready && $elapsed -lt 2 ) ]]; then status=blocked; ready=false; fi
  [[ "$mode" == pending || "$mode" == long-poll ]] && { status=unknown; ready=false; }
  jq -c --arg s "$status" --argjson ready "$ready" '.result.agent.agent_status=$s | .result.agent.interactive_ready=$ready' <<<"$value"
  exit 0
fi
if [[ "$1 ${2:-}" == 'pane read' || "$1 ${2:-}" == 'agent read' ]]; then
  case "$mode" in
    stale) printf 'Earlier startup: Trust this folder?\n› Ask Codex to do anything\n ? for shortcuts\n' ;;
    header) printf 'Trust this folder?\n' ;;
    gate|false-gate|spent) printf 'Trust this folder?\n  1. Trust and continue\n  2. Cancel and exit\nEnter to confirm\n' ;;
    overlay) printf 'Trust this folder?\n› Ask Codex to do anything\n ? for shortcuts\n  1. Trust and continue\n  2. Cancel and exit\nEnter to confirm\n' ;;
    pending|long-poll) printf 'Starting Codex…\n' ;;
    lost) if [[ $elapsed == 0 ]]; then printf 'Trust this folder?\n'; else echo '{"error":{"code":"snapshot_unavailable","message":"no current frame"}}' >&2; exit 1; fi ;;
    *) if [[ $elapsed == 0 ]]; then printf 'Trust this folder?\n  1. Trust and continue\nEnter to confirm\n'; elif [[ $elapsed == 1 ]]; then printf 'Starting Codex…\n'; else printf '› Ask Codex to do anything\n ? for shortcuts\n'; fi ;;
  esac
  exit 0
fi
exec bash "$inner" "$@"
STUB
  chmod +x "$t/bin/date" "$t/bin/sleep" "$t/bin/herdr"
  budget_env=()
  [[ "$scenario" != pending ]] || budget_env=(HOTLINE_CODEX_COMPOSER_TRIES=100)
  [[ "$scenario" != long-poll ]] || budget_env=(HOTLINE_CODEX_COMPOSER_TRIES=100 HOTLINE_PASTE_CONFIRM_SLEEP=999)
  out=$(dial "$t" "${CENV[@]}" REAL_DATE_BIN="$REAL_DATE_BIN" STARTUP_SCENARIO="$scenario" \
    HERDR_STUB_AGENT_KIND=codex HERDR_STUB_AGENT_PANE=w1:p7 "${budget_env[@]}" \
    HOTLINE_CODEX_HOME="$t/work" HOTLINE_HERDR_PLACEMENT=tab -- \
    --target "$t/target" --agent codex --fresh --mode quick --boot-timeout 5 --prompt 'read-only probe')
  elapsed=$(($(cat "$t/state/clock")-1000))
  case "$scenario" in
    transient|stale|delivery|false-ready|resolution)
      [[ "$(jq -r .status <<<"$out")" == connected && "$(jq -r .confirmed <<<"$out")" == rollout \
         && $(grep -c 'agent start' "$t/herdr.log") == 1 && $(grep -c 'agent prompt' "$t/herdr.log") == 1 ]]
      check "$scenario: settle same callee until current composer, then deliver exactly once" $? "elapsed=$elapsed out=$out"
      ;;
    gate|overlay|false-gate)
      [[ "$(jq -r .status <<<"$out")" == error && "$(jq -r .detail <<<"$out")" == *FOLDER-TRUST* \
         && $elapsed -ge 3 && $elapsed -le 5 ]] && ! grep -q 'agent prompt' "$t/herdr.log"
      check "$scenario: bounded persistent real gate refuses, even with a composer behind it" $? "elapsed=$elapsed out=$out"
      ;;
    pending|lost|header|spent|long-poll)
      [[ "$(jq -r .status <<<"$out")" == error && "$(jq -r .detail <<<"$out")" != *FOLDER-TRUST* \
         && $elapsed -ge 3 && $elapsed -le 5 ]] && ! grep -q 'agent prompt' "$t/herdr.log"
      check "$scenario: bounded unresolved evidence refuses without a false trust classification" $? "elapsed=$elapsed out=$out"
      ;;
  esac
  if [[ "$scenario" == pending ]]; then
    [[ $elapsed == 5 ]]
    check 'wall-clock deadline stops pending startup before its larger probe cap' $? "elapsed=$elapsed"
  fi
  if [[ "$scenario" == long-poll ]]; then
    awk '$1>5 {exit 1}' "$t/state/naps"
    check 'configured poll interval cannot sleep past the boot deadline' $? "naps=$(cat "$t/state/naps")"
  fi
  [[ $(grep -c 'agent start' "$t/herdr.log") == 1 ]]
  check "$scenario: never retries agent start or answers a trust choice" $?
done
herdr_suite_finish
