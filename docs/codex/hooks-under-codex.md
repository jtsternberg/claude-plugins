# Hooks under Codex

## Verdict

`handoff` does **not** work unchanged for a first-time Codex user.

- Codex's hook trust gate prevents its `SessionStart` commands from running on
  the first normal invocation.
- After explicit trust (represented in this probe by
  `--dangerously-bypass-hook-trust`), the `startup|resume` entry runs and
  `${CLAUDE_PLUGIN_ROOT}` resolves correctly.
- The second entry is not a valid way to receive compaction in Codex:
  `compact` did not match a fresh `SessionStart`. Codex models compaction as
  separate `PreCompact` and `PostCompact` hook events, rather than a
  `SessionStart` matcher cause.

This was tested on `codex-cli 0.145.0` in a fresh scratch `CODEX_HOME`, with a
throwaway local plugin and marker script. No real profile, handoff script, or
repository plugin file was changed.

## Probe results

The initial hook config mirrored handoff's startup entry: `SessionStart`,
`matcher: "startup|resume"`, `type: "command"`, `shell: "bash"`,
`timeout: 10`, and a command anchored at `${CLAUDE_PLUGIN_ROOT}`. Each
variation was a version bump followed by plugin remove/add and a new Codex
session.

| Surface | Result | Evidence |
| --- | --- | --- |
| Plugin `hooks/hooks.json` | supported | The plugin SessionStart hook ran from the installed cache when trusted. |
| `${CLAUDE_PLUGIN_ROOT}` in a hook command | supported | Marker recorded the exact installed plugin cache root. |
| `matcher` | supported and enforced | `startup|resume` ran at startup; an intentionally nonmatching string did not. |
| `shell` | ignored | Replacing `bash` with `definitely-not-a-shell` still ran the marker. The hook inherited `SHELL=/bin/zsh`; the explicit `bash` in handoff's command remains what selects Bash. |
| `timeout` | honored | With `timeout: 1` and a three-second marker delay, no marker existed even four seconds later. |
| `statusMessage` | supported presentation field | The field was accepted and the hook ran. `codex exec --json` does not emit its transient UI status, so this probe does not assert its TUI rendering. The current [Codex hook schema](https://github.com/openai/codex/blob/main/codex-rs/core/config.schema.json) declares it as an optional command-hook string. |
| Trust on first install | blocks execution | Without bypass, no marker; with `--dangerously-bypass-hook-trust`, the same installed hook ran. Codex emitted: `Enabled hooks may run without review for this invocation.` |

The `shell` result is the surprise: retaining `shell: "bash"` is harmless, but
it is not what causes handoff's command to run under Bash. Its explicit
`bash "${CLAUDE_PLUGIN_ROOT}/..."` is sufficient.

## Events and `compact`

For this hook shape, `SessionStart` has a startup occurrence: the
`startup|resume` matcher fired in a new `codex exec` session. This probe did
not resume an existing session, so it does not separately certify the `resume`
alternative.

`matcher: "compact"` did not fire on that same new-session path. Current
Codex's hook schema lists dedicated `PreCompact` and `PostCompact` events (as
well as `PermissionRequest`, `PreToolUse`, `PostToolUse`, `SessionStart`,
`Stop`, `SubagentStart`, `SubagentStop`, and `UserPromptSubmit`); it does not
define compaction as a `SessionStart` cause. The source list is schema-backed;
only the SessionStart cases in this table were exercised in the isolated CLI
probe.

## Minimal handoff change

Keep handoff's first `SessionStart` entry. Move its second entry out of
`SessionStart` into `PostCompact` and remove the `matcher: "compact"` field:

```json
"PostCompact": [
  {
    "hooks": [
      {
        "type": "command",
        "shell": "bash",
        "timeout": 5,
        "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/scripts/post-compact-nudge.sh\" || true"
      }
    ]
  }
]
```

That is the minimal configuration change for the compaction behavior. It does
not—and should not—attempt to bypass Codex's trust gate; the user must trust
the plugin's hooks before any unprompted command can run.
