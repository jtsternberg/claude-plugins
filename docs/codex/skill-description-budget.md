# Skill-description budget

`bash scripts/measure-skill-descriptions.sh` parsed **50** skill descriptions across 23 plugins with skills. Their combined length is **15,902 characters**: **198.77%** of Codex's approximately 8,000-character description budget. Four marketplace plugins have no skills and contribute zero characters.

The parser reads only YAML front matter and supports quoted and plain scalars plus YAML folded (`>`) and literal (`|`) multi-line scalars. It measured `work-with-media/yt-dlp` at **417** characters while correctly ignoring that skill's adjacent multi-line `when_to_use` field; the actual literal multi-line description in `obsidian-cli` measured **430** characters.

## Per-plugin totals

| plugin | skills | description chars |
|---|---:|---:|
| beads-workflow | 0 | 0 |
| bible | 1 | 368 |
| cmux-cli | 2 | 583 |
| collab-tools | 3 | 630 |
| export-presentation | 1 | 249 |
| fable | 2 | 706 |
| generating-blog-images | 1 | 310 |
| git-commits | 0 | 0 |
| git-tree | 1 | 282 |
| gws | 7 | 2,949 |
| handoff | 2 | 682 |
| headline-refiner | 1 | 321 |
| hotline | 8 | 1,826 |
| localwp-shell | 1 | 314 |
| mac-caffeinate | 1 | 433 |
| obsidian-cli | 1 | 430 |
| paperclip | 1 | 127 |
| pr-workflow | 2 | 557 |
| publish-insights | 0 | 0 |
| research-tools | 1 | 331 |
| session-tools | 3 | 980 |
| skill-tools | 5 | 841 |
| slack | 1 | 638 |
| slides-presentation | 1 | 386 |
| thinking-tools | 2 | 936 |
| work-with-media | 2 | 1,023 |
| workspace-status | 0 | 0 |
| **Grand total** | **50** | **15,902** |

## Descriptions over 500 characters

| plugin | skill | chars |
|---|---|---:|
| slack | `read-slack` | 638 |
| work-with-media | `macwhisper-cli` | 606 |
| gws | `youtube` | 577 |
| skill-tools | `create-skill` | 570 |
| gws | `google-doc-to-md` | 524 |
| gws | `md-to-google-doc` | 519 |

The six flagged descriptions alone use **3,434 characters**: 42.93% of the entire 8,000-character budget. Each combines a useful one-sentence summary with a long list of natural-language trigger phrases, alternate user phrasings, routing rules, or implementation detail. That shape is sensible for Claude Code, where each skill description has its own room; it is expensive when all descriptions share one fixed Codex budget.

## Recommendation

Adopt a **140-character hard maximum** for `description:` and enforce a **7,000-character marketplace total**. A 140-character ceiling across 50 skills caps the descriptions at 7,000 characters and leaves about 1,000 characters of headroom for growth or counting differences. The description should contain one clear action plus at most two or three high-signal aliases.

Move exhaustive trigger-phrase inventories, routing detail, and examples into a `when_to_use:` frontmatter field or a `## Trigger examples` section near the top of the skill body. Claude Code users and maintainers still have the full vocabulary available there. Codex implicit invocation should not be assumed to read those supplemental fields, so retain the most discriminative terms in the short description rather than moving every trigger out of it.

## Marketplace shape

A single 27-plugin marketplace is the wrong default shape for Codex if every installed skill contributes its description to one global budget. It makes unrelated integrations compete: `gws`, `hotline`, media, writing, WordPress, and workflow tools can collectively truncate the descriptions that decide whether any one of them fires.

Keep the source repository and its marketplace registry unified, but offer smaller installable domain bundles or profiles for Codex: for example, core workflow, communications/integrations, media, and local-development. Users can install the bundle relevant to their current work, keeping the active description set below the cap. This is preferable to silently shortening every skill's discovery signal.

## Reproduction

```bash
bash scripts/measure-skill-descriptions.sh
```

The script prints every skill sorted by description length, per-plugin subtotals, the grand total and budget percentage, and the over-500-character list.
