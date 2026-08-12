#!/usr/bin/env bash
# =============================================================================
# mail-check.sh — notice unread agent mail during a session, in either harness.
#
# Registered on SessionStart and UserPromptSubmit (hooks/hooks.json). Emits ONE
# JSON object whose hookSpecificOutput.additionalContext the harness injects
# alongside the prompt:
#
#   {"hookSpecificOutput":{"hookEventName":"UserPromptSubmit",
#                          "additionalContext":"…"},"suppressOutput":true}
#
# Why JSON: it is the explicitly specified channel on both harnesses — Claude
# Code documents it, and Codex declares the same field in
# codex-rs/hooks/schema/generated/user-prompt-submit.command.output.schema.json
# and its session-start sibling — and it is the only shape that also carries
# hookEventName and suppressOutput.
#
# Plain stdout ALSO injects on both, including Codex; that was live-probed on
# codex-cli 0.147.0 (see docs/codex/hooks-under-codex.md). Do not "simplify" this
# to a bare printf on the strength of that: without the JSON envelope there is no
# way to label the event or suppress the transient UI, and a hand-built string
# would have to escape quotes, newlines, and non-ASCII out of message previews
# correctly on every path.
#
# Why not `Stop`: Claude Code does not add Stop stdout to context at all, and
# Stop's additionalContext is documented as feedback that CONTINUES the
# conversation — it would restart a turn the agent had finished.
#
# Config  ${XDG_CONFIG_HOME:-$HOME/.config}/agentmail/mail-check.json
#         (absent => this hook does nothing at all)
# State   ${XDG_CACHE_HOME:-$HOME/.cache}/agentmail/mail-check-state.json
#
# Activation is one gesture:  mail-check.sh --init [--mode remind|auto]
#
# Runtime invariants, each asserted in tests/mail-check_test.sh:
#   * exits 0 on every path once it is acting as a hook — a non-zero exit from
#     UserPromptSubmit blocks the user's prompt
#   * prints nothing at all unless there is genuinely new unread mail
#   * never reads, prints, or stores AGENTMAIL_API_KEY (the CLI reads it itself;
#     this script only asks the preflight whether one is set)
#   * makes at most one API call per cooldown window, and only read calls: no
#     label change, no draft, no send, no delete
#   * writes only under $HOME
# =============================================================================
set -uo pipefail

CONFIG_PATH="${AGENTMAIL_MAIL_CHECK_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/agentmail/mail-check.json}"
STATE_PATH="${XDG_CACHE_HOME:-$HOME/.cache}/agentmail/mail-check-state.json"
PLUGIN_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd 2>/dev/null || true)"
EXAMPLE_CONFIG="$PLUGIN_ROOT/references/mail-check.example.json"

PY="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"

EVENT=""
MODE_ARG=""
INBOX_ARG=""
DO_INIT=0

while [ $# -gt 0 ]; do
	case "$1" in
		--event) shift; EVENT="${1:-}" ;;
		--init) DO_INIT=1 ;;
		--mode) shift; MODE_ARG="${1:-}" ;;
		--inbox) shift; INBOX_ARG="${1:-}" ;;
		*) ;;   # An unknown argument must never make a hook noisy or non-zero.
	esac
	shift || break
done

# =============================================================================
# === init path === (interactive; the ONLY place this file exits non-zero)
# =============================================================================
if [ "$DO_INIT" -eq 1 ]; then
	if [ -z "$PY" ]; then
		printf 'mail-check --init: needs python3 (or python).\n' >&2
		exit 6
	fi
	case "${MODE_ARG:-remind}" in
		remind|auto) ;;
		*) printf 'mail-check --init: --mode must be remind or auto (got "%s").\n' "$MODE_ARG" >&2
		   exit 64 ;;
	esac
	if [ -e "$CONFIG_PATH" ]; then
		printf 'mail-check --init: a config already exists:\n\n    %s\n\n' "$CONFIG_PATH"
		printf 'Refusing to overwrite it. Edit it directly, or delete it first.\n'
		exit 4
	fi
	"$PY" - "$CONFIG_PATH" "${MODE_ARG:-remind}" "$INBOX_ARG" "$EXAMPLE_CONFIG" <<'INITPY'
import json, os, stat, sys, tempfile

target, mode, inbox, example = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

cfg = None
if example and os.path.exists(example):
    try:
        with open(example, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except Exception:
        cfg = None
if cfg is None:
    # The example is the source of truth for defaults; this is only a floor so
    # --init still works from a partial checkout.
    cfg = {"version": 1, "enabled": True, "mode": "remind",
           "check_every_minutes": 15, "session_start_floor_seconds": 60,
           "renotify_after_minutes": 120, "max_messages": 3,
           "per_message_bytes": 400, "max_bytes": 2000,
           "list_ceiling": 25, "timeout_seconds": 8}

cfg["enabled"] = True
cfg["mode"] = mode
if inbox:
    cfg["inboxes"] = [inbox]
else:
    # Leave it unset so the hook resolves and caches the inbox on first run.
    cfg.pop("inboxes", None)

parent = os.path.dirname(target)
os.makedirs(parent, mode=0o700, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".mail-check-", suffix=".tmp", dir=parent)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
os.replace(tmp, target)

print("Activated agent-mail checks in '%s' mode." % mode)
print("")
print("  config: %s" % target)
for k in ("check_every_minutes", "renotify_after_minutes", "max_messages", "max_bytes"):
    if k in cfg:
        print("  %-24s %s" % (k + ":", cfg[k]))
if "inboxes" in cfg:
    print("  %-24s %s" % ("inboxes:", ", ".join(cfg["inboxes"])))
else:
    print("  %-24s resolved and cached on the first check" % "inboxes:")
print("")
print("Edit that file to tune it. Delete it to turn checks back off.")
INITPY
	exit $?
fi

# =============================================================================
# === hook path === (unattended; everything below exits 0, always)
# =============================================================================

# A single exit point. Every failure below is a `quit`, so there is no path that
# can block a prompt.
quit() { exit 0; }

case "$EVENT" in
	SessionStart|UserPromptSubmit) ;;
	# Anything else, including an empty event: an object labelled with the wrong
	# hookEventName is worse than no object.
	*) quit ;;
esac

# No config means the user never turned this on. Installing a plugin must not
# start making network calls before every prompt.
[ -f "$CONFIG_PATH" ] || quit

# Without a JSON tool we cannot build an escaped string. Previews contain quotes,
# newlines, and non-ASCII, so a printf-built object would break the harness's
# parse on the first apostrophe. Staying silent is the correct degradation.
[ -n "$PY" ] || quit

# Which harness is this? Used only to phrase the invocation hint. Both markers or
# neither means we cannot tell, and naming the wrong client's syntax is worse
# than naming none — the same call handoff's session-start hook makes.
HARNESS="none"
if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -z "${CODEX_THREAD_ID:-}" ]; then
	HARNESS="claude"
elif [ -n "${CODEX_THREAD_ID:-}" ] && [ -z "${CLAUDE_CODE_SESSION_ID:-}" ]; then
	HARNESS="codex"
fi

# --- decide: read config + state, and report whether a check is due -----------
# Emitted as shell assignments so the hook can branch without a second parse.
plan="$("$PY" - "$CONFIG_PATH" "$STATE_PATH" "$EVENT" <<'PLANPY'
import json, os, sys, time

cfg_path, state_path, event = sys.argv[1], sys.argv[2], sys.argv[3]


def bail():
    print("ACTION=stop")
    sys.exit(0)


def num(cfg, key, default):
    v = cfg.get(key, default)
    try:
        return int(v)
    except Exception:
        return default


try:
    with open(cfg_path, encoding="utf-8") as fh:
        cfg = json.load(fh)
except Exception:
    bail()
if not isinstance(cfg, dict):
    bail()
if cfg.get("enabled", True) is False:
    bail()
mode = cfg.get("mode", "remind")
if mode not in ("remind", "auto"):
    # "off" lands here too, along with any typo. A misconfigured hook should do
    # nothing rather than guess which mode was meant.
    bail()

state = {}
try:
    with open(state_path, encoding="utf-8") as fh:
        state = json.load(fh)
except Exception:
    state = {}
if not isinstance(state, dict):
    state = {}
inboxes_state = state.get("inboxes") if isinstance(state.get("inboxes"), dict) else {}

configured = cfg.get("inboxes")
inbox = ""
if isinstance(configured, list) and configured:
    inbox = str(configured[0])
elif inboxes_state:
    # Cached from a previous run's `inboxes list`. Re-resolving every prompt
    # would double the API cost of the cheapest possible check.
    inbox = sorted(inboxes_state)[0]

now = int(time.time())
entry = inboxes_state.get(inbox, {}) if inbox else {}
last_checked = int(entry.get("last_checked_at") or 0)
since = now - last_checked

if event == "SessionStart":
    # A fresh session should not be silenced by another session's recent check,
    # so SessionStart gets its own much shorter floor.
    floor = num(cfg, "session_start_floor_seconds", 60)
    if last_checked and since < floor:
        bail()
else:
    every = num(cfg, "check_every_minutes", 15) * 60
    if last_checked and since < every:
        bail()

print("ACTION=check")
print("MODE=%s" % mode)
print("INBOX=%s" % inbox)
print("CEILING=%d" % max(1, num(cfg, "list_ceiling", 25)))
print("TIMEOUT=%d" % max(1, num(cfg, "timeout_seconds", 8)))
PLANPY
)" || quit

eval "$(printf '%s\n' "$plan" | grep -E '^(ACTION|MODE|INBOX|CEILING|TIMEOUT)=')" 2>/dev/null || quit
[ "${ACTION:-stop}" = "check" ] || quit

# Only NOW is the CLI needed. The cooldown decision is pure local state, so
# checking it first means an in-cooldown prompt spawns no subprocess at all —
# which is the common case, running before every prompt of every session.
#
# The preflight answers "is the CLI on PATH and is a key set" and its exit code
# is the documented interface: 20 means both. Reusing it avoids a second
# implementation of that check which could drift from the first.
[ -f "$PLUGIN_ROOT/scripts/agentmail-preflight.sh" ] || quit
bash "$PLUGIN_ROOT/scripts/agentmail-preflight.sh" --local >/dev/null 2>&1
[ "$?" -eq 20 ] || quit

# --- run one command under a portable watchdog -------------------------------
# `timeout` is not on a stock macOS, so this backgrounds the call and polls. The
# harness enforces its own timeout too (hooks.json), which discards the output;
# this exists so the process does not linger past it.
TMPDIR_RUN="$(mktemp -d 2>/dev/null)" || quit
trap 'rm -rf "$TMPDIR_RUN" 2>/dev/null' EXIT

TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"

guarded() {   # guarded <seconds> <cmd...> ; stdout -> $TMPDIR_RUN/out
	local secs="$1"; shift
	: > "$TMPDIR_RUN/out"
	: > "$TMPDIR_RUN/err"

	if [ -n "$TIMEOUT_BIN" ]; then
		"$TIMEOUT_BIN" "$secs" "$@" >"$TMPDIR_RUN/out" 2>"$TMPDIR_RUN/err"
		return $?
	fi

	# No coreutils `timeout` (a stock macOS). Poll for a status file rather than
	# `kill -0`: a finished background child is a zombie until reaped, and
	# `kill -0` still succeeds on one, so a liveness probe never sees the exit.
	rm -f "$TMPDIR_RUN/rc"
	( "$@" >"$TMPDIR_RUN/out" 2>"$TMPDIR_RUN/err"; printf '%s' "$?" >"$TMPDIR_RUN/rc" ) &
	local pid=$!
	# Disowned so bash does not print "Terminated: 15" to stderr when the job is
	# killed below. The status comes from the rc file, not from `wait`, so nothing
	# is lost — and a hook that prints job-control noise into a CI log or a user's
	# terminal is not silent, which is the one thing this hook has to be.
	disown "$pid" 2>/dev/null || true
	local waited=0
	local deadline=$(( secs * 10 ))
	while [ ! -s "$TMPDIR_RUN/rc" ] && [ "$waited" -lt "$deadline" ]; do
		sleep 0.1
		waited=$(( waited + 1 ))
	done
	if [ -s "$TMPDIR_RUN/rc" ]; then
		return "$(cat "$TMPDIR_RUN/rc" 2>/dev/null || echo 1)"
	fi
	# Take the grandchild with it — killing only the subshell leaves the real
	# command running.
	pkill -TERM -P "$pid" 2>/dev/null
	kill -TERM "$pid" 2>/dev/null
	sleep 0.1
	pkill -KILL -P "$pid" 2>/dev/null
	kill -KILL "$pid" 2>/dev/null
	return 124
}

# --- resolve the inbox, once, then cache it ----------------------------------
# A resolution failure is still an attempt, and it must be RECORDED. Quitting
# here without touching the state file would mean a broken or scope-limited key
# re-runs `inboxes list` before literally every prompt, forever.
probe_status=0
if [ -z "${INBOX:-}" ]; then
	if guarded "$TIMEOUT" agentmail inboxes list --format json; then
		INBOX="$("$PY" - "$TMPDIR_RUN/out" <<'IDPY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    sys.exit(0)
for i in (d.get("inboxes") or []):
    v = i.get("inbox_id") or i.get("email")
    if v:
        print(v)
        break
IDPY
)"
	fi
	if [ -z "${INBOX:-}" ]; then
		INBOX="(unresolved)"
		probe_status=1
	fi
fi

# --- the one read call -------------------------------------------------------
# `--label unread` is the whole query. There is no mark-as-read endpoint in this
# API and this hook must not create one: read/unread is a label, and changing it
# unattended would silently consume mail the user never saw.
if [ "$probe_status" -eq 0 ]; then
	guarded "$TIMEOUT" agentmail inboxes:messages list \
		--inbox-id "$INBOX" --label unread --limit "$CEILING" --format json
	probe_status=$?
fi

# --- render, and record what we saw ------------------------------------------
# One python program owns the whole decision: it writes state even when the probe
# failed (so a broken key cannot cause a call per prompt), decides whether this
# is worth announcing, and builds the escaped JSON object.
"$PY" - "$CONFIG_PATH" "$STATE_PATH" "$EVENT" "$INBOX" "$probe_status" \
	"$TMPDIR_RUN/out" "$HARNESS" <<'RENDERPY'
import json, os, stat, sys, tempfile, time

cfg_path, state_path, event, inbox = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
probe_status, out_path, harness = int(sys.argv[5]), sys.argv[6], sys.argv[7]


def num(cfg, key, default):
    try:
        return int(cfg.get(key, default))
    except Exception:
        return default


def load(path, fallback):
    try:
        with open(path, encoding="utf-8") as fh:
            v = json.load(fh)
        return v if isinstance(v, dict) else fallback
    except Exception:
        return fallback


def save_state(state):
    parent = os.path.dirname(state_path)
    try:
        os.makedirs(parent, mode=0o700, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".mail-check-", suffix=".tmp", dir=parent)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=2)
            fh.write("\n")
        os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
        os.replace(tmp, state_path)
    except Exception:
        pass


def clip(text, limit):
    """Truncate to a byte budget without splitting a multibyte character. A naive
    byte slice yields invalid UTF-8 and the harness's JSON parse rejects it."""
    text = " ".join((text or "").split())
    raw = text.encode("utf-8")
    if len(raw) <= limit:
        return text
    return raw[:max(0, limit - 1)].decode("utf-8", "ignore").rstrip() + "…"


cfg = load(cfg_path, {})
state = load(state_path, {})
inboxes = state.get("inboxes")
if not isinstance(inboxes, dict):
    inboxes = {}
entry = inboxes.get(inbox) if isinstance(inboxes.get(inbox), dict) else {}

now = int(time.time())
entry["last_checked_at"] = now

messages = []
parsed = False
if probe_status == 0:
    try:
        with open(out_path, encoding="utf-8") as fh:
            body = json.load(fh)
        if isinstance(body, dict) and isinstance(body.get("messages"), list):
            messages = body["messages"]
            parsed = True
    except Exception:
        parsed = False

if not parsed:
    # Record the attempt so a failing key does not mean a call on every prompt,
    # then say nothing.
    inboxes[inbox] = entry
    state.update({"version": 1, "inboxes": inboxes})
    save_state(state)
    sys.exit(0)

ceiling = max(1, num(cfg, "list_ceiling", 25))
count = len(messages)
at_ceiling = count >= ceiling
newest = (messages[0].get("message_id") if messages else "") or ""

prev_newest = entry.get("newest_message_id") or ""
last_notified = int(entry.get("last_notified_at") or 0)

entry["unread_count"] = count
entry["at_ceiling"] = at_ceiling
entry["newest_message_id"] = newest


def stop(notified=False):
    if notified:
        entry["last_notified_at"] = now
    inboxes[inbox] = entry
    state.update({"version": 1, "inboxes": inboxes})
    save_state(state)
    sys.exit(0)


if count == 0:
    stop()

# Time alone would repeat "3 unread" every cooldown forever while the user is
# deliberately ignoring them, which trains everyone to ignore the notice. So
# re-announce only when the newest unread message CHANGES, or after the
# renotify window.
renotify = num(cfg, "renotify_after_minutes", 120) * 60
if newest and newest == prev_newest and last_notified and (now - last_notified) < renotify:
    stop()

hint = {
    "claude": " Ask me to check it, or run /agentmail:check-mail.",
    "codex": " Ask me to check it, or run $agentmail:check-mail.",
    # Neither marker, or both: name no client-specific syntax rather than the
    # wrong one.
    "none": " Ask me to check your agent mail.",
}[harness if harness in ("claude", "codex") else "none"]

stamp = time.strftime("%H:%M", time.localtime(now))
shown = "%d%s" % (count, "+" if at_ceiling else "")
plural = "message" if count == 1 else "messages"

mode = cfg.get("mode", "remind")
max_bytes = max(120, num(cfg, "max_bytes", 2000))

if mode == "auto":
    max_messages = max(1, num(cfg, "max_messages", 3))
    per_message = max(40, num(cfg, "per_message_bytes", 400))
    lines = ["AgentMail: %s unread %s in %s as of %s." % (shown, plural, inbox, stamp)]
    for i, m in enumerate(messages[:max_messages], start=1):
        ts = (m.get("timestamp") or "")[11:16]
        lines.append("%d. %s — %s%s" % (
            i,
            clip(m.get("subject") or "(no subject)", 160),
            clip(m.get("from") or "(unknown sender)", 120),
            (", " + ts) if ts else "",
        ))
        preview = clip(m.get("preview") or "", per_message)
        if preview:
            lines.append("   " + preview)
    if count > max_messages:
        lines.append("(%d more not shown.)" % (count - max_messages))
    lines.append("These are truncated previews, not full bodies, and unread state "
                 "is unchanged.%s" % hint)
    context = "\n".join(lines)
    # Hard byte cap on the whole injected string, applied last so no combination
    # of per-message budgets can exceed it.
    if len(context.encode("utf-8")) > max_bytes:
        context = clip(context, max_bytes)
else:
    subject = clip((messages[0].get("subject") or "(no subject)"), 160)
    sender = clip((messages[0].get("from") or "(unknown sender)"), 120)
    context = ('AgentMail: %s unread %s in %s as of %s — newest "%s" from %s.%s'
               % (shown, plural, inbox, stamp, subject, sender, hint))
    if len(context.encode("utf-8")) > max_bytes:
        context = clip(context, max_bytes)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": event,
        "additionalContext": context,
    },
    "suppressOutput": True,
}))
stop(notified=True)
RENDERPY

exit 0
