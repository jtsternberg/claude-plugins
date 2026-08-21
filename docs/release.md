# Release repository plugins to Claude Code and Codex

Plugin versions are release identifiers and Codex cache keys. Every plugin
change must bump the version in that plugin's manifest. A Codex-visible change
without a version bump is not acceptable: it defeats an auditable cache
transition and relies on undocumented in-place refresh behavior.

## 1. Identify the published surfaces

Codex and Claude Code resolve different catalogs. Know which one governs a
plugin's Codex availability before testing a release:

- `.claude-plugin/marketplace.json` is the Claude Code catalog **and the single
  inventory source of truth**. Codex does **not** read it once a native catalog
  exists: Codex CLI 0.147.0 resolves marketplace `jtsternberg` to
  `.agents/plugins/marketplace.json` and never falls back to the Claude catalog.
- `.agents/plugins/marketplace.json` is the Codex-native catalog. It is
  **generated, not hand-authored**: `scripts/gen-codex-catalog.mjs` reads the
  legacy catalog (full inventory) plus the small policy overlay in
  `scripts/codex-catalog.config.json`, and emits an entry for every plugin. A
  plugin with no usable Codex surface carries `policy.installation:
  NOT_AVAILABLE`, so Codex refuses to install it rather than silently omitting
  it. Regenerate with `node scripts/gen-codex-catalog.mjs`; the gate runs it in
  `--check` mode (`tests/codex-catalog-drift.test.mjs`) and fails on drift.
  **Never edit this file by hand** — add the plugin to the legacy catalog (and,
  if it needs a policy override, to the config) and regenerate.

Neither catalog pins plugin versions. Codex reads a plugin's manifest by
fallback: `.codex-plugin/plugin.json` if the plugin ships one, otherwise
`.claude-plugin/plugin.json`. This is verified live on Codex CLI 0.147.0 — a
plugin with only a Claude manifest installs from the native catalog and reports
its Claude manifest version. `codex`, `hotline`, and each of the five
`pr-workflow` child plugins ship a `.codex-plugin/plugin.json` — the
`pr-workflow` bundle does not — and every other plugin is served to Codex from
its Claude manifest. Confirm with `find plugins -name plugin.json -path
'*.codex-plugin*'` rather than trusting this list after a plugin is added or
split.

When a shared skill or bundled resource changes, bump every published manifest
whose harness receives that change and keep their release versions aligned. For
a plugin that ships both manifests (`hotline`, `pr-workflow`), keep the two
versions aligned. For a genuinely harness-specific metadata change, bump only
the affected manifest and state why the other harness did not receive a release.
Do not add a `.codex-plugin/plugin.json` merely to mirror metadata: the native
catalog already serves the plugin from its Claude manifest by fallback.

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

Two Claude-side behaviors differ from Codex and are correct, not failures:

- Claude Code's versioned cache **accumulates** — every previously installed
  version stays under `~/.claude/plugins/cache/<marketplace>/<plugin>/`, and only
  the version `claude plugin list` reports is live. Codex removes the prior
  version on upgrade; Claude does not, and `claude plugin prune` cleans
  auto-installed dependencies, not stale versions. Leftover old-version
  directories are expected.
- A marketplace whose `Source` is a local **Directory** (as on the maintainer
  machine) reads the working tree, never the published GitHub revision — the
  Claude check then proves local content only, and it cannot catch a
  committed-but-unpushed release. Prove publication separately: `HEAD ==
  origin/main` on the release ref, or the GitHub-backed Codex profile check
  in §3.

## Empirical cache result

On 2026-08-07, Codex CLI 0.147.0 was tested with a clean `CODEX_HOME` against a
real GitHub branch of this repository. The client installed `codex@jtsternberg`
at 0.1.2 into `plugins/cache/jtsternberg/codex/0.1.2`. The branch was then
updated to 0.1.3. `codex plugin marketplace upgrade jtsternberg` reported the
marketplace root as upgraded and, before any reinstall, replaced the 0.1.2
cache with 0.1.3. The cached README contained the newly published content. A
subsequent `codex plugin add codex@jtsternberg` returned the same 0.1.3 path,
and a second marketplace upgrade reported no upgraded roots.

The same transition was observed on Codex CLI 0.148.0 with
`walk-through-work-history` 1.0.0 → 1.1.0, so the reconciliation behavior is not
specific to 0.147.0.
