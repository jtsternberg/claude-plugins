# Release plugins to Claude Code and Codex

Plugin versions are release identifiers and Codex cache keys. Every plugin
change must bump the version in that plugin's manifest. A Codex-visible change
without a version bump is not acceptable: it defeats an auditable cache
transition and relies on undocumented in-place refresh behavior.

## 1. Identify the published surfaces

Check which catalog offers the plugin before testing the release:

- `.claude-plugin/marketplace.json` is the Claude Code catalog and the legacy
  Codex-compatible catalog.
- `.agents/plugins/marketplace.json` is the Codex-native catalog. It contains a
  deliberately smaller plugin set.

Both catalogs point to plugin directories; neither pins plugin versions. Bump
the version in the manifest inside the affected plugin directory:

- `.claude-plugin/plugin.json` for the repository's shared Claude/Codex plugins;
- `.codex-plugin/plugin.json` for a Codex-native-only plugin such as `codex`.

Do not create or bump a second manifest unless that plugin actually publishes
both manifest files. The repository currently avoids hand-maintained manifest
mirrors.

## 2. Prepare and validate the change

1. Bump the affected manifest version using semantic versioning.
2. Run the plugin's focused tests and validators.
3. If a skill changed, run `validate-dual-harness-skill` against it and perform
   representative Claude Code and Codex probes when behavior changed.
4. Run the repository gate and read its summary, including skips:

   ```bash
   bash tests/run-all.sh
   ```

5. Before merging, seed an isolated Codex profile from the current `main`
   release. This creates the old-version cache that the upgrade check must
   replace:

   ```bash
   export CODEX_HOME="<SCRATCH>/codex-home"
   mkdir -p "$CODEX_HOME"

   codex plugin marketplace add jtsternberg/claude-plugins --ref main
   codex plugin add <plugin-name>@jtsternberg
   ```

   Record the installed version and confirm it is the version currently on
   `main`, not the version in the pending release.
6. Commit, push, and merge the complete release change. A local working tree is
   not evidence of what marketplace users can install.

## 3. Refresh and verify in Codex

Continue with the isolated profile seeded before the merge. After the release
reaches `main`, refresh the marketplace snapshot:

```bash
export CODEX_HOME="<SCRATCH>/codex-home"
codex plugin marketplace upgrade jtsternberg
```

On Codex CLI 0.147.0, `marketplace upgrade` also reconciles installed plugins:
it removes the prior versioned cache and materializes the new version. Verify
that transition by inspecting only the cache directory names:

```bash
find "$CODEX_HOME/plugins/cache/jtsternberg/<plugin-name>" \
  -maxdepth 1 -mindepth 1 -type d -print
```

If the expected version is absent, reinstall explicitly and verify the version
and installed path reported by the command:

```bash
codex plugin add <plugin-name>@jtsternberg
```

If the old version was not installed before the merge, this procedure can only
verify a fresh install. It cannot verify cache reconciliation. Create a new
isolated profile, add the marketplace, and install the plugin to confirm that
the merged release is available, but do not report that result as an
old-version-to-new-version cache transition.

Start a new Codex session before exercising changed skills, hooks, MCP servers,
or app configuration. Existing sessions may retain their previously loaded
plugin surface.

## 4. Verify Claude Code

For a plugin offered through the Claude marketplace, update the marketplace
and install or update the plugin with the current Claude Code plugin commands.
Then start a new session and run a representative `/<plugin>:<skill>` probe.
Codex-native-only plugins have no Claude release step.

## Empirical cache result

On 2026-08-07, Codex CLI 0.147.0 was tested with a clean `CODEX_HOME` against a
real GitHub branch of this repository. The client installed `codex@jtsternberg`
at 0.1.2 into `plugins/cache/jtsternberg/codex/0.1.2`. The branch was then
updated to 0.1.3. `codex plugin marketplace upgrade jtsternberg` reported the
marketplace root as upgraded and, before any reinstall, replaced the 0.1.2
cache with 0.1.3. The cached README contained the newly published content. A
subsequent `codex plugin add codex@jtsternberg` returned the same 0.1.3 path,
and a second marketplace upgrade reported no upgraded roots.
