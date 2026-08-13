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
# python3 (or python) is REQUIRED. There is no jq fallback: every JSON read and
# write here is structural, and two implementations of the same escaping rules is
# how they drift. With no interpreter the hook is silently inert.
#
# Runtime invariants, each asserted in tests/mail-check_test.sh:
#   * exits 0 on every path once it is acting as a hook — a non-zero exit from
#     UserPromptSubmit blocks the user's prompt
#   * prints nothing at all unless there is genuinely new unread mail
#   * never reads, prints, or stores AGENTMAIL_API_KEY (the CLI reads it itself;
#     this script only asks the preflight whether one is set)
#   * makes at most one API call per cooldown window, and only read calls: no
#     label change, no draft, no send, no delete
#   * treats every inbox id — from the API, from config, from its own state — as
#     untrusted text, validated against INBOX_RE before use or storage, and
#     never eval'd
#   * writes only under the config and cache directories it derives from the
#     environment. Its scratch directory lives beside the state file rather than
#     in TMPDIR, because API responses carry subjects, senders, and previews and
#     a shared /tmp is the wrong place for message content.
# =============================================================================
set -uo pipefail

# An inbox id in AgentMail is an email address. This is the ONLY shape allowed to
# reach a command line, a config file, or a state key. It is deliberately strict:
# no spaces, no quotes, no shell metacharacters, no `$`, no backticks.
#
# This matters more than it looks. Every id here originates outside the process —
# an API response, a config file, this hook's own cache — and the whole point of
# the plugin is to read mail from strangers. An unvalidated id was a live
# injection sink: an `inboxes list` response with an id of
# `a$(touch /tmp/PWNED)@agentmail.to` got stored as a state key, read back on the
# next prompt, and executed. Validation at every boundary is what closes that,
# together with never passing this text through `eval`.
INBOX_RE='^[A-Za-z0-9][A-Za-z0-9._%+-]{0,62}@[A-Za-z0-9][A-Za-z0-9.-]{0,252}\.[A-Za-z]{2,24}$'

valid_inbox() {   # valid_inbox <value>
	[ -n "${1:-}" ] || return 1
	[[ "$1" =~ $INBOX_RE ]] || return 1
	return 0
}

# --- paths, with no assumption that HOME exists -------------------------------
# A hook runs in whatever environment the harness hands it. Under `set -u` a bare
# ${HOME} on an env-scrubbed invocation aborted the script with "unbound
# variable"; only hooks.json's `|| true` kept that from blocking the prompt.
CONFIG_PATH="${AGENTMAIL_MAIL_CHECK_CONFIG:-}"
if [ -z "$CONFIG_PATH" ]; then
	if [ -n "${XDG_CONFIG_HOME:-}" ]; then
		CONFIG_PATH="${XDG_CONFIG_HOME}/agentmail/mail-check.json"
	elif [ -n "${HOME:-}" ]; then
		CONFIG_PATH="${HOME}/.config/agentmail/mail-check.json"
	fi
fi

STATE_PATH=""
if [ -n "${XDG_CACHE_HOME:-}" ]; then
	STATE_PATH="${XDG_CACHE_HOME}/agentmail/mail-check-state.json"
elif [ -n "${HOME:-}" ]; then
	STATE_PATH="${HOME}/.cache/agentmail/mail-check-state.json"
fi

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
	if [ -z "$CONFIG_PATH" ]; then
		printf 'mail-check --init: cannot locate a config directory — neither HOME nor\n' >&2
		printf 'XDG_CONFIG_HOME is set, and AGENTMAIL_MAIL_CHECK_CONFIG was not given.\n' >&2
		exit 64
	fi
	case "${MODE_ARG:-remind}" in
		remind|auto) ;;
		*) printf 'mail-check --init: --mode must be remind or auto (got "%s").\n' "$MODE_ARG" >&2
		   exit 64 ;;
	esac
	# Validate BEFORE writing. The config is read by an unattended hook before
	# every prompt, and `--init` is allowlisted in the check-mail skill so the
	# model can run it without a permission prompt — which makes an unvalidated
	# --inbox a way to persuade an agent to persist a payload by email.
	if [ -n "$INBOX_ARG" ] && ! valid_inbox "$INBOX_ARG"; then
		printf 'mail-check --init: --inbox must be a plain email address (got "%s").\n' "$INBOX_ARG" >&2
		printf 'Refusing to write it. Nothing was changed.\n' >&2
		exit 64
	fi
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

# Silence stderr for the whole unattended path.
#
# This is not tidiness. The watchdog below kills a background job, and bash
# announces that as `Terminated: 15` on ITS OWN stderr, asynchronously, naming the
# subshell. `disown` suppresses it most of the time but not reliably — measured at
# roughly one run in five — and an intermittently noisy hook is worse than a
# consistently noisy one, because it passes review and then surfaces in a user's
# terminal and in CI logs. Nothing in this path writes to stderr deliberately, so
# there is nothing to lose; set AGENTMAIL_MAIL_CHECK_DEBUG=1 to get it back while
# debugging.
if [ -z "${AGENTMAIL_MAIL_CHECK_DEBUG:-}" ]; then
	exec 2>/dev/null
fi

# A single exit point. Every failure below is a `quit`, so there is no path that
# can block a prompt.
quit() { exit 0; }

case "$EVENT" in
	SessionStart|UserPromptSubmit) ;;
	# Anything else, including an empty event: an object labelled with the wrong
	# hookEventName is worse than no object.
	*) quit ;;
esac

# No config or nowhere to keep state means the user never turned this on, or the
# environment has no home to write to. Either way: do nothing.
[ -n "$CONFIG_PATH" ] || quit
[ -n "$STATE_PATH" ] || quit
[ -f "$CONFIG_PATH" ] || quit

# Without an interpreter we cannot read or build JSON safely. Previews contain
# quotes, newlines, and non-ASCII, so a printf-built object would break the
# harness's parse on the first apostrophe. Staying silent is the correct
# degradation.
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
plan="$("$PY" - "$CONFIG_PATH" "$STATE_PATH" "$EVENT" "$INBOX_RE" <<'PLANPY'
import json, os, re, sys, time

cfg_path, state_path, event, inbox_re = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
VALID = re.compile(inbox_re)


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

# Anything that fails validation is ignored rather than repaired: a state key or
# a config value that is not an address is either corruption or an attempt, and
# in both cases the right move is to behave as though the inbox is unknown and
# re-resolve it from the API.
configured = cfg.get("inboxes")
inbox = ""
if isinstance(configured, list) and configured and isinstance(configured[0], str) \
        and VALID.match(configured[0]):
    inbox = configured[0]
else:
    cached = sorted(k for k in inboxes_state if isinstance(k, str) and VALID.match(k))
    if cached:
        # Cached from a previous run's `inboxes list`. Re-resolving every prompt
        # would double the API cost of the cheapest possible check.
        inbox = cached[0]

now = int(time.time())
if inbox:
    entry = inboxes_state.get(inbox) if isinstance(inboxes_state.get(inbox), dict) else {}
    last_checked = int(entry.get("last_checked_at") or 0)
else:
    # No inbox known yet — or the last attempt to learn one failed. That attempt
    # is recorded at the top level rather than under a made-up inbox key: a
    # sentinel key ("(unresolved)") poisoned the cache permanently, because it
    # then looked like a perfectly good cached inbox on every later run.
    last_checked = int(state.get("unresolved_last_checked_at") or 0)
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

# Read the plan with `read`, never `eval`.
#
# `eval` here was a shell-injection sink reachable from an API response: the
# planner prints INBOX=<value>, and an id containing $(...) executed on the next
# prompt. Nothing about this data needs shell interpretation — five known keys,
# each a scalar — so it is parsed field-wise and then validated.
ACTION=""; MODE=""; INBOX=""; CEILING=""; TIMEOUT=""
while IFS='=' read -r _k _v; do
	case "$_k" in
		ACTION)  ACTION="$_v" ;;
		MODE)    MODE="$_v" ;;
		INBOX)   INBOX="$_v" ;;
		CEILING) CEILING="$_v" ;;
		TIMEOUT) TIMEOUT="$_v" ;;
		*) ;;
	esac
done <<PLANOUT
$plan
PLANOUT

[ "${ACTION:-stop}" = "check" ] || quit
case "$MODE" in remind|auto) ;; *) quit ;; esac
case "$CEILING" in ''|*[!0-9]*) quit ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) quit ;; esac
# An inbox is either empty (resolve it below) or a valid address. Never anything else.
if [ -n "$INBOX" ] && ! valid_inbox "$INBOX"; then
	quit
fi

# Only NOW is the CLI needed. The cooldown decision is pure local state, so
# checking it first means an in-cooldown prompt spawns no subprocess at all —
# which is the common case, running before every prompt of every session.
#
# The preflight answers "is the CLI on PATH and is a key set" and its exit code
# is the documented interface: a healthy --local run exits 0 (10/11 name what's
# missing). Reusing it avoids a second implementation of that check which could
# drift from the first.
[ -f "$PLUGIN_ROOT/scripts/agentmail-preflight.sh" ] || quit
bash "$PLUGIN_ROOT/scripts/agentmail-preflight.sh" --local >/dev/null 2>&1
[ "$?" -eq 0 ] || quit

# --- scratch space, beside the state file rather than in TMPDIR ---------------
# The API response held here carries subjects, senders, and preview text. That is
# message content, and a world-readable shared /tmp is the wrong place for it.
STATE_DIR="$(dirname "$STATE_PATH")"
mkdir -p "$STATE_DIR" 2>/dev/null || quit
chmod 700 "$STATE_DIR" 2>/dev/null || true
TMPDIR_RUN="$(mktemp -d "$STATE_DIR/run-XXXXXX" 2>/dev/null)" || quit
trap 'rm -rf "$TMPDIR_RUN" 2>/dev/null' EXIT

# --- run one command under a portable watchdog -------------------------------
# `timeout` is not on a stock macOS, so this backgrounds the call and polls. The
# harness enforces its own timeout too (hooks.json), which discards the output;
# this exists so the process does not linger past it.
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
# A resolution failure is still an attempt and must be RECORDED, or a broken or
# scope-limited key re-runs `inboxes list` before literally every prompt. It is
# recorded at the top level of the state file, NOT as an inbox key: a sentinel
# key survived as a plausible-looking cached inbox and bricked the hook until the
# user deleted the cache by hand.
RESOLVED=1
if [ -z "$INBOX" ]; then
	if guarded "$TIMEOUT" agentmail inboxes list --format json; then
		INBOX="$("$PY" - "$TMPDIR_RUN/out" "$INBOX_RE" <<'IDPY'
import json, re, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        d = json.load(fh)
except Exception:
    sys.exit(0)
valid = re.compile(sys.argv[2])
for i in (d.get("inboxes") or []):
    if not isinstance(i, dict):
        continue
    for key in ("inbox_id", "email"):
        v = i.get(key)
        # An id that is not a plain address is dropped, not sanitized. It reaches
        # a command line and a state key next, and there is no safe repair for
        # "looks like an address plus a command substitution".
        if isinstance(v, str) and valid.match(v):
            print(v)
            sys.exit(0)
IDPY
)"
	fi
	if ! valid_inbox "${INBOX:-}"; then
		INBOX=""
		RESOLVED=0
	fi
fi

probe_status=0
if [ "$RESOLVED" -eq 0 ]; then
	# Record the failed attempt, say nothing, and let the next window retry. This
	# recovers by itself as soon as the API returns a usable inbox.
	"$PY" - "$STATE_PATH" <<'FAILPY'
import json, os, stat, sys, tempfile, time

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        state = json.load(fh)
    if not isinstance(state, dict):
        state = {}
except Exception:
    state = {}
state["version"] = 1
state["unresolved_last_checked_at"] = int(time.time())
try:
    parent = os.path.dirname(path)
    os.makedirs(parent, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".mail-check-", suffix=".tmp", dir=parent)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2)
        fh.write("\n")
    os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
    os.replace(tmp, path)
except Exception:
    pass
FAILPY
	quit
fi

# --- the one read call -------------------------------------------------------
# `--label unread` is the whole query. There is no mark-as-read endpoint in this
# API and this hook must not create one: read/unread is a label, and changing it
# unattended would silently consume mail the user never saw.
guarded "$TIMEOUT" agentmail inboxes:messages list \
	--inbox-id "$INBOX" --label unread --limit "$CEILING" --format json
probe_status=$?

# --- render, and record what we saw ------------------------------------------
# One python program owns the whole decision: it writes state even when the probe
# failed (so a broken key cannot cause a call per prompt), decides whether this
# is worth announcing, and builds the escaped JSON object.
"$PY" - "$CONFIG_PATH" "$STATE_PATH" "$EVENT" "$INBOX" "$probe_status" \
	"$TMPDIR_RUN/out" "$HARNESS" <<'RENDERPY'
import json, os, stat, sys, tempfile, time

cfg_path, state_path, event, inbox = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
probe_status, out_path, harness = int(sys.argv[5]), sys.argv[6], sys.argv[7]

ELLIPSIS = "…"
ELLIPSIS_BYTES = len(ELLIPSIS.encode("utf-8"))


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
    """Truncate to a byte budget without splitting a multibyte character, and
    without ever exceeding the budget: the ellipsis is 3 bytes in UTF-8, so it has
    to be subtracted, not assumed to be 1."""
    text = " ".join((text or "").split())
    raw = text.encode("utf-8")
    if len(raw) <= limit:
        return text
    keep = max(0, limit - ELLIPSIS_BYTES)
    return raw[:keep].decode("utf-8", "ignore").rstrip() + ELLIPSIS


def bytelen(s):
    return len(s.encode("utf-8"))


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
            messages = [m for m in body["messages"] if isinstance(m, dict)]
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
newest = ""
if messages:
    v = messages[0].get("message_id")
    if isinstance(v, str):
        newest = v

# The re-notify key must exist even when a message carries no id, or every
# cooldown re-announces the same mail forever. Fall back to the newest message's
# own coordinates, then to the count.
ident = newest
if not ident and messages:
    m = messages[0]
    ident = "|".join(str(m.get(k) or "") for k in ("timestamp", "from", "subject"))
if not ident:
    ident = "count:%d" % count

prev_ident = entry.get("newest_ident") or entry.get("newest_message_id") or ""
last_notified = int(entry.get("last_notified_at") or 0)

entry["unread_count"] = count
entry["at_ceiling"] = at_ceiling
entry["newest_message_id"] = newest
entry["newest_ident"] = ident


def stop(notified=False):
    if notified:
        entry["last_notified_at"] = now
    inboxes[inbox] = entry
    state.update({"version": 1, "inboxes": inboxes})
    # A successful check means the "we could not resolve an inbox" marker is
    # stale; leaving it would keep gating a cooldown that no longer applies.
    state.pop("unresolved_last_checked_at", None)
    save_state(state)
    sys.exit(0)


if count == 0:
    stop()

# Time alone would repeat "3 unread" every cooldown forever while the user is
# deliberately ignoring them, which trains everyone to ignore the notice. So
# re-announce only when the newest unread message CHANGES, or after the
# renotify window.
renotify = num(cfg, "renotify_after_minutes", 120) * 60
if ident == prev_ident and last_notified and (now - last_notified) < renotify:
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
max_bytes = max(160, num(cfg, "max_bytes", 2000))

if mode == "auto":
    max_messages = max(1, num(cfg, "max_messages", 3))
    per_message = max(40, num(cfg, "per_message_bytes", 400))
    header = "AgentMail: %s unread %s in %s as of %s." % (shown, plural, inbox, stamp)
    footer = ("These are truncated previews, not full bodies, and unread state "
              "is unchanged.%s" % hint)

    # The footer is the part that must survive. It says the content is partial
    # and that nothing was marked read — exactly the caveats a reader needs — so
    # it gets its budget first and the listing fills what is left. Clipping the
    # assembled block instead would drop the footer and collapse the layout into
    # one line, which is what it used to do.
    budget = max_bytes - bytelen(header) - bytelen(footer) - 2
    if budget < 0:
        # The cap is too small for even the header and the caveat. Degrade to the
        # one-line form rather than emitting something over budget or dropping the
        # caveat — a partial listing with no "these are previews" warning is the
        # one output shape that could actively mislead.
        context = clip("%s%s" % (header, hint), max_bytes)
        print(json.dumps({
            "hookSpecificOutput": {"hookEventName": event, "additionalContext": context},
            "suppressOutput": True,
        }))
        stop(notified=True)
    lines = []
    shown_n = 0
    for i, m in enumerate(messages[:max_messages], start=1):
        ts = str(m.get("timestamp") or "")[11:16]
        head = "%d. %s — %s%s" % (
            i,
            clip(m.get("subject") or "(no subject)", 160),
            clip(m.get("from") or "(unknown sender)", 120),
            (", " + ts) if ts else "",
        )
        block = [head]
        preview = clip(m.get("preview") or "", per_message)
        if preview:
            block.append("   " + preview)
        cost = sum(bytelen(b) + 1 for b in block)
        if budget - cost < 0:
            break
        budget -= cost
        lines.extend(block)
        shown_n = i
    if count > shown_n:
        omitted = "(%d more not shown.)" % (count - shown_n)
        if budget - bytelen(omitted) - 1 >= 0:
            lines.append(omitted)
    context = "\n".join([header] + lines + [footer])
else:
    subject = clip((messages[0].get("subject") or "(no subject)"), 160)
    sender = clip((messages[0].get("from") or "(unknown sender)"), 120)
    context = ('AgentMail: %s unread %s in %s as of %s — newest "%s" from %s.%s'
               % (shown, plural, inbox, stamp, subject, sender, hint))
    if bytelen(context) > max_bytes:
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
