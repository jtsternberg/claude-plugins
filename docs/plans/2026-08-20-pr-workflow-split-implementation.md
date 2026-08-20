# pr-workflow Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the `pr-workflow` plugin into 5 single-purpose child plugins plus a dependency-only bundle, in a nested group dir, so Claude Code users can install/disable each skill independently.

**Architecture:** `plugins/pr-workflow/` becomes a group directory (no manifest of its own) holding six plugin dirs: `bundle/` (plugin named `pr-workflow`, deps only) and five children. Repo tooling learns one rule: *a plugin root is the nearest dir containing `.claude-plugin/plugin.json` (or `.codex-plugin/plugin.json`); a dir under `plugins/` without one is a group dir scanned one level deeper.* Tooling changes land first so the tree stays green at every commit; the move lands second.

**Tech Stack:** bash (test runner, scripts), node:test (compatibility suites), JSON manifests. No new dependencies.

**Spec:** `docs/plans/2026-08-20-plugin-split-justification.md` (decided 2026-08-20).

## Global Constraints

- Child plugins: `address-pr-comments` (holds BOTH `address-pr-comments` and `address-pr-comments-human` skills), `qa-walkthrough-pr`, `update-pr-description`, `walk-through-work-history`, `watch-pr-then-action`. Bundle plugin name: `pr-workflow`.
- Child versions: `1.0.0`. Bundle version: `2.0.0`. Versions are set at file creation; no further bumps in this change-set (one release, one bump).
- Skill content (SKILL.md bodies, scripts, references) moves **unchanged** via `git mv` — the only content edits are `agents/openai.yaml` `default_prompt` namespaces and manifest/test metadata.
- Every SKILL.md keeps working in both harnesses (Dual-Harness Skill Contract in CLAUDE.md). No `${CLAUDE_SKILL_DIR}/../../` traversal exists in pr-workflow and none may be introduced.
- `bash tests/run-all.sh` must pass (with only the expected `codex: live-plugin` skip) at the end of **every task** from Task 5 onward, and after Tasks 1–4 individually.
- Commit after each task with the message given in its final step.

---

### Task 1: Nested-plugin discovery in `tests/run-all.sh`

**Files:**
- Modify: `tests/run-all.sh` (node glob ~line 60, bash glob + label ~lines 74–77, python glob + label ~lines 98–105)

**Interfaces:**
- Produces: test discovery for both `plugins/<plugin>/…` and `plugins/<group>/<plugin>/…`; suite labels use `group/child` for nested plugins. Tasks 5–6 rely on this.

- [ ] **Step 1: Extend the node glob.** Replace the node `for` line:

```bash
	for t in plugins/*/skills/*/tests/*.test.mjs plugins/*/tests/*.test.mjs \
	         plugins/*/*/skills/*/tests/*.test.mjs plugins/*/*/tests/*.test.mjs; do
```

Note: `plugins/*/*/tests` (3 segments) cannot collide with the flat skill glob `plugins/*/skills/*/tests` (4 segments), so no file matches twice. `plugins/<plugin>/skills/` itself never contains a direct `tests/` dir in this repo.

- [ ] **Step 2: Extend the bash glob and fix the label.** Replace:

```bash
	for t in plugins/*/tests/*_test.sh; do
		[[ -f "$t" ]] || continue
		plugin="${t#plugins/}"; plugin="${plugin%%/*}"
```

with:

```bash
	for t in plugins/*/tests/*_test.sh plugins/*/*/tests/*_test.sh; do
		[[ -f "$t" ]] || continue
		plugin="${t#plugins/}"; plugin="${plugin%/tests/*}"
```

(`%/tests/*` strips the shortest `/tests/…` suffix, yielding `agentmail` for flat and `pr-workflow/address-pr-comments` for nested.)

- [ ] **Step 3: Extend the python glob and label.** Replace:

```bash
	for d in plugins/*/skills/*/tests plugins/*/tests; do
		[[ -d "$d" ]] || continue
		compgen -G "$d/test_*.py" >/dev/null || continue

		plugin="${d#plugins/}"; plugin="${plugin%%/*}"
		sub="$(basename "$(dirname "$d")")"
		label="python: $plugin"
		[[ "$sub" != "$plugin" ]] && label="python: $plugin/$sub"
```

with:

```bash
	for d in plugins/*/skills/*/tests plugins/*/tests \
	         plugins/*/*/skills/*/tests plugins/*/*/tests; do
		[[ -d "$d" ]] || continue
		compgen -G "$d/test_*.py" >/dev/null || continue

		plugin="${d#plugins/}"; plugin="${plugin%%/skills/*}"; plugin="${plugin%/tests}"
		sub="$(basename "$(dirname "$d")")"
		label="python: $plugin"
		[[ "$sub" != "$(basename "$plugin")" ]] && label="python: $plugin/$sub"
```

- [ ] **Step 4: Verify no regression on the current flat tree.**

Run: `bash tests/run-all.sh`
Expected: identical suite list and results as before the edit (compare suite count; only `codex: live-plugin` skipped).

- [ ] **Step 5: Prove nested discovery with a throwaway fixture.**

```bash
mkdir -p plugins/zz-fixture/zz-child/tests
printf 'import test from "node:test";\ntest("fixture", () => {});\n' > plugins/zz-fixture/zz-child/tests/fixture.test.mjs
bash tests/run-all.sh 2>&1 | grep "zz-fixture/zz-child"
rm -rf plugins/zz-fixture
```

Expected: the grep prints a PASS line labeled `node: zz-fixture/zz-child/tests/fixture.test.mjs`. Then the fixture is removed.

- [ ] **Step 6: Commit** — `git add tests/run-all.sh && git commit -m "test(runner): discover suites in nested plugin group dirs"`

---

### Task 2: Nested-plugin support in `plugins/codex/tests/compatibility.test.mjs`

**Files:**
- Modify: `plugins/codex/tests/compatibility.test.mjs` — `manifestPlugins()` (~line 71), `catalogEntries()` (~line 78), `validateCatalogs()` (~line 88), `runtimeReferenceErrors()` (~line 119)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `catalogEntries(file, root)` returns `[{name, source}]`; `manifestPlugins()` returns manifest **names** (not dir names) including one nested level; `pluginRootFor(pluginsRoot, file)` resolves the nearest manifest-bearing ancestor. Task 6's marketplace edits are validated by this.

- [ ] **Step 1: Replace `manifestPlugins` with a one-level-recursive, name-returning version:**

```js
function manifestPlugins(pluginsRoot, manifestDir) {
	const names = [];
	for (const dir of directories(pluginsRoot)) {
		const flat = path.join(pluginsRoot, dir, manifestDir, 'plugin.json');
		if (fs.existsSync(flat)) {
			names.push(readJson(flat).name);
			continue;
		}
		// No manifest at this level: treat as a group dir and scan one level deeper.
		for (const child of directories(path.join(pluginsRoot, dir))) {
			const nested = path.join(pluginsRoot, dir, child, manifestDir, 'plugin.json');
			if (fs.existsSync(nested)) names.push(readJson(nested).name);
		}
	}
	return names.sort();
}
```

- [ ] **Step 2: Replace `catalogEntries` — validate name-via-manifest instead of dirname==name, and return sources:**

```js
function catalogEntries(file, root) {
	const catalog = readJson(file);
	assert.ok(Array.isArray(catalog.plugins), `${file}: plugins must be an array`);
	return catalog.plugins.map(entry => {
		const source = typeof entry.source === 'string' ? entry.source : entry.source?.path;
		assert.ok(source && source.startsWith('./plugins/'), `${file}: ${entry.name} source must live under ./plugins/`);
		const sourceDir = path.join(root, source);
		const manifestPath = ['.claude-plugin', '.codex-plugin']
			.map(d => path.join(sourceDir, d, 'plugin.json'))
			.find(p => fs.existsSync(p));
		assert.ok(manifestPath, `${file}: ${entry.name} source ${source} has no plugin manifest`);
		assert.equal(readJson(manifestPath).name, entry.name, `${file}: ${entry.name} has a mismatched manifest name at ${source}`);
		return { name: entry.name, source };
	});
}
```

- [ ] **Step 3: Update `validateCatalogs` to the new return shape.** In its body: call `catalogEntries(<file>, root)` for both catalogs; derive `const legacyNames = legacy.map(e => e.name)` / `const nativeNames = native.map(e => e.name)` and use the name arrays everywhere names were used before. Replace the final native-entry existence loop with:

```js
	for (const entry of native) {
		assert.ok(fs.existsSync(path.join(root, entry.source)),
			`native catalog entry ${entry.name} has no plugin directory at ${entry.source}`);
	}
```

- [ ] **Step 4: Fix plugin-root resolution in `runtimeReferenceErrors`.** Add above it:

```js
function pluginRootFor(pluginsRoot, file) {
	let dir = path.dirname(file);
	while (dir.length > pluginsRoot.length) {
		if (fs.existsSync(path.join(dir, '.claude-plugin', 'plugin.json')) ||
		    fs.existsSync(path.join(dir, '.codex-plugin', 'plugin.json'))) return dir;
		dir = path.dirname(dir);
	}
	return path.join(pluginsRoot, path.relative(pluginsRoot, file).split(path.sep)[0]);
}
```

and replace `const pluginRoot = path.join(pluginsRoot, relative.split(path.sep)[0]);` with `const pluginRoot = pluginRootFor(pluginsRoot, file);`.

- [ ] **Step 5: Run the suite on the still-flat tree.**

Run: `node --test plugins/codex/tests/compatibility.test.mjs`
Expected: PASS (flat tree satisfies the generalized checks — every dirname==name plugin passes the manifest-name assertion identically).

- [ ] **Step 6: Commit** — `git add plugins/codex/tests/compatibility.test.mjs && git commit -m "test(codex): resolve plugins via manifests, supporting nested group dirs"`

---

### Task 3: Nested-plugin support in maintainer scripts

**Files:**
- Modify: `scripts/measure-skill-descriptions.sh` (~lines 120–180), `scripts/compare-skill-descriptions.mjs` (`collectSkills`, ~line 85), `scripts/install-standalone-skill.sh` (~line 81)

**Interfaces:**
- Produces: all three scripts treat `plugins/<group>/<child>` plugins correctly; the stale 60-skill guard is gone (closes bead `claude-plugins-nwtk`).

- [ ] **Step 1: `measure-skill-descriptions.sh` — attribution + guard + subtotals.**
Replace `plugin=${relative_path%%/*}` with:

```bash
  plugin=${relative_path%%/skills/*}
```

(flat: `agentmail`; nested: `pr-workflow/address-pr-comments`). Delete the stale guard entirely:

```bash
if [ "$skill_count" -ne 60 ]; then
  printf 'Expected 60 skill descriptions; parsed %s.\n' "$skill_count" >&2
  exit 1
fi
```

(The `Skills parsed: N` line already reports the count; the guard has been failing since the tree passed 60 skills.) Replace the per-plugin subtotal loop (`for plugin_dir in "$repo_root"/plugins/*; do … done | sort …`) with a loop over the plugins actually parsed:

```bash
printf '%s\n' "${plugins[@]}" | sort -u | while IFS= read -r plugin; do
  plugin_stats=$(emit_records | awk -F '\t' -v wanted="$plugin" '
    $1 == wanted {
      skills++
      total += $3
    }
    END {
      printf "%d\t%d", skills + 0, total + 0
    }
  ')
  printf '%s\t%s\n' "$plugin" "$plugin_stats"
done
```

- [ ] **Step 2: `compare-skill-descriptions.mjs` — nested-aware `collectSkills`.** Replace the plugin loop with:

```js
function skillRoots(pluginsDir) {
	const roots = [];
	for (const dir of readdirSync(pluginsDir).sort()) {
		const base = join(pluginsDir, dir);
		if (!statSync(base).isDirectory()) continue;
		if (existsSync(join(base, 'skills'))) { roots.push({ label: dir, dir: join(base, 'skills') }); continue; }
		if (existsSync(join(base, '.claude-plugin')) || existsSync(join(base, '.codex-plugin'))) continue; // plugin without skills
		for (const child of readdirSync(base).sort()) {
			const nested = join(base, child, 'skills');
			if (existsSync(nested)) roots.push({ label: `${dir}/${child}`, dir: nested });
		}
	}
	return roots;
}
```

then iterate `for (const { label: plugin, dir: skillsDir } of skillRoots(pluginsDir))` and keep the inner per-skill loop unchanged. Add `statSync` to the existing `node:fs` import.

- [ ] **Step 3: `install-standalone-skill.sh` — two-level source lookup.** Replace `source_dir="$repo_root/plugins/$plugin/skills/$skill"` with:

```bash
source_dir="$repo_root/plugins/$plugin/skills/$skill"
if [ ! -d "$source_dir" ]; then
	for candidate in "$repo_root"/plugins/*/"$plugin"/skills/"$skill"; do
		[ -d "$candidate" ] && source_dir="$candidate" && break
	done
fi
```

(The `is_managed_destination` symlink check `*/plugins/"$plugin"/skills/"$skill"` still matches, because the nested path also ends in `/<plugin>/skills/<skill>`.)

- [ ] **Step 4: Verify on the flat tree.**

Run: `bash scripts/measure-skill-descriptions.sh | head -5` → prints `Skills parsed: 71` (no guard failure).
Run: `node scripts/compare-skill-descriptions.mjs` → same output as `git stash`-free baseline (spot-check it lists 71 skills / exits 0).
Run: `bash tests/run-all.sh` → green.

- [ ] **Step 5: Commit + close bead** — `git add scripts/ && git commit -m "chore(scripts): nested-plugin awareness; drop stale 60-skill guard"` then `bd close claude-plugins-nwtk --reason "Guard removed in nested-plugin scripts pass" --json`

---

### Task 4: Move skills into child plugin dirs (`git mv`, no content edits)

**Files:**
- Move: everything under `plugins/pr-workflow/skills/` and `plugins/pr-workflow/tests/` into child dirs (exact commands below)
- Delete: `plugins/pr-workflow/.claude-plugin/`, `plugins/pr-workflow/.codex-plugin/` (recreated per child in Task 5)

**Interfaces:**
- Produces: the directory shape Tasks 5–7 fill in. The tree is **red** between Task 4 and Task 6 (missing manifests/catalog); Tasks 4–6 land as one commit at the end of Task 6.

- [ ] **Step 1: Create the child skeletons and move skills:**

```bash
cd /Users/JT/Code/claude-plugins
mkdir -p plugins/pr-workflow/bundle \
         plugins/pr-workflow/{address-pr-comments,qa-walkthrough-pr,update-pr-description,walk-through-work-history,watch-pr-then-action}/skills
git mv plugins/pr-workflow/skills/address-pr-comments        plugins/pr-workflow/address-pr-comments/skills/address-pr-comments
git mv plugins/pr-workflow/skills/address-pr-comments-human  plugins/pr-workflow/address-pr-comments/skills/address-pr-comments-human
git mv plugins/pr-workflow/skills/qa-walkthrough-pr          plugins/pr-workflow/qa-walkthrough-pr/skills/qa-walkthrough-pr
git mv plugins/pr-workflow/skills/update-pr-description      plugins/pr-workflow/update-pr-description/skills/update-pr-description
git mv plugins/pr-workflow/skills/walk-through-work-history  plugins/pr-workflow/walk-through-work-history/skills/walk-through-work-history
git mv plugins/pr-workflow/skills/watch-pr-then-action       plugins/pr-workflow/watch-pr-then-action/skills/watch-pr-then-action
```


- [ ] **Step 2: Move the tests:**

```bash
mkdir -p plugins/pr-workflow/address-pr-comments/tests plugins/pr-workflow/update-pr-description/tests plugins/pr-workflow/walk-through-work-history/tests
git mv plugins/pr-workflow/tests/skills-layout.test.mjs plugins/pr-workflow/address-pr-comments/tests/skills-layout.test.mjs
git mv plugins/pr-workflow/tests/walk-through-work-history.test.mjs plugins/pr-workflow/walk-through-work-history/tests/walk-through-work-history.test.mjs
git rm -r plugins/pr-workflow/.claude-plugin plugins/pr-workflow/.codex-plugin
rmdir plugins/pr-workflow/skills plugins/pr-workflow/tests 2>/dev/null || true
```

- [ ] **Step 3: Split `skills-layout.test.mjs`.** The moved copy's `pluginRoot = dirname(dirname(fileURLToPath(import.meta.url)))` still resolves correctly — the file sits at `<child>/tests/`, so two `dirname`s yield the child plugin root. No path edit needed. Edit the moved file:
  - `const convertedSkills = ['address-pr-comments', 'address-pr-comments-human'];`
  - In the second test, delete the `updateDescription` const, remove it from the first `for` array (`[automatic, human]`), and delete the four `updateDescription` assertions at the bottom.
  - Rename the first test string to `'address-pr-comments exposes its former commands as explicit-only skills'`.

Then create `plugins/pr-workflow/update-pr-description/tests/skills-layout.test.mjs` with the update-pr-description half:

```js
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const pluginRoot = dirname(dirname(fileURLToPath(import.meta.url)));

test('update-pr-description ships as an explicit-only skill', () => {
	const skillRoot = join(pluginRoot, 'skills', 'update-pr-description');
	const content = readFileSync(join(skillRoot, 'SKILL.md'), 'utf8');
	const metadata = readFileSync(join(skillRoot, 'agents', 'openai.yaml'), 'utf8');

	assert.match(content, /name: update-pr-description/);
	assert.match(content, /disable-model-invocation: true/);
	assert.match(metadata, /allow_implicit_invocation: false/);

	const commandsDirectory = join(pluginRoot, 'commands');
	const commandFiles = existsSync(commandsDirectory)
		? readdirSync(commandsDirectory).filter(file => file.endsWith('.md'))
		: [];
	assert.deepEqual(commandFiles, []);
});

test('update-pr-description preserves safe cross-harness contracts', () => {
	const content = readFileSync(join(pluginRoot, 'skills', 'update-pr-description', 'SKILL.md'), 'utf8');
	assert.match(content, /\$ARGUMENTS/);
	assert.match(content, /Codex: if the invocation text above is not populated/);
	assert.match(content, /argument-hint: "\[date\/commit-hash \| --force\]"/);
	assert.match(content, /mktemp -d/);
	assert.match(content, /git diff --no-index/);
	assert.doesNotMatch(content, /@docs\//);
});
```

- [ ] **Step 4: Update `walk-through-work-history.test.mjs` metadata expectations.** In the moved file: `assert.equal(manifest.name, 'walk-through-work-history');`, `assert.equal(manifest.version, '1.0.0');`, delete the `assert.match(manifest.description, /history walkthroughs/);` line (child manifest gets its own one-skill description), and change the openai default_prompt assertion to `/default_prompt: "Use \$walk-through-work-history:walk-through-work-history /`. The `readme` read at `pluginRoot/README.md` now targets the child README created in Task 5 — leave the read in place.

- [ ] **Step 5: No commit yet.** Tree is intentionally red until Task 6.

---

### Task 5: Child manifests, openai.yaml namespaces, and READMEs

**Files:**
- Create: `plugins/pr-workflow/<child>/.claude-plugin/plugin.json` and `plugins/pr-workflow/<child>/.codex-plugin/plugin.json` for all 5 children
- Create: `plugins/pr-workflow/<child>/README.md` for all 5 children
- Modify: every `agents/openai.yaml` under `plugins/pr-workflow/*/skills/*/agents/openai.yaml` (6 files)

**Interfaces:**
- Consumes: dir shape from Task 4.
- Produces: manifest `name`/`version` values that Task 6's catalog entries and Task 4's edited tests assert.

- [ ] **Step 1: Claude manifests.** Create each `.claude-plugin/plugin.json` exactly (author block identical to the old plugin's):

`address-pr-comments`:
```json
{
  "name": "address-pr-comments",
  "description": "Address PR review comments — automated resolution or human-in-the-loop drafts.",
  "version": "1.0.0",
  "author": { "name": "JT Sternberg", "url": "https://github.com/jtsternberg" }
}
```

`qa-walkthrough-pr`:
```json
{
  "name": "qa-walkthrough-pr",
  "description": "Guide manual QA of a pull request with a generated walkthrough and checklist.",
  "version": "1.0.0",
  "author": { "name": "JT Sternberg", "url": "https://github.com/jtsternberg" }
}
```

`update-pr-description`:
```json
{
  "name": "update-pr-description",
  "description": "Regenerate a pull request's description from its current diff and commits.",
  "version": "1.0.0",
  "author": { "name": "JT Sternberg", "url": "https://github.com/jtsternberg" }
}
```

`walk-through-work-history`:
```json
{
  "name": "walk-through-work-history",
  "description": "Explain how work progressed — PR, branch, or project — one page at a time.",
  "version": "1.0.0",
  "author": { "name": "JT Sternberg", "url": "https://github.com/jtsternberg" }
}
```

`watch-pr-then-action`:
```json
{
  "name": "watch-pr-then-action",
  "description": "Watch a PR for events (CI, reviews, ready-for-review) and run a follow-up action.",
  "version": "1.0.0",
  "author": { "name": "JT Sternberg", "url": "https://github.com/jtsternberg" }
}
```

- [ ] **Step 2: Codex manifests.** For each child create `.codex-plugin/plugin.json` mirroring the old pr-workflow one's shape: same `name`/`version`/`description`/`author` as its Claude manifest plus the constants `"repository": "https://github.com/jtsternberg/claude-plugins"`, `"license": "MIT"`, `"skills": "./skills/"`, keywords `["github", "pull-requests", "code-review"]` (add `"qa"` for qa-walkthrough-pr), and an `interface` block with `developerName: "JT Sternberg"`, `category: "Developer Tools"`, `capabilities: ["Interactive", "Read", "Write"]`, `websiteURL: "https://github.com/jtsternberg/claude-plugins"`, per-child `displayName`/`shortDescription` (title-case of the plugin name / the Claude description), and `defaultPrompt` with the child's own namespace, e.g. for walk-through-work-history:

```json
"defaultPrompt": [
  "Use $walk-through-work-history:walk-through-work-history to explain how work progressed one page at a time."
]
```

(address-pr-comments lists two prompts, one per skill: `$address-pr-comments:address-pr-comments` and `$address-pr-comments:address-pr-comments-human`.)

- [ ] **Step 3: openai.yaml namespace sweep.** In all 6 `agents/openai.yaml` files, replace the `$pr-workflow:` prefix in `default_prompt` with the child plugin's namespace:

```bash
cd /Users/JT/Code/claude-plugins/plugins/pr-workflow
grep -rln '\$pr-workflow:' . | while read -r f; do
  child=$(echo "$f" | cut -d/ -f2)
  sed -i '' "s/\\\$pr-workflow:/\$${child}:/g" "$f"
done
grep -rn 'pr-workflow:' */skills/*/agents/openai.yaml   # expect: no matches
```

- [ ] **Step 4: Child READMEs.** For each child create `README.md` with: title (`# <Display Name>`), the child's one-line description, an Installation section using the child plugin name (`claude plugin install <child>@jtsternberg` / `codex plugin add <child> --marketplace jtsternberg`), the skill section(s) for that child **moved verbatim** from the old `plugins/pr-workflow/README.md` (`### address-pr-comments` lines 24–55 go to the address-pr-comments README covering both skills; `### update-pr-description` lines 56–71; `### watch-pr-then-action` lines 72–98; `### qa-walkthrough-pr` lines 99–122; `### walk-through-work-history` lines 123–148 — line numbers per the pre-move file), with invocation examples rewritten from `/pr-workflow:X` to `/<child>:X`, and a closing line: `Part of the pr-workflow bundle — install pr-workflow to get all PR skills at once.`

- [ ] **Step 5: No commit yet** (tree still red pending Task 6).

---

### Task 6: Bundle plugin + marketplace catalogs

**Files:**
- Create: `plugins/pr-workflow/bundle/.claude-plugin/plugin.json`, `plugins/pr-workflow/bundle/README.md`
- Modify: `.claude-plugin/marketplace.json`, `scripts/codex-catalog.config.json`
- Regenerate: `.agents/plugins/marketplace.json`
- Delete: old `plugins/pr-workflow/README.md`

**Interfaces:**
- Consumes: child manifests (Task 5) — dependency names must match exactly.
- Produces: a green tree; Tasks 4–6 commit here.

- [ ] **Step 1: Bundle manifest** at `plugins/pr-workflow/bundle/.claude-plugin/plugin.json`:

```json
{
  "name": "pr-workflow",
  "description": "PR workflow bundle: installs all five PR skills plugins (address-pr-comments, qa-walkthrough-pr, update-pr-description, walk-through-work-history, watch-pr-then-action).",
  "version": "2.0.0",
  "author": { "name": "JT Sternberg", "url": "https://github.com/jtsternberg" },
  "dependencies": [
    "address-pr-comments",
    "qa-walkthrough-pr",
    "update-pr-description",
    "walk-through-work-history",
    "watch-pr-then-action"
  ]
}
```

- [ ] **Step 2: Bundle README** at `plugins/pr-workflow/bundle/README.md`: title `# PR Workflow (bundle)`, explain it is a dependency-only bundle (installing it installs the five children; each child can be disabled/uninstalled independently), the same Installation snippet as the old README but noting v2.0.0 is a breaking change (`/pr-workflow:X` invocations became `/<child>:X` — list all six old→new mappings), and links to each child dir. Move the old README's `## Example Usage` block (lines 149–172) here with namespaces rewritten. Then `git rm plugins/pr-workflow/README.md`.

- [ ] **Step 3: Marketplace (legacy).** In `.claude-plugin/marketplace.json`, replace `{ "name": "pr-workflow", "source": "./plugins/pr-workflow" }` with six entries (keep array position, children first, bundle last):

```json
{ "name": "address-pr-comments", "source": "./plugins/pr-workflow/address-pr-comments" },
{ "name": "qa-walkthrough-pr", "source": "./plugins/pr-workflow/qa-walkthrough-pr" },
{ "name": "update-pr-description", "source": "./plugins/pr-workflow/update-pr-description" },
{ "name": "walk-through-work-history", "source": "./plugins/pr-workflow/walk-through-work-history" },
{ "name": "watch-pr-then-action", "source": "./plugins/pr-workflow/watch-pr-then-action" },
{ "name": "pr-workflow", "source": "./plugins/pr-workflow/bundle" }
```

- [ ] **Step 4: Codex catalog policy + regenerate.** Codex has no verified plugin-dependency support, so the bundle must not be offered natively until verified: add `"pr-workflow"` to the `notAvailable` array in `scripts/codex-catalog.config.json` (children stay available — Codex reads their `.codex-plugin` manifests). Then:

```bash
node scripts/gen-codex-catalog.mjs
node --test tests/codex-catalog-drift.test.mjs
```

Expected: catalog regenerated; drift test PASS.

- [ ] **Step 5: Full verification.**

Run: `bash tests/run-all.sh`
Expected: green; the suite list now shows `pr-workflow/address-pr-comments`, `pr-workflow/update-pr-description`, `pr-workflow/walk-through-work-history` node suites and no plain `pr-workflow` suites. Only `codex: live-plugin` skipped.

- [ ] **Step 6: Commit Tasks 4–6** — `git add -A && git commit -m "feat(pr-workflow)!: split into 5 child plugins + dependency-only bundle (2.0.0)"`

---

### Task 7: Repo docs + reference sweep

**Files:**
- Modify: `README.md` (repo root — pr-workflow section), `CLAUDE.md` (Repository Structure + Adding a New Plugin), any file matched by the sweep

**Interfaces:**
- Consumes: final names/paths from Tasks 5–6.

- [ ] **Step 1: Sweep for stale references.**

```bash
grep -rn "pr-workflow:" --include="*.md" --include="*.json" --include="*.yaml" --include="*.mjs" --include="*.sh" . | grep -v ".git/" | grep -v "docs/plans/" | grep -v "plugins/pr-workflow/"
grep -rn "plugins/pr-workflow/skills" . | grep -v ".git/" | grep -v "docs/plans/"
```

Fix every hit outside `docs/plans/` (historical plans stay as written): old invocations become the child namespace; old paths become the nested path. Expect hits at minimum in the repo root `README.md`.

- [ ] **Step 2: CLAUDE.md structure docs.** In the Repository Structure section, after the existing tree, add:

```markdown
A directory under `plugins/` without its own `.claude-plugin/plugin.json` is a
**plugin group**: each of its immediate subdirectories is a plugin of the normal
shape above (see `plugins/pr-workflow/`). A group typically also holds a
`bundle/` plugin — a manifest with only `name` + `dependencies` — so one install
brings in every child. Tooling resolves a plugin root as the nearest directory
containing a plugin manifest; never assume `plugins/<name>` is a plugin root.
```

And in "Adding a New Plugin", append one line: `For a set of related but independent skills, prefer a plugin group of single-skill plugins plus a bundle (see plugins/pr-workflow/) over one multi-skill plugin.` Update the `find plugins -name SKILL.md` expectation line to say results match `plugins/<plugin>/skills/<skill>/SKILL.md` **or** `plugins/<group>/<plugin>/skills/<skill>/SKILL.md`.

- [ ] **Step 3: Repo root README.** Update the pr-workflow entry to describe the group: bundle install one-liner plus the five children with their new invocations.

- [ ] **Step 4: Run compounding-preflight** (repo-private skill) against the full change-set; address or consciously dismiss each flag. Add a compounding ledger entry only if the work taught a durable rule beyond what CLAUDE.md now states (the group-dir rule lives in CLAUDE.md — the ledger should point, not restate).

- [ ] **Step 5: Commit** — `git add -A && git commit -m "docs: plugin-group layout; update pr-workflow references to child namespaces"`

---

### Task 8: Live install verification (both harnesses)

**Files:** none (verification only; fixes loop back into earlier tasks)

- [ ] **Step 1: Claude Code.** In a scratch dir: add the local marketplace and install the bundle; verify the five children arrive and skills resolve:

```bash
cd "$(mktemp -d)"
claude --dangerously-skip-permissions -p "Run /plugin marketplace add /Users/JT/Code/claude-plugins then install pr-workflow from it. Then list every skill whose namespace contains 'address-pr-comments', 'qa-walkthrough-pr', 'update-pr-description', 'walk-through-work-history', or 'watch-pr-then-action'. Report exactly what installed and the full namespaced skill list." --output-format json > install-probe.json 2>&1
```

Save raw output to the file first, then read it. Expected: bundle install pulls all 5 dependencies; skills listed under child namespaces (`walk-through-work-history:walk-through-work-history` etc.). If dependencies do NOT auto-install, stop and investigate against https://code.claude.com/docs/en/plugin-dependencies before proceeding.

- [ ] **Step 2: Codex.** Verify a child installs and, separately, whether Codex resolves the bundle's `dependencies` field at all:

```bash
codex plugin add walk-through-work-history --marketplace jtsternberg   # or the local-path equivalent used in past releases (see docs/release.md)
```

Expected: child installs; `$walk-through-work-history:walk-through-work-history` invocable. If Codex turns out to support dependency bundles, remove `"pr-workflow"` from `notAvailable` in `scripts/codex-catalog.config.json`, regenerate the catalog, and amend the Task 6 commit rationale in a follow-up commit.

- [ ] **Step 3: Uninstall/disable granularity check (the whole point).** In the scratch Claude session: disable one child (`/plugin` → disable `update-pr-description`), confirm its skills leave the context listing while the other children's skills remain.

- [ ] **Step 4: Record results.** Append a `## Verification` section to `docs/plans/2026-08-20-plugin-split-justification.md` with the probe outcomes (dependency auto-install: yes/no; per-child disable: works/not; Codex bundle: supported/notAvailable). Commit — `git add docs/plans && git commit -m "docs(plans): record pr-workflow split verification results"`

---

### Task 9: Ship

- [ ] **Step 1:** Final `bash tests/run-all.sh` — green, `skipped 1` only.
- [ ] **Step 2:** Invoke the repo's `publish-release` skill for the change-set (versions were already set: children 1.0.0, bundle 2.0.0 — no further bump). Follow its runbook including the marketplace refresh in both harnesses.
- [ ] **Step 3:** Land-the-plane per CLAUDE.md: `git pull --rebase && bd dolt push && git push && git status` (must show up to date). Close any beads this work satisfies; `claude-plugins-57g6` (split-plugin meta-skill) stays open — it is written AFTER this pilot proves the pattern.
