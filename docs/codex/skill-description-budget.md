# Skill-description budget

`bash scripts/measure-skill-descriptions.sh` parses **55** skill descriptions. Run it to measure the current aggregate before making a release; the expected count is intentionally guarded in the script so new skill descriptions receive an explicit budget review.

The parser reads only YAML front matter and supports quoted and plain scalars plus YAML folded (`>`) and literal (`|`) multi-line scalars.

## Current measurement

The current 55 descriptions total **7,311 characters** (**91.39%** of Codex's approximately 8,000-character budget). `git-commits` contributes two skills and 264 characters.

| plugin | skills | description chars |
|---|---:|---:|
| git-commits | 2 | 264 |
| **Grand total** | **55** | **7,311** |

## Descriptions over 500 characters

No descriptions currently exceed 500 characters. Keep descriptions short because Codex loads them into a shared budget.

## Recommendation

Adopt a **140-character hard maximum** for `description:` and enforce a **7,000-character marketplace total**. A 140-character ceiling across 55 skills caps descriptions at 7,700 characters, so a stricter aggregate check or a lower per-skill target will be needed as the inventory grows. The description should contain one clear action plus at most two or three high-signal aliases.

Move exhaustive trigger-phrase inventories, routing detail, and examples into a `when_to_use:` frontmatter field or a `## Trigger examples` section near the top of the skill body. Claude Code users and maintainers still have the full vocabulary available there. Codex implicit invocation should not be assumed to read those supplemental fields, so retain the most discriminative terms in the short description rather than moving every trigger out of it.

## Marketplace shape

A single 27-plugin marketplace is the wrong default shape for Codex if every installed skill contributes its description to one global budget. It makes unrelated integrations compete: `gws`, `hotline`, media, writing, WordPress, and workflow tools can collectively truncate the descriptions that decide whether any one of them fires.

Keep the source repository and its marketplace registry unified, but offer smaller installable domain bundles or profiles for Codex: for example, core workflow, communications/integrations, media, and local-development. Users can install the bundle relevant to their current work, keeping the active description set below the cap. This is preferable to silently shortening every skill's discovery signal.

## Reproduction

```bash
bash scripts/measure-skill-descriptions.sh
```

The script prints every skill sorted by description length, per-plugin subtotals, the grand total and budget percentage, and the over-500-character list.
