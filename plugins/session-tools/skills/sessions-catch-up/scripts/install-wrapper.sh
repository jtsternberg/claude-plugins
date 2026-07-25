#!/usr/bin/env bash
# =============================================================================
# install-wrapper.sh — install the optional `claude-session-catchup` shell shim.
#
# Launches a fresh Claude Code session that immediately catches you up on another
# session, so a catch-up is one command from any terminal instead of "open claude,
# then invoke the skill".
#
# Shell, not PHP or Node, on purpose: this hands an interactive TTY to `claude`.
# A wrapper that captures output would swallow the REPL. (Same reasoning as
# ~/.dotfiles/bin/watchdog-chat.)
#
# Usage:
#   install-wrapper.sh install [--dir <bindir>]
#   install-wrapper.sh uninstall
#   install-wrapper.sh status
# =============================================================================
set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
NAME="claude-session-catchup"

CMD="${1:-status}"; shift || true
while [[ $# -gt 0 ]]; do
	case "$1" in
		--dir) BIN_DIR="$2"; shift 2 ;;
		*) shift ;;
	esac
done

TARGET="${BIN_DIR}/${NAME}"

case "$CMD" in
	status)
		if [ -x "$TARGET" ]; then
			echo "installed: $TARGET"
			case ":$PATH:" in
				*":$BIN_DIR:"*) echo "on PATH: yes" ;;
				*) echo "on PATH: NO — add 'export PATH=\"$BIN_DIR:\$PATH\"' to your shell rc" ;;
			esac
		else
			echo "not installed (would go to $TARGET)"
		fi
		;;

	uninstall)
		if [ -e "$TARGET" ]; then rm -f "$TARGET"; echo "removed $TARGET"; else echo "nothing to remove at $TARGET"; fi
		;;

	install)
		command -v claude >/dev/null 2>&1 || { echo "Error: 'claude' not found on PATH." >&2; exit 1; }
		command -v node   >/dev/null 2>&1 || echo "Warning: 'node' not found — the digest script needs Node 18+." >&2
		mkdir -p "$BIN_DIR"

		cat > "$TARGET" <<'WRAPPER'
#!/usr/bin/env bash
# claude-session-catchup — catch up on another Claude Code session, from anywhere.
#
# Installed by the sessions-catch-up skill (session-tools plugin).
#
# Usage:
#   claude-session-catchup <session-id|prefix|slug|title>
#   claude-session-catchup --yolo <target>     # skip permission prompts
#   CLAUDE_CATCHUP_YOLO=1 claude-session-catchup <target>
#
# Permissions are NOT skipped by default. --dangerously-skip-permissions is
# opt-in via --yolo or CLAUDE_CATCHUP_YOLO=1, never assumed.
set -euo pipefail

YOLO="${CLAUDE_CATCHUP_YOLO:-0}"
ARGS=()
for a in "$@"; do
	case "$a" in
		--yolo) YOLO=1 ;;
		*) ARGS+=("$a") ;;
	esac
done

if [ "${#ARGS[@]}" -eq 0 ]; then
	echo "usage: claude-session-catchup <session-id|prefix|slug|title> [--yolo]" >&2
	exit 1
fi

TARGET="${ARGS[0]}"
FLAGS=()
[ "$YOLO" = "1" ] && FLAGS+=(--dangerously-skip-permissions)

# A sidecar session: separate from the one being read, so its context is untouched.
exec claude "${FLAGS[@]}" "/sessions-catch-up $TARGET"
WRAPPER

		chmod +x "$TARGET"
		echo "installed: $TARGET"
		case ":$PATH:" in
			*":$BIN_DIR:"*) : ;;
			*) echo "NOTE: $BIN_DIR is not on your PATH — add 'export PATH=\"$BIN_DIR:\$PATH\"' to your shell rc" ;;
		esac
		echo
		echo "Try:  $NAME <session-id>"
		echo "Permissions are not skipped unless you pass --yolo or set CLAUDE_CATCHUP_YOLO=1."
		;;

	*)
		echo "usage: install-wrapper.sh install|uninstall|status [--dir <bindir>]" >&2
		exit 1
		;;
esac
