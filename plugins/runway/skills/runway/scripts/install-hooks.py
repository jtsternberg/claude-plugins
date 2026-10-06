#!/usr/bin/env python3
"""Register (or remove) the runway hooks in a Claude Code settings file.

For a standalone copy of the skill (e.g. ~/.claude/skills/<name>/), which has no
hooks.json of its own. It merges a SessionStart entry, a throttled UserPromptSubmit entry,
and a silent PostModelSwitch entry into ~/.claude/settings.json, pointing at runway.py
wherever this skill happens to live. Inside the runway plugin, whose hooks/hooks.json
already registers them, it refuses to install and only checks or uninstalls.

Safe to run repeatedly. Existing runway entries are replaced, every other hook is left
alone, and the settings file is backed up before any write.

  install-hooks.py                 # install all three hooks, or repair an outdated install
  install-hooks.py --check         # list problems, exit 1 when missing or outdated
  install-hooks.py --dry-run       # show the resulting hooks block, write nothing
  install-hooks.py --no-prompt-hook  # SessionStart and PostModelSwitch, no prompt re-check
  install-hooks.py --uninstall     # remove every runway hook
"""

import argparse
import json
import re
import shutil
import stat
import sys
import time
from pathlib import Path

SCRIPT = (Path(__file__).resolve().parent / "runway.py")
DEFAULT_SETTINGS = Path.home() / ".claude" / "settings.json"
MARKER = "runway.py"
EVENTS = ("SessionStart", "UserPromptSubmit", "PostModelSwitch")
PROMPT_THROTTLE = 900
# Bump whenever the hook commands change, so older installs show up as out of date.
HOOKS_VERSION = 2
VERSION_FLAG = f"--hooks-version {HOOKS_VERSION}"


def ships_plugin_hooks(script=SCRIPT):
    """True when runway.py sits in a plugin whose hooks/hooks.json already registers it.

    runway.py asks this too, so the layout rule lives in one place.
    """
    try:
        return MARKER in (script.parents[3] / "hooks" / "hooks.json").read_text()
    except (IndexError, OSError):
        return False


def hook_command(throttle=None, flags="--brief"):
    """Build the shell command for a hook entry, quoted for paths containing spaces."""
    suffix = f" --throttle {throttle}" if throttle else ""
    # through python3, so a copy installed without the execute bit still runs
    return f'python3 "{SCRIPT}" {flags}{suffix} {VERSION_FLAG}'


def hook_group(throttle=None, flags="--brief"):
    """Wrap a command in the group shape Claude Code expects under an event."""
    return {"hooks": [{"type": "command", "command": hook_command(throttle, flags),
                       "timeout": 15}]}


def load_settings(path):
    """Read a settings file, returning an empty dict when it does not exist yet."""
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as error:
        sys.exit(f"{path} is not valid JSON ({error}). Fix it by hand, then re-run.")


def strip_runway(settings):
    """Remove every runway hook group, pruning events left empty. Returns the count."""
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return 0
    stripped = 0
    for event in list(hooks):
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        kept = []
        for group in groups:
            entries = [h for h in (group.get("hooks") or [])
                       if MARKER not in str(h.get("command", ""))]
            stripped += len(group.get("hooks") or []) - len(entries)
            if entries:
                kept.append({**group, "hooks": entries})
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if not hooks:
        settings.pop("hooks", None)
    return stripped


def add_runway(settings, with_prompt_hook):
    """Append the runway hook groups to the settings dict."""
    hooks = settings.setdefault("hooks", {})
    hooks.setdefault("SessionStart", []).append(hook_group())
    hooks.setdefault("PostModelSwitch", []).append(hook_group(flags="--record-model"))
    if with_prompt_hook:
        hooks.setdefault("UserPromptSubmit", []).append(hook_group(throttle=PROMPT_THROTTLE))


def installed_commands(settings):
    """List the runway hook commands currently registered, by event."""
    found = []
    hooks = settings.get("hooks")
    for event in EVENTS:
        groups = hooks.get(event) if isinstance(hooks, dict) else None
        for group in groups if isinstance(groups, list) else []:
            for entry in group.get("hooks") or [] if isinstance(group, dict) else []:
                if MARKER in str(entry.get("command", "")):
                    found.append((event, entry["command"]))
    return found


def problems(settings, plugin=None):
    """List what is missing or stale in the settings-file hooks, empty when the install is complete.

    Inside the plugin, hooks.json is the install, so the settings file owes it nothing.
    """
    if plugin is None:
        plugin = ships_plugin_hooks()
    if plugin:
        return []
    found = installed_commands(settings)
    issues = []
    for event in EVENTS:
        registered = [c for e, c in found if e == event]
        if not registered:
            if event != "UserPromptSubmit":
                issues.append(f"{event}: missing")
        elif not all(re.search(rf"{VERSION_FLAG}(?!\d)", c) for c in registered):
            issues.append(f"{event}: out of date")
    return issues


def make_executable(path):
    """Ensure the reader script has its executable bit set."""
    try:
        path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    except OSError:
        pass


def write_settings(path, settings):
    """Back up the settings file, then write the updated version."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        backup = path.with_name(f"{path.name}.bak-{time.strftime('%Y%m%d-%H%M%S')}")
        shutil.copy2(path, backup)
        print(f"backed up {path} to {backup.name}")
    path.write_text(json.dumps(settings, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description="Install the runway hooks")
    parser.add_argument("--settings", type=Path, default=DEFAULT_SETTINGS,
                        help=f"settings file to edit (default {DEFAULT_SETTINGS})")
    parser.add_argument("--check", action="store_true", help="report status and exit")
    parser.add_argument("--dry-run", action="store_true", help="print the result, write nothing")
    parser.add_argument("--no-prompt-hook", action="store_true",
                        help="install SessionStart and PostModelSwitch only, skip the "
                             "periodic prompt re-check")
    parser.add_argument("--uninstall", action="store_true", help="remove every runway hook")
    args = parser.parse_args()

    if not SCRIPT.exists():
        sys.exit(f"cannot find {SCRIPT}. Keep install-hooks.py next to runway.py.")

    settings = load_settings(args.settings)
    plugin = ships_plugin_hooks()

    if args.check:
        found = installed_commands(settings)
        for event, command in found:
            print(f"{event}: {command}")
        if plugin:
            print("runway hooks ship with the plugin (hooks/hooks.json)")
            if found:
                print(f"the entries above in {args.settings} run every hook twice; "
                      "remove them with --uninstall")
            return 0
        issues = problems(settings, plugin=False)
        for issue in issues:
            print(f"problem: {issue}")
        if issues:
            print(f'runway hooks incomplete, fix with: python3 "{Path(__file__).resolve()}"')
            return 1
        print("runway hooks installed")
        return 0

    stripped = strip_runway(settings)
    if args.uninstall:
        if not stripped:
            print("no runway hooks were registered, nothing to do")
            return 0
        write_settings(args.settings, settings)
        print(f"removed {stripped} runway hook(s) from {args.settings}")
        print("restart Claude Code to apply")
        return 0

    if plugin and not args.dry_run:
        sys.exit("runway hooks ship with the plugin (hooks/hooks.json); installing them in "
                 f"{args.settings} too would run every hook twice. Nothing written.")

    add_runway(settings, not args.no_prompt_hook)
    if args.dry_run:
        print(json.dumps({"hooks": settings["hooks"]}, indent=2))
        return 0

    make_executable(SCRIPT)
    write_settings(args.settings, settings)
    verb = "replaced" if stripped else "installed"
    print(f"{verb} runway hooks in {args.settings}")
    for event, command in installed_commands(settings):
        print(f"  {event}: {command}")
    print("restart Claude Code to apply")
    return 0


if __name__ == "__main__":
    sys.exit(main())
