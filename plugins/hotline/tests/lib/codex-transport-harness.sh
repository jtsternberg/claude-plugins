#!/usr/bin/env bash
# Shared Codex/herdr fixture (row shapes from codex-cli 0.165.0).
# shellcheck source=lib/herdr-transport-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/herdr-transport-harness.sh"

THREAD=01a1a28d-f07a-76a3-bbc7-21b555a6a8dc

# A codex on PATH (never run — herdr is stubbed — but dial.sh preflights for it),
# and an `agent prompt` that writes the callee's rollout the way codex would:
# the typed prompt as a user message, then, unless told otherwise, a final answer
# bracketed for the nonce it finds in that prompt.
codex_env() {  # codex_env <scratch> [reply: done|none]
  local t="$1" reply="${2:-done}"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$t/bin/codex"; chmod +x "$t/bin/codex"
  mkdir -p "$t/binsrc"; make_herdr_stub "$t/binsrc"; mv "$t/binsrc/herdr" "$t/bin/herdr-real"
  cat > "$t/bin/herdr" <<STUBW
#!/usr/bin/env bash
if [[ "\$1 \${2:-}" == "tab create" ]]; then
  for arg in "\$@"; do
    [[ "\$arg" == CODEX_HOME=* ]] && printf '%s' "\${arg#CODEX_HOME=}" > "\$HERDR_STATE/process_home"
  done
fi
if [[ "\$1 \${2:-}" == "agent prompt" && "\${HERDR_STUB_CODEX_NO_ROLLOUT:-}" != 1 ]]; then
  PROCESS_HOME=\$(cat "\$HERDR_STATE/process_home" 2>/dev/null || printf '%s' "\${CODEX_HOME:-\$HOME/.codex}")
  R="\$PROCESS_HOME/sessions/2026/11/03/rollout-2026-11-03T12-56-13-$THREAD.jsonl"
  mkdir -p "\$(dirname "\$R")"
  N=\$(grep -oE 'CALL_ID: [0-9a-f]+' <<<"\$4" | head -1 | cut -d' ' -f2)
  jq -nc --arg s "$THREAD" '{type:"session_meta",payload:{id:\$s}}' >> "\$R"
  jq -nc --arg t "\$4" '{type:"response_item",payload:{type:"message",role:"user",content:[{type:"input_text",text:\$t}]}}' >> "\$R"
  if [[ "$reply" == done ]]; then
    jq -nc --arg t "STATUS: WORK_IN_PROGRESS call_id=\$N"\$'\n\n'"codex did it"\$'\n\n'"STATUS: WORK_COMPLETE call_id=\$N" \
      '{type:"response_item",payload:{type:"message",role:"assistant",phase:"final_answer",content:[{type:"output_text",text:\$t}]}}' >> "\$R"
    jq -nc '{type:"event_msg",payload:{type:"task_complete"}}' >> "\$R"
  fi
fi
exec bash "$t/bin/herdr-real" "\$@"
STUBW
  chmod +x "$t/bin/herdr"
}

# Every codex dial in this file: the herdr preflight's pane, and a confirmation budget
# measured in ticks rather than seconds.
CODEX_READY_SCREEN="$ROOT/codex-ready-screen"
printf '› Ask Codex to do anything\n  ? for shortcuts\n' > "$CODEX_READY_SCREEN"
CENV=(HOTLINE_HERDR_PANE=w1:p1 HOTLINE_HERDR_FIRST_SETTLE=0 HOTLINE_HERDR_PANE_SETTLE=0
      HOTLINE_PASTE_CONFIRM_SLEEP=0.05 HOTLINE_CODEX_COMPOSER_TRIES=5
      HERDR_STUB_SCREEN="$CODEX_READY_SCREEN")

