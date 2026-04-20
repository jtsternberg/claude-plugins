# Cron Management (macOS launchd)

This document covers how `/sessions-weekly-recap` wraps `scripts/install_cron.sh` to manage a weekly launchd job. Load this file only when the user passes a cron flag (`--install-cron`, `--uninstall-cron`, `--cron-status`, `--cron-logs`, `--cron-run-now`). Otherwise ignore.

## What the cron does

Fires on a weekly schedule (default: Monday 09:00) and runs:

```
claude -p "/sessions-weekly-recap --weekly --output-dir \"<path>\"" --dangerously-skip-permissions
```

`--dangerously-skip-permissions` is required because there's no TTY to approve tool calls. The job runs as your user with your existing Claude Code auth.

## Flag → script mapping

When a cron flag is present, **skip the recap workflow in SKILL.md entirely**. Route to the installer script, run it, and report its stdout directly.

| Skill flag | Script invocation |
|---|---|
| `--install-cron --output-dir "<path>" [--day <d>] [--time <t>]` | `bash ${CLAUDE_SKILL_DIR}/scripts/install_cron.sh install --output-dir "<path>" [--day <d>] [--time <t>]` |
| `--uninstall-cron` | `bash ${CLAUDE_SKILL_DIR}/scripts/install_cron.sh uninstall` |
| `--cron-status` | `bash ${CLAUDE_SKILL_DIR}/scripts/install_cron.sh status` |
| `--cron-logs` | `bash ${CLAUDE_SKILL_DIR}/scripts/install_cron.sh logs` |
| `--cron-run-now` | `bash ${CLAUDE_SKILL_DIR}/scripts/install_cron.sh run-now` |

Rules:

- `--install-cron` **requires** `--output-dir`. If missing, tell the user and stop — don't guess a path.
- `--output-dir` must resolve to an absolute path. The installer expands a leading `~` to `$HOME`, but relative paths (`./notes`, `../out`) are left as-is and will be interpreted relative to the user's home directory at cron fire time — usually not what the user wanted. If the user provides a relative path, resolve it to an absolute path before forwarding.
- `--day` accepts `mon`/`tue`/.../`sun` (or full name). Defaults to `mon`.
- `--time` must be `HH:MM` (24-hour). Defaults to `09:00`.
- The remaining recap flags (`--weekly`, `--since`, `--until`) are ignored when a cron flag is present.

After `--install-cron`, confirm:

- Label: `com.jtsternberg.sessions-weekly-recap`
- Plist: `~/Library/LaunchAgents/com.jtsternberg.sessions-weekly-recap.plist`
- Schedule: `<day> @ <time>`
- Output dir (echo back the path)
- Logs: `~/.claude/logs/sessions-weekly-recap.out.log` and `.err.log`

## Natural-language phrasings that should route here

These should map to cron flags, not to recap generation:

- "install the weekly cron" → `--install-cron` (ask for `--output-dir` if not given)
- "is the cron running?" / "cron status" → `--cron-status`
- "show me the cron logs" → `--cron-logs`
- "run the weekly job now" / "trigger the cron" → `--cron-run-now`
- "uninstall the cron" / "remove the weekly job" → `--uninstall-cron`

## Bypassing the skill (plain shell)

The installer is a standalone bash script. Users can call it directly without going through Claude:

```bash
SCRIPTS=/path/to/claude-plugins/plugins/session-tools/skills/sessions-weekly-recap/scripts

bash $SCRIPTS/install_cron.sh install --output-dir "/absolute/path" --day mon --time 09:00
bash $SCRIPTS/install_cron.sh status
bash $SCRIPTS/install_cron.sh logs
bash $SCRIPTS/install_cron.sh run-now
bash $SCRIPTS/install_cron.sh uninstall
bash $SCRIPTS/install_cron.sh help
```

Same actions, same behavior. Useful for CI scripts, dotfiles, or invocation from outside a Claude session.

## Log locations

- `~/.claude/logs/sessions-weekly-recap.out.log` — stdout from the scheduled `claude -p` run
- `~/.claude/logs/sessions-weekly-recap.err.log` — stderr

`--cron-logs` tails the last ~40 lines of each.

## Platform support

launchd is macOS-only. On Linux, `install_cron.sh` will fail at `launchctl`. If a user asks to install on Linux, tell them this and point them at `cron` / `systemd --user` as manual alternatives. The underlying `claude -p "/sessions-weekly-recap --weekly ..." --dangerously-skip-permissions` command works on any platform with Claude Code installed.
