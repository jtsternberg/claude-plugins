#!/usr/bin/env python3
"""Report how much runway is left: Claude subscription quota and context window.

Quota comes from the endpoint the /usage command uses
(GET https://api.anthropic.com/api/oauth/usage), authorised with the OAuth token
Claude Code stores in the macOS Keychain or ~/.claude/.credentials.json.

Context usage is read from the session transcript under ~/.claude/projects/<slug>/,
using the token counts the API returned on the most recent assistant message.

Modes:
  (default)          full human-readable report
  --brief            one or two lines, for SessionStart / UserPromptSubmit hooks
  --json             raw data plus the verdict
  --throttle N       in --brief mode, stay silent if this session's check under N seconds
                     old said everything was fine, or that every tight quota bucket is
                     already armed or acknowledged (skips the network call entirely)
  --armed WAKE       record that this session armed its quota wake-up for WAKE
                     (YYYY-MM-DD HH:MM); pair with --bucket LABEL to name the bucket
  --ack [WAKE]       record that this session carries on without a wake-up for --bucket LABEL,
                     quiet until WAKE passes (default: that bucket's wake from the last check)
  --bucket LABEL     with --armed or --ack, the quota bucket it is for
  --record-model     cache the model from the hook payload and exit silently
  --session ID       session id (defaults to $CLAUDE_CODE_SESSION_ID)
  --cwd PATH         project path for the transcript
  --limit N          context window size override
  --no-self-install  never wire or repair hooks in ~/.claude/settings.json
  --hooks-version N  set by the installer in hook commands; not for manual use

A run without --brief wires missing or outdated hooks into ~/.claude/settings.json, unless
--no-self-install is passed or this script sits in a plugin whose hooks/hooks.json
already registers it. In a standalone copy, the SessionStart hook prints a `runway SETUP:`
line while the settings-file hooks are missing or outdated.
"""

import argparse
import functools
import importlib.util
import json
import os
import re
import select
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
SCRIPT = Path(__file__).resolve()
INSTALLER = SCRIPT.parent / "install-hooks.py"
KEYCHAIN_SERVICE = "Claude Code-credentials"
CLAUDE_DIR = Path.home() / ".claude"
STATE_FILE = CLAUDE_DIR / "runway" / "state.json"
LARGE_CONTEXT_LIMIT = 1_000_000
SMALL_CONTEXT_LIMIT = 200_000
DEFAULT_CONTEXT_LIMIT = LARGE_CONTEXT_LIMIT

# Model families whose window is 200k. Everything else is assumed to be 1M,
# which matches the current Claude Code defaults.
SMALL_CONTEXT_MODELS = ("haiku", "claude-3", "claude-2")
MODEL_CACHE_SIZE = 20
# Bucket key for an --armed run that named no bucket: it matches any bucket whose wake
# time is within ANY_BUCKET_SLACK of the one recorded.
ANY_BUCKET = "*"
ANY_BUCKET_SLACK = timedelta(minutes=10)
WAKE_FORMAT = "%Y-%m-%d %H:%M"
RESTART_PROMPT = "runway: quota has reset, carry on with the task you paused"
THROTTLE_MARKER_TTL = 24 * 3600

# Percent-used thresholds. Override any of them with RUNWAY_<SUBJECT>_<LEVEL>,
# e.g. RUNWAY_CONTEXT_WRAP_UP=85 or RUNWAY_QUOTA_STOP=99.
THRESHOLDS = {
    "context": {"notice": 80, "wrap_up": 90, "stop": 95},
    "quota": {"notice": 90, "wrap_up": 95, "stop": 98},
}
RESET_SOON_MINUTES = int(os.environ.get("RUNWAY_RESET_SOON_MINUTES") or 10)
LEVELS = ["ok", "notice", "wrap_up", "stop"]


def thresholds_for(subject):
    """Return the threshold map for a subject, applying RUNWAY_* env overrides."""
    values = dict(THRESHOLDS[subject])
    for level in values:
        override = os.environ.get(f"RUNWAY_{subject.upper()}_{level.upper()}")
        if override and override.strip().isdigit():
            values[level] = int(override)
    return values


def level_for(subject, percent):
    """Map a percent-used figure onto ok / notice / wrap_up / stop."""
    values = thresholds_for(subject)
    for level in ("stop", "wrap_up", "notice"):
        if percent >= values[level]:
            return level
    return "ok"


def bucket_applies(bucket, model):
    """True when the running model draws from this quota bucket.

    A bucket with no model scope meters everything, so it always applies. For a scoped
    one the API's is_active flag cannot answer this: it reports a Fable weekly bucket as
    active while Opus is running, so the scope name is matched against the model id
    instead. With no model to match, is_active is the only evidence left.
    """
    scope = bucket.get("scope_model")
    if not scope:
        return True
    if not model:
        return bucket.get("is_active", True)
    name = re.sub(r"[^a-z0-9]+", "-", scope.lower()).strip("-")
    pattern = rf"(?:^|-){re.escape(name)}"
    if re.search(r"\d", name):
        pattern += r"(?!-\d{1,2}(?!\d))"  # "Opus 5" must not match claude-opus-5-5
    return re.search(pattern, model.lower()) is not None


def apply_model(quota, model):
    """Mark which buckets the running model uses and set the quota level from those only."""
    for bucket in quota["buckets"]:
        bucket["applies"] = bucket_applies(bucket, model)
    quota["level"] = worst([b["level"] for b in quota["buckets"] if b["applies"]])


def worst(levels):
    """Return the most severe level in a list."""
    return max(levels, key=LEVELS.index) if levels else "ok"


def read_credentials():
    """Return the parsed Claude Code credential blob, or None when unavailable."""
    if sys.platform == "darwin":
        try:
            raw = subprocess.run(
                ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
                capture_output=True, text=True, timeout=10,
            ).stdout.strip()
            if raw:
                return json.loads(raw)
        except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
            pass
    try:
        return json.loads((CLAUDE_DIR / ".credentials.json").read_text())
    except (OSError, json.JSONDecodeError):
        return None


def fetch_quota(token):
    """Call the OAuth usage endpoint and return its JSON payload."""
    request = urllib.request.Request(USAGE_URL, headers={
        "Authorization": f"Bearer {token}",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-cli/runway (external, cli)",
        "Accept": "application/json",
    })
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read().decode())


def minutes_until(stamp):
    """Return whole minutes from now until an ISO timestamp, or None."""
    if not stamp:
        return None
    when = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    return int((when - datetime.now(timezone.utc)).total_seconds() // 60)


def local_clock(stamp):
    """Format an ISO timestamp as local HH:MM."""
    if not stamp:
        return "n/a"
    return f"{datetime.fromisoformat(stamp.replace('Z', '+00:00')).astimezone():%H:%M}"


def resume_cron(stamp, pad_minutes=2):
    """Build a one-shot local-time cron expression for just after a reset timestamp."""
    if not stamp:
        return None
    when = datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone()
    when += timedelta(minutes=pad_minutes)
    return f"{when.minute} {when.hour} {when.day} {when.month} *"


def wake_clock(stamp, pad_minutes=2):
    """Local 'YYYY-MM-DD HH:MM' just after a reset timestamp, the time to hand `until`."""
    if not stamp:
        return None
    when = datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone()
    return f"{when + timedelta(minutes=pad_minutes):{WAKE_FORMAT}}"


def stop_work_enabled():
    """RUNWAY_STOP_WORK opts back into pausing at a quota threshold instead of working on."""
    return os.environ.get("RUNWAY_STOP_WORK", "").strip().lower() not in ("", "0", "false", "no")


def quota_report(oauth):
    """Turn the usage payload into every bucket that reports a percent, plus a verdict level."""
    payload = fetch_quota(oauth["accessToken"])
    buckets = []
    for raw in payload.get("limits", []):
        if raw.get("percent") is None:
            continue
        scope = ((raw.get("scope") or {}).get("model") or {}).get("display_name")
        buckets.append({
            "kind": raw.get("kind"),
            "group": raw.get("group"),
            "label": f"{raw.get('kind')}:{scope}" if scope else raw.get("kind"),
            "scope_model": scope,
            "percent": raw["percent"],
            "resets_at": raw.get("resets_at"),
            "resets_local": local_clock(raw.get("resets_at")),
            "minutes_to_reset": minutes_until(raw.get("resets_at")),
            "resume_cron": resume_cron(raw.get("resets_at")),
            "wake_at": wake_clock(raw.get("resets_at")),
            "is_active": raw.get("is_active", True),
            "level": level_for("quota", raw["percent"]),
        })
    session = next((b for b in buckets if b["group"] == "session"), None)
    return {
        "plan": oauth.get("subscriptionType"),
        "tier": oauth.get("rateLimitTier"),
        "buckets": buckets,
        "session": session,
        "level": worst([b["level"] for b in buckets]),
    }


def project_slug(cwd):
    """Return the ~/.claude/projects directory name Claude Code uses for a path."""
    return re.sub(r"[^A-Za-z0-9]", "-", str(cwd))


def find_transcript(session_id, cwd):
    """Locate the transcript for a session id, or the newest one for this cwd when there is none."""
    directory = CLAUDE_DIR / "projects" / project_slug(cwd)
    if session_id:
        named = directory / f"{session_id}.jsonl"
        if named.exists():
            return named
        elsewhere = sorted((CLAUDE_DIR / "projects").glob(f"*/{session_id}.jsonl"),
                           key=lambda p: p.stat().st_mtime, reverse=True)
        # another session's transcript would report its context as ours
        return elsewhere[0] if elsewhere else None
    logs = sorted(directory.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    return logs[0] if logs else None


def tail_lines(path, budget=4_000_000):
    """Yield the file's lines from last to first, reading at most `budget` bytes."""
    size = path.stat().st_size
    with path.open("rb") as handle:
        handle.seek(max(0, size - budget))
        chunk = handle.read()
    for line in reversed(chunk.split(b"\n")):
        if line.strip():
            yield line


def last_token_counts(path):
    """Return (tokens, model, breakdown) from the newest assistant token counts."""
    for line in tail_lines(path):
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        message = entry.get("message") or {}
        usage = message.get("usage")
        if entry.get("type") != "assistant" or not usage:
            continue
        breakdown = {
            "input": usage.get("input_tokens", 0),
            "cache_read": usage.get("cache_read_input_tokens", 0),
            "cache_creation": usage.get("cache_creation_input_tokens", 0),
            "output": usage.get("output_tokens", 0),
        }
        tokens = breakdown["input"] + breakdown["cache_read"] + breakdown["cache_creation"]
        return tokens, message.get("model"), breakdown
    return None, None, None


def hook_payload(wait=0.5):
    """Return the hook's stdin JSON, or an empty dict when not running as a hook."""
    try:
        if sys.stdin is None or sys.stdin.isatty():
            return {}
    except (OSError, ValueError):
        return {}
    try:
        if not select.select([sys.stdin], [], [], wait)[0]:
            return {}
    except (OSError, ValueError):
        pass  # not selectable: read it straight rather than treating it as empty
    try:
        raw = sys.stdin.read()
    except (OSError, ValueError):
        return {}
    try:
        payload = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return {}
    return payload if isinstance(payload, dict) else {}


def reported_model(payload):
    """Pull the resolved model id out of a hook payload, if it carries one."""
    for key in ("model", "to_model"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def remember_model(session_id, model):
    """Cache a session's resolved model id so later hook events can read it back."""
    if not session_id or not model:
        return
    state = read_state()
    models = state.get("models")
    models = models if isinstance(models, dict) else {}
    if models.get(session_id) == model:
        return
    models[session_id] = model
    state["models"] = dict(list(models.items())[-MODEL_CACHE_SIZE:])
    write_raw_state(state)


def remembered_model(session_id):
    """Return the resolved model id cached for a session, or None."""
    models = read_state().get("models")
    if isinstance(models, dict) and session_id:
        return models.get(session_id)
    return None


def record_armed(session_id, wake, label=None, ack=False):
    """Remember the wake a session armed (or acknowledged) for one bucket, so hooks stop asking.

    Keyed per bucket because the 5-hour and a weekly bucket can be tight at once; a single
    slot per session would flip between their wake times and re-request each in turn. An
    acknowledgement is stored as {"ack": wake} so the report can tell it from a real arm.
    """
    if not session_id or not wake:
        return
    state = read_state()
    armed = state.get("armed")
    armed = armed if isinstance(armed, dict) else {}
    wakes = armed.pop(session_id, None)
    wakes = wakes if isinstance(wakes, dict) else {}
    wakes[label or ANY_BUCKET] = {"ack": wake} if ack else wake
    armed[session_id] = wakes
    state["armed"] = dict(list(armed.items())[-MODEL_CACHE_SIZE:])
    write_raw_state(state)


def armed_wakes(session_id):
    """Return the {bucket label: wake time} map this session armed, or {}."""
    armed = read_state().get("armed")
    if isinstance(armed, dict) and session_id:
        wakes = armed.get(session_id)
        if isinstance(wakes, dict):
            return wakes
    return {}


def last_wake(label):
    """The wake time the most recent check computed for a bucket, or None."""
    wakes = read_state().get("wakes")
    return wakes.get(label) if isinstance(wakes, dict) and label else None


def parse_wake(value):
    """Read a recorded local wake time, or None when it is not one."""
    try:
        return datetime.strptime(str(value), WAKE_FORMAT)
    except ValueError:
        return None


def armed_entry(bucket, armed):
    """Return ("armed" | "ack", recorded wake) when this bucket is covered, else None.

    A record for the bucket's own label counts until its wake passes, not on an exact match,
    because resets_at jitters across minute boundaries between API calls. An unlabelled record
    could belong to any bucket, so it must also sit near this bucket's own wake.
    """
    now = datetime.now()
    armed = armed or {}
    for key in (bucket.get("label"), ANY_BUCKET):
        entry = armed.get(key)
        kind, wake = ("ack", entry.get("ack")) if isinstance(entry, dict) else ("armed", entry)
        when = parse_wake(wake)
        if not when or when <= now:
            continue
        if key == ANY_BUCKET:
            target = parse_wake(bucket.get("wake_at"))
            if not target or abs(when - target) > ANY_BUCKET_SLACK:
                continue
        return kind, wake
    return None


def is_armed(bucket, armed):
    """True when this bucket's wake is armed or acknowledged and has not fired yet."""
    return armed_entry(bucket, armed) is not None


def record_mark(bucket, flag):
    """The command that records an --armed or --ack, ready to run from any directory."""
    wake = bucket.get("wake_at") or "<that time>"
    return (f'`python3 "{SCRIPT}" {flag} "{wake}" '
            f'--bucket {shlex.quote(str(bucket["label"]))}`')


def env_context_limit():
    """Return the window size Claude Code's own override env var declares, or 0."""
    raw = os.environ.get("CLAUDE_CODE_MAX_CONTEXT_TOKENS") or ""
    return int(raw) if raw.strip().isdigit() else 0


def limit_for_model(model):
    """Return the context window a model id implies, or None when unrecognised."""
    name = (model or "").lower()
    if not name:
        return None
    if "1m" in name:
        return LARGE_CONTEXT_LIMIT
    if any(family in name for family in SMALL_CONTEXT_MODELS):
        return SMALL_CONTEXT_LIMIT
    return LARGE_CONTEXT_LIMIT


def configured_context_limit():
    """Read the context limit implied by the model set in the settings files."""
    for name in ("settings.local.json", "settings.json"):
        try:
            model = json.loads((CLAUDE_DIR / name).read_text()).get("model") or ""
        except (OSError, json.JSONDecodeError):
            continue
        limit = limit_for_model(model)
        if limit:
            return limit
    return None


def resolve_context_limit(override, tokens, model=None):
    """Pick the context window size, widening it if the session already exceeds it."""
    limit = override or int(os.environ.get("RUNWAY_CONTEXT_LIMIT") or 0) \
        or env_context_limit() or limit_for_model(model) \
        or configured_context_limit() or DEFAULT_CONTEXT_LIMIT
    return LARGE_CONTEXT_LIMIT if tokens and tokens > limit else limit


def context_report(transcript, limit_override, hook_model=None):
    """Turn a transcript's newest token counts into a context verdict."""
    tokens, api_model, breakdown = last_token_counts(transcript)
    if tokens is None:
        return None
    model = hook_model or remembered_model(transcript.stem) or api_model
    limit = resolve_context_limit(limit_override, tokens, model)
    percent = round(tokens / limit * 100, 1)
    return {
        "session": transcript.stem,
        "transcript": str(transcript),
        "model": model,
        "api_model": api_model,
        "tokens": tokens,
        "limit": limit,
        "percent": percent,
        "remaining": limit - tokens,
        "breakdown": breakdown,
        "level": level_for("context", percent),
    }


def keep_working_action(head, when, bucket, armed=None):
    """Default quota action: keep working, with the `until` wake armed before the 429 lands.

    A rate-limited request has no turn left to arm anything, so the wake goes up at
    wrap_up/stop while quota remains. It costs nothing while it waits.
    """
    base = f"{head}, refills {when}: keep working normally."
    if bucket["level"] == "notice":
        return base
    entry = armed_entry(bucket, armed)
    if entry and entry[0] == "armed":
        return (f"{base} The wake-up for {entry[1]} is already armed in this session: do not arm "
                "another.")
    if entry:
        return f"{base} Already acknowledged in this session without a wake-up: carry on."
    target = bucket.get("wake_at") or "the reset time from `runway.py --json`"
    payload = ("with a self-contained payload (the task, its resume point, and 'if the work is "
               "already finished, say so in one line and stop')")
    if bucket.get("group") != "session":
        return (f"{base} This reset is days away, so arming is your call. If the user wants the "
                f"session to wait that long, arm delayed-work:until for {target} {payload} and "
                f"run {record_mark(bucket, '--armed')}. Otherwise run "
                f"{record_mark(bucket, '--ack')}, say when it resets, and carry on.")
    return (f"{base} Now, once: arm delayed-work:until for {target} {payload}, run "
            f"{record_mark(bucket, '--armed')}, then carry on. If a request is 429ed, stop and "
            "wait for the wake line. Set RUNWAY_STOP_WORK=1 to pause until the reset instead.")


def all_armed(context, quota, armed):
    """True when every tight quota bucket is armed or acknowledged and the context is fine.

    Default mode only. The agent then has nothing to do until the reset, so the brief line
    drops its invoke-the-skill nudge and the prompt hook throttles as if the check were clean.
    """
    if stop_work_enabled() or (context and context["level"] != "ok"):
        return False
    tight = [b for b in (quota or {}).get("buckets", [])
             if b.get("applies", True) and b["level"] in ("wrap_up", "stop")]
    return bool(tight) and all(is_armed(b, armed) for b in tight)


def build_actions(context, quota, armed=None, model=None):
    """Describe what to do about every subject past a threshold, plus buckets to ignore.

    Returns (actions, notes). Notes name a tight bucket that does not meter the running
    model, which agents otherwise read as an order to stop. With no known model there is
    nothing to name, so such a bucket gets neither.
    """
    model = model or (context or {}).get("model")
    actions = []
    notes = []
    if context and context["level"] != "ok":
        verb = {"notice": "Context past notice threshold",
                "wrap_up": "Context nearly full",
                "stop": "Context effectively full"}[context["level"]]
        actions.append(f"{verb} ({context['percent']}% of {context['limit']:,}): "
                       "finish the current step, then hand off to a fresh session: use the "
                       "`handoff` skill if it is installed, otherwise leave the user a brief "
                       "summary in chat to start the new session from.")
    for bucket in (quota or {}).get("buckets", []):
        if bucket["level"] == "ok":
            continue
        if not bucket.get("applies", True):
            if model:
                notes.append(
                    f"{bucket['label']} quota at {bucket['percent']}% DOES NOT APPLY to this "
                    f"session: that bucket meters {bucket['scope_model']} only and this session "
                    f"is running {model}. Ignore it and keep working - it is not a reason to "
                    "stop or pause.")
            continue
        minutes = bucket["minutes_to_reset"]
        when = f"{bucket['resets_local']}" + (f" (in {minutes // 60}h {minutes % 60}m)"
                                              if minutes is not None else "")
        head = f"{bucket['label']} quota at {bucket['percent']}%"
        if not stop_work_enabled() or bucket["level"] == "notice":
            actions.append(keep_working_action(head, when, bucket, armed))
        elif minutes is not None and minutes <= RESET_SOON_MINUTES:
            actions.append(f"{head} but refills in {minutes}m at {bucket['resets_local']}: "
                           "pause here and resume after the reset.")
        elif bucket["resume_cron"]:
            restart = (f"schedule the restart in this session with CronCreate (cron "
                       f"\"{bucket['resume_cron']}\", recurring false, prompt: "
                       f"\"{RESTART_PROMPT}\"). Keep this session open, because a session "
                       "cron dies with its session.")
            if bucket["level"] == "stop":
                actions.append(f"{head}: finish the current step, then pause until {when}. Tell "
                               f"the user, and {restart}")
            else:
                actions.append(f"{head}: stop starting new work and finish the step in flight. "
                               f"Quota refills {when}. If you pause before then, {restart}")
        else:
            actions.append(f"{head}: stop starting new work and pause after the current step. "
                           f"Quota refills {when}.")
    return actions, notes


@functools.lru_cache(maxsize=None)
def load_installer():
    """Import install-hooks.py, which owns the hook commands, their version, and the plugin check.

    It sits next to this script in the plugin and in a standalone copy alike. None when it is
    missing, so a lone runway.py still reports instead of crashing.
    """
    try:
        spec = importlib.util.spec_from_file_location("runway_install_hooks", INSTALLER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except (OSError, ImportError, AttributeError, SyntaxError):
        return None
    return module


def ships_plugin_hooks(script=SCRIPT):
    """True when this script sits in a plugin whose hooks/hooks.json already registers it."""
    installer = load_installer()
    return bool(installer) and installer.ships_plugin_hooks(script)


def setup_problems():
    """List what is missing or stale in the settings-file hooks, empty when all is well.

    Always empty inside the plugin, whose hooks.json is the install.
    """
    if ships_plugin_hooks():
        return []
    installer = load_installer()
    if not installer:
        return [f"cannot find {INSTALLER.name} next to {SCRIPT.name}"]
    try:
        settings = json.loads((CLAUDE_DIR / "settings.json").read_text())
    except FileNotFoundError:
        settings = {}
    except (OSError, json.JSONDecodeError):
        return ["settings.json is not valid JSON"]
    return installer.problems(settings, plugin=False)


def fix_hint():
    """Tell the agent how to repair the hooks, and what to ask the user when it cannot."""
    command = f'python3 "{INSTALLER}"'
    return (f"Run `{command}`, then tell the user to restart Claude Code. If that command is "
            f"denied or fails with a permission error, ask the user to type `! {command}` in "
            "the prompt and restart Claude Code.")


def setup_line(problems):
    """Build the hook line that flags a missing or outdated install."""
    return f"runway SETUP: hooks need installing ({'; '.join(problems)}). {fix_hint()}"


def self_install_notice(ok, output):
    """Describe the outcome of wiring missing hooks during a manual run."""
    notice = [f"runway: hooks were missing, {'wired them' if ok else 'install failed'}"]
    notice += [f"  {line}" for line in output.splitlines()]
    notice.append("  Restart Claude Code to load them." if ok else f"  {fix_hint()}")
    return "\n".join(notice)


def install_hooks():
    """Run the installer next to this script against our settings file. Returns (ok, output)."""
    if not INSTALLER.exists():
        return False, f"cannot find {INSTALLER}"
    try:
        done = subprocess.run([sys.executable, str(INSTALLER),
                               "--settings", str(CLAUDE_DIR / "settings.json")],
                              capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as error:
        return False, str(error)
    return done.returncode == 0, (done.stdout + done.stderr).strip()


def collect(session_id, cwd, limit_override, hook_model=None, new_session=False):
    """Gather quota and context figures plus an overall verdict.

    A new session has no transcript or token counts yet, so their absence is not reported.
    """
    report = {"quota": None, "context": None, "actions": [], "notes": [], "level": "ok",
              "armed_quiet": False, "setup": [], "errors": []}
    oauth = (read_credentials() or {}).get("claudeAiOauth") or {}
    if not oauth.get("accessToken"):
        report["errors"].append("no OAuth token found; run `claude` and sign in")
    else:
        try:
            report["quota"] = quota_report(oauth)
        except urllib.error.HTTPError as error:
            hint = " (token expired, run `claude` to refresh)" if error.code == 401 else ""
            report["errors"].append(f"usage endpoint returned HTTP {error.code}{hint}")
        except (urllib.error.URLError, json.JSONDecodeError, OSError, ValueError) as error:
            report["errors"].append(f"usage endpoint failed: {error}")

    transcript = find_transcript(session_id, cwd)
    if transcript:
        report["context"] = context_report(transcript, limit_override, hook_model)
    if not new_session and not transcript:
        report["errors"].append(f"no transcript found for {cwd}")
    elif not new_session and not report["context"]:
        report["errors"].append(f"no assistant token counts yet in {transcript.name}")

    model = (report["context"] or {}).get("model") or hook_model or remembered_model(session_id)
    if report["quota"]:
        apply_model(report["quota"], model)

    armed = armed_wakes(session_id)
    report["actions"], report["notes"] = build_actions(report["context"], report["quota"], armed,
                                                       model)
    report["armed_quiet"] = all_armed(report["context"], report["quota"], armed)
    report["level"] = worst([part["level"] for part in (report["context"], report["quota"])
                             if part])
    return report


def bar(percent, width=24):
    """Render a fixed-width ASCII meter for a 0-100 percentage."""
    filled = max(0, min(width, round(width * percent / 100)))
    return "[" + "#" * filled + "-" * (width - filled) + "]"


def render_full(report):
    """Print the long human-readable report."""
    lines = []
    quota = report["quota"]
    if quota:
        plan = " / ".join(filter(None, [quota["plan"], quota["tier"]]))
        lines.append(f"Quota{f' ({plan})' if plan else ''}")
        for bucket in quota["buckets"]:
            minutes = bucket["minutes_to_reset"]
            when = bucket["resets_local"]
            if minutes is not None and minutes >= 0:
                when += f" (in {minutes // 60}h {minutes % 60}m)" if minutes >= 60 \
                    else f" (in {minutes}m)"
            flags = "" if bucket.get("applies", True) \
                else f"  ({bucket['scope_model']} only - not this session)"
            lines.append(f"  {bucket['label']:<22} {bar(bucket['percent'])} "
                         f"{bucket['percent']:>5.1f}%  resets {when}{flags}")

    context = report["context"]
    if context:
        parts = context["breakdown"]
        lines += ["", f"Context window ({context['model'] or 'unknown model'})",
                  f"  {'used':<22} {bar(context['percent'])} {context['percent']:>5.1f}%  "
                  f"{context['tokens']:,} / {context['limit']:,}",
                  f"  free {context['remaining']:,} tokens   "
                  f"cache-read {parts['cache_read']:,}, "
                  f"cache-write {parts['cache_creation']:,}, "
                  f"fresh input {parts['input']:,}",
                  f"  session {context['session']}"]

    lines += ["", f"Verdict: {report['level']}"]
    lines += [f"  - {action}" for action in report["actions"]]
    lines += [f"  - ignore: {note}" for note in report.get("notes", [])]
    lines += [f"! {error}" for error in report["errors"]]
    print("\n".join(lines))


def render_brief(report):
    """Print the compact hook line, plus action lines when something is tight."""
    parts = []
    session = (report["quota"] or {}).get("session")
    if session:
        parts.append(f"5h quota {session['percent']}% (resets {session['resets_local']})")
    context = report["context"]
    if context:
        parts.append(f"context {context['percent']}% of {context['limit']:,}")
    if not parts:
        parts.append("no readings")
    print(f"runway [{report['level']}]: " + " | ".join(parts))
    for action in report["actions"]:
        print(f"runway ACTION: {action}")
    for note in report.get("notes", []):
        print(f"runway IGNORE: {note}")
    if report.get("setup"):
        print(setup_line(report["setup"]))
    if (report["level"] != "ok" and not report.get("armed_quiet")) or report.get("setup"):
        print("runway: invoke the `runway` skill before continuing.")
    for error in report["errors"]:
        print(f"runway warn: {error}")


def read_state():
    """Return the cached previous check, or an empty dict."""
    try:
        return json.loads(STATE_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def write_raw_state(state):
    """Write the whole state blob, creating its directory on first use."""
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    try:
        STATE_FILE.write_text(json.dumps(state))
    except OSError:
        pass


# throttle is rebuilt below; the rest are snapshot fields no reader uses, dropped from old files.
DROPPED_STATE_KEYS = ("throttle", "checked_at", "level", "session", "context_percent",
                      "quota_percent")


def write_state(report, session_id=None):
    """Persist the buckets' wake times and this session's throttle marker, keeping other keys."""
    now = int(time.time())
    previous = read_state()
    payload = {k: v for k, v in previous.items() if k not in DROPPED_STATE_KEYS}
    wakes = {b["label"]: b["wake_at"] for b in (report["quota"] or {}).get("buckets", [])
             if b.get("wake_at")}
    if wakes:
        payload["wakes"] = wakes
    markers = previous.get("throttle")
    markers = markers if isinstance(markers, dict) else {}
    markers = {sid: m for sid, m in markers.items()
               if isinstance(m, dict) and now - m.get("at", 0) < THROTTLE_MARKER_TTL}
    if session_id:
        # Keyed per session: one session arming its wake must not silence another that
        # sits at the same quota without having armed anything.
        markers[session_id] = {"at": now, "quiet": report["level"] == "ok"
                               or bool(report.get("armed_quiet"))}
    if markers:
        payload["throttle"] = markers
    write_raw_state(payload)


def mark_quiet(session_id):
    """Start this session's throttle window now, so the prompt after an arm or ack is silent."""
    state = read_state()
    markers = state.get("throttle")
    markers = markers if isinstance(markers, dict) else {}
    markers[session_id] = {"at": int(time.time()), "quiet": True}
    state["throttle"] = markers
    write_raw_state(state)


def throttled(seconds, session_id):
    """True when this session's recent check was fine, or fully armed, so it can stay silent."""
    if not seconds or not session_id:
        return False
    markers = read_state().get("throttle")
    marker = markers.get(session_id) if isinstance(markers, dict) else None
    if not isinstance(marker, dict) or not marker.get("quiet"):
        return False
    return int(time.time()) - marker.get("at", 0) < seconds


def main():
    parser = argparse.ArgumentParser(description="Claude Code quota and context runway")
    parser.add_argument("--brief", action="store_true", help="compact output for hooks")
    parser.add_argument("--json", action="store_true", help="emit raw JSON")
    parser.add_argument("--throttle", type=int, default=0, metavar="SECONDS",
                        help="with --brief, stay silent if this session's check this recent was "
                             "ok, or had every tight quota bucket armed or acknowledged")
    parser.add_argument("--session", default=os.environ.get("CLAUDE_CODE_SESSION_ID"),
                        help="session id (defaults to $CLAUDE_CODE_SESSION_ID, else newest)")
    parser.add_argument("--cwd", default=os.getcwd(), help="project path for the transcript")
    parser.add_argument("--limit", type=int, help="context window size override")
    parser.add_argument("--record-model", action="store_true",
                        help="cache the model from the hook payload and exit, printing nothing")
    parser.add_argument("--armed", metavar="WAKE",
                        help="record that this session armed its quota wake-up (YYYY-MM-DD HH:MM)")
    parser.add_argument("--ack", nargs="?", const="", metavar="WAKE",
                        help="record that this session carries on without a wake-up for --bucket, "
                             "quiet until WAKE (default: the bucket's wake from the last check)")
    parser.add_argument("--bucket", metavar="LABEL",
                        help="with --armed or --ack, the quota bucket it is for")
    parser.add_argument("--no-self-install", action="store_true",
                        help="skip wiring the hooks when they are missing or outdated")
    parser.add_argument("--hooks-version", type=int, metavar="N",
                        help="set by the installer in hook commands; not for manual use")
    args = parser.parse_args()

    payload = hook_payload()
    event = payload.get("hook_event_name")
    session_id = payload.get("session_id") or args.session
    hook_model = reported_model(payload)
    remember_model(session_id, hook_model)

    if args.record_model:
        return 0

    if args.armed:
        if not session_id:
            print("runway warn: --armed needs a session id (--session or "
                  "$CLAUDE_CODE_SESSION_ID); nothing recorded", file=sys.stderr)
            return 0
        record_armed(session_id, args.armed, args.bucket)
        if not stop_work_enabled():
            mark_quiet(session_id)
        return 0

    if args.ack is not None:
        wake = args.ack or last_wake(args.bucket)
        if not session_id or not args.bucket or not wake:
            print("runway warn: --ack needs a session id, --bucket, and a wake time (passed, or "
                  "from a check that saw that bucket); nothing recorded", file=sys.stderr)
            return 0
        record_armed(session_id, wake, args.bucket, ack=True)
        if not stop_work_enabled():
            mark_quiet(session_id)
        return 0

    if not args.brief and not args.no_self_install and setup_problems():
        # stderr, so --json stays machine-readable on the run that installs
        print(self_install_notice(*install_hooks()), file=sys.stderr)

    if args.brief and throttled(args.throttle, session_id):
        return 0

    report = collect(session_id, args.cwd, args.limit, hook_model,
                     new_session=event == "SessionStart")
    if event == "SessionStart":
        report["setup"] = setup_problems()
    write_state(report, session_id)
    if args.json:
        print(json.dumps(report, indent=2))
    elif args.brief:
        render_brief(report)
    else:
        render_full(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
