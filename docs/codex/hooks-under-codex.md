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

**Follow-up, tested on codex-cli 0.146.0 (2026-08-03):** a trusted
`SessionStart` hook ran and successfully received `${CLAUDE_PLUGIN_ROOT}`, but
an `export CLAUDE_SKILL_DIR=...` from that hook was absent in a later
skill-body shell. A hook can record state for a skill only if the skill
explicitly reads that state; it cannot inject a persistent per-skill shell
variable by itself. Reverify this boundary after Codex upgrades.

## Context injection: both channels work (codex-cli 0.147.0, 2026-08-11)

The earlier probes established that a plugin hook *runs* under Codex. They did not establish
that anything it prints reaches the model. That gap mattered: `handoff`'s `SessionStart` hook
reports pending handoffs as plain text, and the `agentmail` mail-check hook emits a JSON
envelope, so the two depend on different answers.

Both work. Two `codex exec` runs, each with a hook printing a distinct nonce and a prompt
asking for it (`NOTOKEN` as the negative answer):

| `UserPromptSubmit` hook stdout | Model's answer |
| --- | --- |
| `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"…ZEBRA-7741-QUAIL…"},"suppressOutput":true}` | `ZEBRA-7741-QUAIL` |
| plain text: `SYSTEM NOTE: … OTTER-3312-MANGO …` | `OTTER-3312-MANGO` |

Each run returned only its own nonce and Codex echoed neither into the transcript, so this is
delivery into the model's context rather than terminal bleed. Codex surfaced both identically
(`hook: UserPromptSubmit` → `hook: UserPromptSubmit Completed`) and warned about neither.

Method: `codex exec --ephemeral --ignore-rules --skip-git-repo-check --sandbox read-only
--dangerously-bypass-hook-trust`, with the hook supplied through a `-c
hooks.UserPromptSubmit=[…]` override in a scratch workspace. The override form was chosen
over installing a throwaway plugin so that nothing in the real `CODEX_HOME` changed; the
plugin-hooks surface itself is already covered by the probes below. The trust bypass was
required, which re-confirms the gate.

**The correction worth carrying forward:** before this probe, the `agentmail` spec inferred
from `additionalProperties: false` in Codex's hook *output* schema that plain stdout could
not be a context channel, and filed a bug against `handoff` on that basis. The inference was
wrong. A JSON Schema constrains how a JSON body is parsed; it says nothing about what the
harness does with output that isn't JSON. Schema shape is not behavior — probe it.

## PostToolUse: neither channel reaches context (codex-cli 0.151.0, 2026-08-31)

The 0.147.0 result above covers only `UserPromptSubmit`. `PostToolUse` was schema-backed but
unprobed — and it behaves oppositely. A `PostToolUse` hook *fires* reliably (a fire-log is
written on every tool call), but nothing it prints reaches the model, on either channel a
`UserPromptSubmit` hook succeeds with.

| `PostToolUse` hook stdout | Model's answer |
| --- | --- |
| `{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"…ALPHA-5501-FALCON…"}}` | `NOTOKEN` |
| plain text: `SYSTEM NOTE: … BRAVO-6602-HERON …` | `NOTOKEN` |

Each run forced a tool call (`echo`), the `PostToolUse` hook fired after it (confirmed by an
on-disk fire-log), and the model — in the same turn, immediately after the tool result —
reported no injected token. A same-version/model positive control (`UserPromptSubmit`
additionalContext, nonce `CHARLIE-7703-OTTER`) returned the nonce, so the probe detects real
injection and these are genuine negatives; it also re-confirms the 0.147.0 `UserPromptSubmit`
finding on 0.151.0. Tested `gpt-5.6-sol` under ChatGPT auth in a scratch `CODEX_HOME` supplied
via a `hooks.json` file (the `-c hooks.X=[…]` override fails as "expected a sequence" when the
value is shell-quoted), same flags as the probe above, `< /dev/null` to stop `codex exec`
blocking on stdin. Only same-turn delivery was tested — the only case a tripwire needs.

Lesson holds in reverse: schema shape is not behavior — a `PostToolUse` hook Codex accepts and
runs still cannot talk to the model. Consequence: a `PostToolUse` tripwire (or any hook that
must warn the model in-turn) is Claude-only under current Codex, by limitation, not omission.

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
