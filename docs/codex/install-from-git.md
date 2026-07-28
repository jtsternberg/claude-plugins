# Install from Git: stranger test

## Result

The published GitHub source can be added by shorthand, its catalog resolves all
27 plugins, and `research-tools` installs into Codex's versioned cache. A
bundled Claude skill script does **not** run after that install: Codex does not
set `CLAUDE_SKILL_DIR`.

This is a test of the public, last-pushed source—not the working tree. At test
time the working tree had 81 modified/untracked paths, so a new user cloning
the Git URL received commit
`176cf204ca2113ceaeedf958060debd9ce838246` (`fix(session-tools): sessions-fork
is a context loader, not a work continuer`). `origin/HEAD` resolved to that
same commit.

## Reproduction

Use a new `CODEX_HOME`; do not point this at an existing Codex profile. The
authentication file may be symlinked into that directory, but it must not be
copied or inspected.

```bash
export CODEX_HOME="<SCRATCH>/codex-home"
mkdir -p "$CODEX_HOME"
ln -s "<EXISTING_CODEX_HOME>/auth.json" "$CODEX_HOME/auth.json"

codex plugin marketplace add jtsternberg/claude-plugins
codex plugin list
codex plugin add research-tools@jtsternberg
```

Observed marketplace-add output:

```text
Added marketplace `jtsternberg` from https://github.com/jtsternberg/claude-plugins.git.
```

The shorthand therefore works as a Git source; no full URL fallback was
needed. `codex plugin list` reported 27 `@jtsternberg` entries, all initially
`not installed`. The catalog identity is `jtsternberg`, so the install spelling
is `research-tools@jtsternberg`, not `research-tools@claude-plugins`.

The install succeeded and reported this cache shape (with the actual installed
version):

```text
$CODEX_HOME/plugins/cache/jtsternberg/research-tools/1.1.0
```

## Bundled script result: fails

In an isolated temporary workspace, invoke the installed skill and explicitly
ask it to run its prerequisite exactly as written:

```bash
codex exec --ephemeral --json --sandbox danger-full-access \
  --skip-git-repo-check -C "<SCRATCH>/workspace" \
  'Use the installed $fetch-docs skill. As an actual execution test, run its prerequisite command exactly as supplied by the skill. Do not substitute an inline curl or any other command. Do not inspect or edit files. Report the literal command and its exit result.'
```

Codex loaded `fetch-docs` from the installed cache, then attempted its literal
prerequisite command:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh --check
```

It exited 127 with:

```text
bash: /scripts/fetch-docs.sh: No such file or directory
```

The install is real; the script failure is the runtime-variable incompatibility
documented by the `.3` probe, now confirmed for a clean Git-source consumer.
The user-visible effect is that asking Codex to use `$fetch-docs` cannot run
its bundled script even though that script is present under the installed
plugin cache.

## Marketplace upgrade

```bash
codex plugin marketplace upgrade jtsternberg
```

On the same clean Git-source profile this exited successfully:

```text
Marketplace `jtsternberg` is already up to date.
```

This verifies that marketplace upgrade also works for the Git source. It does
not repair the Claude-only `CLAUDE_SKILL_DIR` reference in the skill.
