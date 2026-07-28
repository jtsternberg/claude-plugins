# Path-resolution evidence

Probed 2026-07-27 with codex-cli 0.145.0. All Codex plugin probes used the existing throwaway `probe-plugin` marketplace, isolated `CODEX_HOME`, and this environment scrub:

```bash
env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PLUGIN_DATA -u CLAUDE_SKILL_DIR \
  CODEX_HOME="$SCRATCH/codex-home" codex ...
```

Machine-specific paths below are normalized to `<HOME>` and `<SCRATCH>`; no authentication file was read.

## P1 — shell state across skill tool calls

### Setup

Probe-plugin 1.0.7 instructed Codex to make exactly two separate shell calls, in this order:

```bash
export PROBE_MARKER=abc123
```

```bash
echo "[$PROBE_MARKER]"
```

Probe-plugin 1.0.8 then used the same two adjacent fenced blocks without the instruction that they must be separate calls.

### Raw output

The required-separate-call run emitted two `exec` events:

```text
/bin/zsh -lc 'export PROBE_MARKER=abc123'
succeeded in 0ms
/bin/zsh -lc 'echo "[$PROBE_MARKER]"'
succeeded in 0ms:
[]
```

The adjacent-fence run also emitted two separate `exec` events with the same output:

```text
/bin/zsh -lc 'export PROBE_MARKER=abc123'
/bin/zsh -lc 'echo "[$PROBE_MARKER]"'
[]
```

### Finding

Shell state did not persist between separate Codex tool calls. In both observed variants, Codex issued one `zsh -lc` process per fenced command rather than batching the two fences into one shell. Claude Code was not run in this probe; its ordinary separate Bash calls are likewise expected to be fresh processes.

## P2 — Codex environment variables

### Setup

The installed executable resolved to `<HOME>/.codex/packages/standalone/current/bin/codex`. The required binary scan was:

```bash
strings "$codex_bin" | grep -oE 'CODEX_[A-Z_]+' | sort -u
```

The scan contained path-adjacent names such as `CODEX_HOME`, `CODEX_MANAGED_PACKAGE_ROOT`, and `CODEX_CODE_MODE_HOST_PATH`, plus many authentication, network, sandbox, and telemetry names. It contained no `CODEX_SKILL_*`, `CODEX_PLUGIN_*`, or similarly named skill/plugin-root variable.

In a live ungated probe session, the skill ran this filtered form of `env | sort`; it deliberately emitted only `CODEX_*` values so unrelated environment values were not exposed:

```bash
env | sort | awk -F= '/^CODEX_/ { print }'
```

### Raw output

```text
CODEX_CI=1
CODEX_HOME=<SCRATCH>/codex-home
CODEX_THREAD_ID=<session UUID>
```

### Finding

Those were every `CODEX_*` variable actually set in the live probe shell. `CODEX_HOME` names the Codex state home, and `CODEX_THREAD_ID` names the session; neither identifies a skill or plugin root. No live skill/plugin-path-bearing Codex variable was observed.

## P3 — model tool for skill paths

### Setup

A fresh Codex session was asked, without shell commands or file reads, to inspect its callable tool registry for an installed-skill listing tool and state whether that tool returns absolute filesystem paths.

### Raw output

```text
No available tool lists installed Codex skills.

The only skill-named registry tool is `mcp__codex_apps__wpvibe_load_skill`. With no arguments, it returns WPVibe’s internal WordPress skill catalog—not the installed Codex skills. Its declared result is a human-readable string and does not promise absolute filesystem paths.

Any absolute skill paths visible in the session’s injected “Available skills” metadata are not tool output.
```

### Finding

No callable installed-skill listing tool was available in this session, so no tool returned a skill’s filesystem path. The model can see paths supplied in injected Available-skills metadata, but that is distinct from obtaining a path through a tool and was not treated as tool evidence.

## P4 — cache layouts and deterministic globbing

### Setup

The same `hotline` plugin was inspected in both installed caches and in this checkout. The run used literal absolute roots, not a skill/plugin environment variable; `<HOME>` and `<checkout>` below normalize only the machine-specific prefixes:

```bash
resolve_latest_version() {
  find "$1" -mindepth 1 -maxdepth 1 -type d -print | sort -V | tail -n 1
}
codex_hotline=$(resolve_latest_version "<HOME>/.codex/plugins/cache/jtsternberg/hotline")
claude_hotline=$(resolve_latest_version "<HOME>/.claude/plugins/cache/jtsternberg/hotline")
checkout_hotline="<checkout>/plugins/hotline"
printf 'codex=%s\nclaude=%s\ncheckout=%s\n' "$codex_hotline" "$claude_hotline" "$checkout_hotline"
```

### Raw output

```text
<HOME>/.codex/plugins/cache/jtsternberg/hotline/0.20.0
<HOME>/.claude/plugins/cache/jtsternberg/hotline/0.18.1
<checkout>/plugins/hotline

codex=<HOME>/.codex/plugins/cache/jtsternberg/hotline/0.20.0
claude=<HOME>/.claude/plugins/cache/jtsternberg/hotline/0.18.1
checkout=<checkout>/plugins/hotline
```

Each of those three roots contains `.claude-plugin/plugin.json` and `skills/`.

Hotline had one cached version per harness, but multiple cached versions do coexist elsewhere. For example, the Claude cache contained:

```text
<HOME>/.claude/plugins/cache/jtsternberg/cmux-cli/0.8.2
<HOME>/.claude/plugins/cache/jtsternberg/cmux-cli/0.9.0
```

The numeric sort check produced:

```text
$ printf '%s\n' 0.9.0 0.20.0 1.2.0 1.10.0 | sort -V
0.9.0
0.20.0
1.2.0
1.10.0
```

Its prerelease check did not follow SemVer precedence:

```text
$ printf '%s\n' 1.0.0-alpha.1 1.0.0-alpha.2 1.0.0-beta 1.0.0 | sort -V
1.0.0
1.0.0-alpha.1
1.0.0-alpha.2
1.0.0-beta
```

### Finding

Both harnesses use the versioned cache layout in the task, and the two inspected Hotline installs are on different versions. A version glob can deterministically select the final `sort -V` entry for ordinary numeric versions; multiple-version caches mean an unsorted glob/head does not establish that it selected the highest version. `sort -V` is not a general SemVer ordering for prereleases. A checkout is coverable when its root is already known (the run used the current checkout’s literal `plugins/hotline` path); an arbitrary checkout location cannot be discovered from these cache globs alone.
