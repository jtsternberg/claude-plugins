#!/usr/bin/env bash
# =============================================================================
# Check herdr: is the herdr transport usable for a hotline call?
#
# The preflight verb of the herdr backend, and the counterpart of check-cmux.sh.
# It answers in JSON rather than by exit status alone, because dial.sh has to be
# able to TELL the caller what is missing: `--transport herdr` is explicit, so a
# failure here is an error the user has to act on, not a degrade hotline can make
# on their behalf.
#
#   {"usable":true,"reason":"…","pane":"w6:p1"}            exit 0
#   {"usable":false,"reason":"…","recovery":"…"}           exit 1
#
# Three things are checked, in the order a reader needs them:
#   1. `herdr` on PATH — an install problem.
#   2. a reachable server — HERDR_ENV=1 (we are inside a herdr pane, so a server
#      is hosting this very process) or `herdr session list` answering. A "start
#      herdr" problem.
#   3. a pane to split — the callee needs a host, and `agent start` cannot create
#      one (herdr is explicit that it "never creates, splits, or moves layout").
#      Checked HERE rather than discovered inside the launcher so the failure
#      arrives before a call dir exists and before anything has been minted.
#
# Usage:
#   check-herdr.sh
# =============================================================================
set -uo pipefail

if [[ "${1:-}" == "--help" ]]; then
  sed -n '2,/^# =\{10,\}$/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^=\{10,\}$'
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/herdr-state.sh
source "$SCRIPT_DIR/../../../scripts/herdr-state.sh"

unusable() {  # unusable <reason> <recovery>
  jq -nc --arg reason "$1" --arg recovery "$2" \
    '{usable: false, reason: $reason, recovery: $recovery}'
  exit 1
}

herdr_on_path || unusable \
  "herdr is not on PATH" \
  "Install herdr (https://herdr.dev) or drop --transport herdr to use the cmux default."

herdr_reachable || unusable \
  "herdr is installed but no server answered: ${HERDR_CLI_ERR:-\`herdr session list\` failed and HERDR_ENV is not 1}" \
  "Start herdr (run \`herdr\` in a terminal, or \`herdr session list\` to see what is up), then re-dial. Or drop --transport herdr to use the cmux default."

herdr_resolve_split_pane || unusable \
  "herdr is up but no pane could be resolved to host the callee: ${HERDR_CLI_ERR:-no diagnostic}" \
  "Open a herdr pane (any pane will do — hotline splits it), or set HOTLINE_HERDR_PANE=<pane-id> to name one explicitly."

jq -nc --arg pane "$HERDR_PANE" \
  '{usable: true, reason: "herdr is on PATH, a server answered, and a pane is available to split", pane: $pane}'
exit 0
