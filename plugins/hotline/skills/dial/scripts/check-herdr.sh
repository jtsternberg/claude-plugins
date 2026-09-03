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
# WITH $HOTLINE_HERDR_REMOTE SET, ALL THREE ARE ASKED OF THAT BOX — over ssh, via
# herdr-state.sh's dispatch, so the questions and their wording are the same ones.
# Two are ADDED for a remote dial, ahead of the rest, because they are the two that
# cannot be inferred from anything local:
#   0. the ssh hop itself — reachable, non-interactive, inside the time box. First,
#      because every check after it is an ssh hop and reporting "herdr is not
#      installed" about a box we could not reach is a lie.
#   4. `claude` on the REMOTE PATH. A non-login `ssh host cmd` gets that box's own
#      PATH, not the one a human sees after logging in, so a claude installed under
#      ~/.local/bin may or may not resolve. It has no local counterpart: locally the
#      launcher inherits the caller's own environment, where claude is a given.
#      Checked last of the four because it is the one failure a user fixes without
#      touching herdr at all.
# Emitted on success for a remote dial: .remote (the target) alongside .pane.
#
# Usage:
#   check-herdr.sh
#   HOTLINE_HERDR_REMOTE=<ssh-target> check-herdr.sh
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

REMOTE=""
# Which override names the pane, spelled once: the local and remote seams are
# deliberately different variables (see herdr_resolve_split_pane), and a recovery
# that names the wrong one sends a user to set something with no effect.
PANE_VAR="HOTLINE_HERDR_PANE"
if hotline_remote_active; then
  PANE_VAR="HOTLINE_HERDR_REMOTE_PANE"
  REMOTE=$(hotline_remote_target)
  # The hop, before anything that would ride it. `true` is the cheapest remote
  # command there is, and it also warms the ControlMaster so the checks below and
  # the launch that follows all reuse one authenticated connection.
  hotline_remote_run 'true' || unusable \
    "the remote box $REMOTE could not be reached over ssh: ${HOTLINE_REMOTE_ERR:-no diagnostic}" \
    "Prove the hop by hand first: \`ssh -o BatchMode=yes $REMOTE true\`. It has to work NON-INTERACTIVELY — hotline never answers a password or a browser check. Check the host name (a tailnet MagicDNS name is not the same host as its .local mDNS name), the user (the tailnet's SSH policy may not permit the one you asked for), and whether an agent/key is available. Or drop --remote to dial locally."
fi

herdr_on_path || unusable \
  "herdr is not on PATH${REMOTE:+ on $REMOTE}" \
  "Install herdr (https://herdr.dev)${REMOTE:+ on $REMOTE, and make sure it resolves for a non-login \`ssh $REMOTE command -v herdr\`} or drop --transport herdr to use the cmux default."

herdr_reachable || unusable \
  "herdr is installed${REMOTE:+ on $REMOTE} but no server answered: ${HERDR_CLI_ERR:-\`herdr session list\` failed and HERDR_ENV is not 1}" \
  "Start herdr (run \`herdr\` in a terminal${REMOTE:+ on $REMOTE}, or \`herdr session list\` to see what is up), then re-dial. Or drop ${REMOTE:+--remote, or }--transport herdr to use the cmux default."

herdr_resolve_split_pane || unusable \
  "herdr is up${REMOTE:+ on $REMOTE} but no pane could be resolved to host the callee: ${HERDR_CLI_ERR:-no diagnostic}" \
  "Open a herdr pane${REMOTE:+ on $REMOTE} (any pane will do — hotline splits it), or set $PANE_VAR=<pane-id> to name one explicitly."

if [[ -n "$REMOTE" ]]; then
  hotline_remote_have_cmd claude || unusable \
    "claude is not on the PATH a non-login ssh command gets on $REMOTE, so \`herdr agent start --kind claude\` there would have nothing to start" \
    "Check it yourself with \`ssh $REMOTE command -v claude\`. If it resolves for you interactively but not there, the install is only on a login-shell PATH — add its directory to that box's non-login environment (~/.ssh/environment, or the shell rc the ssh command actually reads)."
fi

jq -nc --arg pane "$HERDR_PANE" --arg remote "$REMOTE" \
  '{usable: true,
    reason: (if $remote == "" then "herdr is on PATH, a server answered, and a pane is available to split"
             else "ssh reached \($remote); herdr is on its PATH, its server answered, a pane is available to split, and claude resolves there" end),
    pane: $pane}
   + (if $remote == "" then {} else {remote: $remote} end)'
exit 0
