# Skill-description budget

`bash scripts/measure-skill-descriptions.sh` parsed **60** skill descriptions across 26 plugins with skills. Their combined length is **7,700 characters**: **96.25%** of Codex's approximately 8,000-character description budget. Two marketplace plugins have no skills and contribute zero characters.

The parser reads only YAML front matter and supports quoted and plain scalars plus YAML folded (`>`) and literal (`|`) multi-line scalars. It measured `work-with-media/yt-dlp` at **263** characters while correctly ignoring that skill's adjacent multi-line `when_to_use` field; the `obsidian-cli` description measured **161** characters.

## Per-plugin totals

| plugin | skills | description chars |
|---|---:|---:|
| beads-workflow | 2 | 140 |
| bible | 1 | 62 |
| cmux-cli | 2 | 381 |
| codex | 3 | 490 |
| collab-tools | 3 | 483 |
| export-presentation | 1 | 58 |
| fable | 2 | 436 |
| generating-blog-images | 1 | 63 |
| git-commits | 2 | 264 |
| git-tree | 1 | 81 |
| gws | 7 | 920 |
| handoff | 2 | 321 |
| headline-refiner | 1 | 64 |
| hotline | 8 | 761 |
| localwp-shell | 1 | 191 |
| mac-caffeinate | 1 | 88 |
| obsidian-cli | 1 | 161 |
| paperclip | 1 | 69 |
| pr-workflow | 5 | 458 |
| publish-insights | 0 | 0 |
| research-tools | 1 | 186 |
| session-tools | 3 | 329 |
| skill-tools | 5 | 374 |
| slack | 1 | 268 |
| slides-presentation | 1 | 102 |
| thinking-tools | 2 | 433 |
| work-with-media | 2 | 517 |
| workspace-status | 0 | 0 |
| **Grand total** | **60** | **7,700** |

## Descriptions over 500 characters

| plugin | skill | chars |
|---|---|---:|
| none | — | — |

No descriptions currently exceed 500 characters. The longest is `slack/read-slack` at 268 characters.

## Recommendation

Adopt a **140-character hard maximum** for `description:` and enforce a **7,000-character marketplace total**. The current 60 descriptions total 7,700 characters, so the aggregate is already 700 characters above that target even though every individual description is below 500 characters. The description should contain one clear action plus at most two or three high-signal aliases.

Move exhaustive trigger-phrase inventories, routing detail, and examples into a `when_to_use:` frontmatter field or a `## Trigger examples` section near the top of the skill body. Claude Code users and maintainers still have the full vocabulary available there. Codex implicit invocation should not be assumed to read those supplemental fields, so retain the most discriminative terms in the short description rather than moving every trigger out of it.

## Marketplace shape

A single 27-plugin marketplace is the wrong default shape for Codex if every installed skill contributes its description to one global budget. It makes unrelated integrations compete: `gws`, `hotline`, media, writing, WordPress, and workflow tools can collectively truncate the descriptions that decide whether any one of them fires.

Keep the source repository and its marketplace registry unified, but offer smaller installable domain bundles or profiles for Codex: for example, core workflow, communications/integrations, media, and local-development. Users can install the bundle relevant to their current work, keeping the active description set below the cap. This is preferable to silently shortening every skill's discovery signal.

## Reproduction

```bash
bash scripts/measure-skill-descriptions.sh
```

The script prints every skill sorted by description length, per-plugin subtotals, the grand total and budget percentage, and the over-500-character list.
