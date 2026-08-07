# Release plugins to Claude Code and Codex

Plugin versions are release identifiers and Codex cache keys. Every plugin
change must bump the version in that plugin's manifest. A Codex-visible change
without a version bump is not acceptable: an installed client can continue to
use the old versioned cache even after its marketplace snapshot refreshes.

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

5. Commit, push, and merge the complete release change. A local working tree is
   not evidence of what marketplace users can install.

## 3. Refresh and reinstall in Codex

Test with an isolated profile so an existing local marketplace registration or
plugin cache cannot mask the Git release:

```bash
export CODEX_HOME="<SCRATCH>/codex-home"
mkdir -p "$CODEX_HOME"

codex plugin marketplace add jtsternberg/claude-plugins
codex plugin add <plugin-name>@jtsternberg
```

After the release reaches the configured Git ref, refresh the marketplace
snapshot and reinstall the plugin:

```bash
codex plugin marketplace upgrade jtsternberg
codex plugin add <plugin-name>@jtsternberg
```

`marketplace upgrade` updates the checked-out catalog and plugin sources. It
does not, by itself, prove that an already installed plugin moved to the new
versioned cache. Reinstall the plugin, verify the command reports the expected
version and installed path, and inspect only the cache directory names:

```bash
find "$CODEX_HOME/plugins/cache/jtsternberg/<plugin-name>" \
  -maxdepth 1 -mindepth 1 -type d -print
```

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
updated to 0.1.3 and the same client ran marketplace upgrade and plugin add
again. The observed refresh and cache transition are recorded in the commit
that introduced this guide.

