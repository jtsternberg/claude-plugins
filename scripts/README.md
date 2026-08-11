# Repository scripts

These scripts are repository-level utilities, not plugin runtime dependencies.
Run them from the repository root. The analysis scripts inspect only the
checkout and do not contact Codex, a marketplace, or an external API. The
standalone installer writes only to its selected skill destination.

## Scripts

### `install-standalone-skill.sh`

Installs one self-contained repository skill for Codex. It accepts an explicit
`<plugin>:<skill>` name, symlinks into `$HOME/.agents/skills` by default, and
supports a copy mode, managed refresh, managed uninstall, and a destination
override for repository-scoped installs or isolated tests.

```bash
bash scripts/install-standalone-skill.sh research-tools:fetch-docs
bash scripts/install-standalone-skill.sh --copy research-tools:fetch-docs
bash scripts/install-standalone-skill.sh --uninstall research-tools:fetch-docs
```

It rejects malformed skills, plugin-root resource dependencies, and existing
destinations it does not manage. See the
[standalone skill guide](../docs/codex/standalone-skills.md) for discovery
locations, update behavior, and the full safety contract.

### `measure-skill-descriptions.sh`

Reports the frontmatter `description:` character budget across every
`plugins/*/skills/*/SKILL.md` file. It prints per-skill records, per-plugin
totals, the grand total, and descriptions over 500 characters.

```bash
bash scripts/measure-skill-descriptions.sh
```

The script currently expects 60 skill descriptions and exits nonzero if the
count changes. That is an intentional drift guard: when a skill is added or
removed, update the expected count and refresh
[`docs/codex/skill-description-budget.md`](../docs/codex/skill-description-budget.md)
in the same change.

### `compare-skill-descriptions.mjs`

Compares live skill frontmatter with the proposed rewrite set in
[`docs/codex/proposed-descriptions.json`](../docs/codex/proposed-descriptions.json).
It reports both budgets:

- Codex's pooled `description:` budget; and
- Claude Code's per-skill `description` + `when_to_use` cap.

```bash
node scripts/compare-skill-descriptions.mjs
node scripts/compare-skill-descriptions.mjs --dump-current
```

This is a phase/rewrite-plan tool, not the current budget guard. Its proposal
file describes the earlier 50-skill rewrite set, while the live tree now has
60 skills; it therefore exits with a count mismatch until that proposal set
and its report are deliberately refreshed. Do not turn its exit code into CI
policy without updating the proposal inventory and regenerating the companion
rewrite report.

To refresh that plan, first dump the live frontmatter, add proposals for every
new skill, update the expected count in the script, then rerun the comparison
and inspect both budget sections before editing any `SKILL.md` files.

## Where to document future changes

When a script's behavior or output changes:

1. update this README with its input, output, exit behavior, and a minimal
   invocation;
2. update the relevant report or compatibility guide under `docs/codex/`;
3. record the decision and follow-up in the associated Beads issue; and
4. add a test under `tests/` if the script is a regression guard rather than a
   one-off report generator.

The repository's `AGENTS.md`/`CLAUDE.md` should link here and identify the
scripts as maintainer checks, but should not duplicate their full usage or
turn report-specific details into ambient agent instructions. User-facing
plugin READMEs should mention a script only when the script is part of that
plugin's supported runtime; these repository-wide analyzers belong here.
