# Repository-rename viability assessment

> **Decision (2026-07-27, JT): No repository rename.** The marketplace name remains `jtsternberg` and the Beads prefix remains `claude-plugins-`. This document is retained as the rationale for that decision, not as an open proposal.

This assessment records the decision's evidence rather than proposing a rename. It distinguishes claims tested in an isolated scratch environment from static inspection and reasoning. No GitHub action, real marketplace registration, or real Codex/Claude configuration was changed.

## Tested marketplace-source experiment

**Tested, 2026-07-27:** I cloned this repository into a designated private scratch directory, registered the checked-out clone as marketplace `jtsternberg`, and installed `headline-refiner@jtsternberg` in isolated Codex and Claude Code homes. The marketplace identity came from `.claude-plugin/marketplace.json`, not the source-directory basename.

The bare-clone variant failed loudly in Codex before installation: it requires a checked-out marketplace root containing a supported manifest. The checked-out-clone variant installed normally. After moving that source directory from `old-name` to `new-name`:

| Harness | Marketplace/list result | Installed-plugin result | Update/upgrade result | Manual recovery |
|---|---|---|---|---|
| Codex 0.145.0 | `codex plugin marketplace list` and `codex plugin list` exited 1, naming the stale source path and missing manifest. | A fresh `$headline-refiner` invocation still exited 0 and loaded the cached 1.2.0 skill. | `codex plugin marketplace upgrade jtsternberg` exited 1: the local marketplace is not a Git marketplace. | `codex plugin marketplace remove jtsternberg`, then `add <new-path>` recovered listing; cached plugin remained installed and enabled. |
| Claude Code | `claude plugin marketplace list` exited 0 but showed the stale directory path. | `claude plugin list` exited 0 but marked the installed plugin `failed to load: cache-miss`. | `claude plugin marketplace update jtsternberg` exited 1 with `ENOENT` for the old directory. | Removing and re-adding the marketplace succeeded, but removed the installed plugin; reinstalling `headline-refiner@jtsternberg` was required. |

This tests **local directory sources only**. GitHub redirect behavior, git-sourced marketplace behavior, and third-party users' configuration remain reasoned unless expressly marked otherwise.

## Seven-surface verdict

| Surface | What breaks | Loudly or silently? | Compatibility shim | Who must act | Evidence |
|---|---|---|---|---|---|
| 1. Git identity | `origin` and the stale `temp` remote retain the old GitHub slug; clones, forks, worktrees, submodules, CI, and external links may also pin it. | A GitHub redirect is expected to preserve fetch/clone against the old URL; this was not live-tested because GitHub was deliberately not touched. The risk becomes real if the old slug is later reused. | Keep the redirect; proactively update `origin` with `git remote set-url origin <new-url>`. The stale `temp` remote is documented only; do not remove it without JT's decision. | JT updates controlled remotes and docs; users only need action if redirect continuity is intentionally not relied on. | **Tested locally:** current `origin` and `temp` values. **Reasoned:** redirect semantics and downstream clone behavior. |
| 2. Marketplace source identities | Any local source path breaks immediately on a directory rename. Marketplace identity remains `jtsternberg`, so a repo rename alone need not change `plugin@jtsternberg`. Git-source behavior after an upstream GitHub rename was not tested. | Codex fails its marketplace/plugin lists with an error. Claude lists the stale marketplace but then marks each installed plugin failed to load. | Re-register the same marketplace name at the new source; preserving `jtsternberg` avoids changing plugin IDs. A GitHub redirect may help git sources, but that is untested here. | JT must re-register the local working copy. Each user with a local path source must do the same. | **Tested:** local source move in both harnesses. |
| 3. Caches and installed state | The source registry is authoritative enough to affect discovery even with a cache. | Codex cache still invoked the installed skill after the source vanished, despite list failure. Claude cache did not: it reported `cache-miss`. | Codex: remove/re-add marketplace; cache survived. Claude: remove/re-add plus reinstall every desired plugin. | Each affected user; JT first, because this machine uses a local source. | **Tested:** isolated `CODEX_HOME` and isolated Claude `HOME`. |
| 4. Skill paths and user-side references | Absolute symlinks, copied skills, PATH entries, project settings, aliases, cron, or launchd jobs can dangle or point to the old directory. | Usually silent until invoked. | Update or recreate the reference; a filesystem symlink at the old path could temporarily bridge JT's own move, but is not a distribution solution. | JT for known local references; every user for private automation. | **Tested:** direct symlink scan of `~/.codex/skills`, `~/.agents/skills`, and `~/.claude/skills` found none targeting this repository. **Reasoned:** arbitrary user automation cannot be exhaustively inventoried. |
| 5. In-repo and documentation references | README, manifests, plugin READMEs, Beads remote configuration, and planning docs retain the old name/path. External posts and messages are outside this repository. | In-repo links fail visibly when clicked or used; private/external references fail when someone follows them. | Update controlled references in the rename change; GitHub redirects can cushion old web links but not absolute filesystem paths. | JT/repo maintainers for tracked files; authors of external material where reachable. | **Tested:** 44 tracked files mention `claude-plugins`; 20 contain `jtsternberg/claude-plugins`; two hard-code `/Users/JT/Code/claude-plugins`. The exact `https://github.com/...` form occurs in three files. |
| 6. CI, release artifacts, and Beads | Release/tag URLs inherit the old slug. Beads' remote URL retains the old repository. A prefix rename would change issue IDs and textual references. | CI has no repo-name literal and should not break from a name-only remote change. Tag URLs rely on redirect behavior. Beads prefix changes are broad and hard to reverse outside the database. | Keep the Beads prefix. `bd rename-prefix <prefix> --dry-run` exists, and its help states it rewrites all IDs and text references across database fields, but it cannot repair historical commits, external links, or copied IDs. | JT for remote/config changes; all users and external references if IDs are renamed. | **Tested:** no `claude-plugins` literal in `.github/workflows`; one tag (`gws-v1.16.0`); `bd rename-prefix` capability/help. `bd list --all --limit 0` currently returns 323 prefixed issue IDs, not the previously reported 303. |
| 7. Migration strategy and support burden | A rename is support work, not just an outbound GitHub operation: local source paths require intervention, and Claude users must reinstall plugins after re-registration. | Codex gives an explicit list error; Claude gives an enabled-looking marketplace followed by plugin-level failure. Both are diagnosable but not self-healing. | Preserve marketplace name and Beads prefix; publish exact migration commands and an in-repo migration note at the same time as any future rename. | JT handles rollout and documentation; each installed user handles only their own registry/cache state. | **Tested:** local-source recovery commands. **Reasoned:** population size and external-report volume. |

## Current blast-radius inventory

- `origin` is `https://github.com/jtsternberg/claude-plugins.git`; `temp` is the stale `https://github.com/jtsternberg/claude-plugins-temp.git`. This assessment does not remove `temp`.
- `.claude-plugin/marketplace.json` declares the marketplace name `jtsternberg`. That stable name is independent of the repository slug and is worth preserving through a repository-only rename.
- The two absolute-path documents are `docs/plans/2026-07-05-gws-docs-native-tabs.md` and `docs/superpowers/plans/2026-03-28-hotline-plan.md`.
- `.claude-plugin/plugin.json` and `.beads/config.yaml` are among the tracked references that need intentional review in any rename implementation.
- The live Beads count is 323 issue IDs with the `claude-plugins-` prefix. That is 20 more than the task's earlier 303 count, so any prefix-migration estimate should use a fresh count at execution time.

## Beads prefix is a separate decision

The GitHub repository and the Beads prefix should not be renamed as one package. `bd rename-prefix` is technically available, but its own help calls it rare and says it rewrites IDs and text references in database fields. Even a successful database rewrite leaves old IDs in commit messages, external links, chat, handoffs, screenshots, and users' notes.

The preferred assessment is therefore: **if JT chooses a repository rename, retain `claude-plugins-*` Beads IDs.** They are historical identifiers, not user-facing product branding, and preserving them avoids a high-cost migration with little dual-harness benefit.

## Ranked options

This is a ranked recommendation, not a decision.

| Rank | Option | Assessment | Reversibility |
|---:|---|---|---|
| 1 | **Rename the GitHub repository only; keep marketplace name `jtsternberg` and Beads prefix.** | Best balance if JT wants a neutral public name. Stable plugin IDs avoid a needless client migration; the necessary work is source-path recovery, controlled-link updates, and a migration note. | GitHub rename can be reversed, but redirects and newly created links make repeated toggling undesirable. Local users can re-register either path. |
| 2 | **Do nothing.** | Lowest risk and zero support cost; retains the naming/distribution mismatch that prompted the assessment. | Fully reversible because nothing changes. |
| 3 | **Rename repository and marketplace identity.** | Adds no benefit for a repository-only naming problem but forces every installed reference from `<plugin>@jtsternberg` to a new identity and requires broader reinstall/documentation work. | Technically reversible; practically disruptive once users adopt the new ID. |
| 4 | **New repository with an old-repository redirect/stub marketplace.** | May provide a deliberate compatibility bridge, but duplicates release/distribution state and depends on untested harness handling of marketplace indirection. Use only if a GitHub rename/redirect is unavailable or an independently versioned legacy channel is required. | Moderate: the stub can be removed later, but users may become dependent on it. |
| 5 | **Full rename including Beads prefix.** | Highest irreversible support burden for minimal end-user gain. It multiplies the work across 323 current IDs plus historical references outside Beads. | Database changes may be mechanically reversible, but external textual references are not. |

## Exact migration commands

These commands were tested with directory sources. Replace `<new-source>` with the new local checkout path; a GitHub source form is intentionally not presented as tested behavior here.

### Claude Code user

```bash
claude plugin marketplace remove jtsternberg
claude plugin marketplace add <new-source>
claude plugin install <plugin>@jtsternberg
```

Repeat the final command for each installed plugin. The scratch test showed that removal/re-addition left no installed plugins, so reinstall is required for Claude Code.

### Codex user

```bash
codex plugin marketplace remove jtsternberg
codex plugin marketplace add <new-source>
```

The scratch test retained the cached `headline-refiner@jtsternberg` installation after re-registration. `codex plugin marketplace upgrade jtsternberg` is not a recovery command for a local source; it errors because that marketplace is not Git-backed.

## Support-burden estimate

For users who originally registered `jtsternberg/claude-plugins` as a GitHub source, an upstream redirect may reduce impact, but that claim was not tested in this assessment. For users with a local path source, impact is certain: the source path is stale at the moment the directory moves. JT is the first affected local user.

The bounded, known cost is the controlled repository inventory (44 tracked reference files) plus explicit migration help. The unbounded cost is private automation and any installed-user registry. Codex's cache survival softens an outage but leaves discovery/listing broken; Claude Code's `cache-miss` is a clearer failure but requires reinstallation. A one-time repo-only rename with a stable marketplace name and a visible migration note is therefore manageable. Changing marketplace or Beads identities materially increases support load.

## Findings that outlive this decision

- A **bare** clone cannot serve as a Codex marketplace: Codex requires a checked-out root containing a supported manifest.
- Marketplace identity comes from the `name` field in `marketplace.json`, not the source-directory basename.
- Renaming or removing any marketplace source breaks both harnesses in different shapes. Codex makes both list commands exit 1 while cached skills still invoke; Claude Code's lists exit 0 but plugins report `failed to load: cache-miss`, and re-registration forces reinstall. This is general marketplace troubleshooting knowledge, not rename-specific.
- `codex plugin marketplace upgrade` is not a recovery path for local sources.
- `bd rename-prefix --dry-run` exists if the prefix question ever reopens.

## Candidate repository names (not acted on)

Availability was not checked; these are naming evaluations only and no candidate will be pursued under the 2026-07-27 decision.

| Candidate | Not harness-specific? | Distinct from `anthropics/claude-plugins-official`? | Assessment |
|---|---|---|---|
| `agent-workbench` | yes | yes | Strong neutral umbrella for skills, commands, hooks, and integrations. |
| `assistant-workbench` | yes | yes | Clearer to non-specialists, slightly longer. |
| `agent-utilities` | yes | yes | Accurate but generic; may undersell the workflow-oriented plugins. |
| `automation-workbench` | yes | yes | Broadly accurate, but less directly signals an agent-facing distribution. |
| `agent-toolkit` | yes | mostly | Understandable, though generic enough to merit collision/availability research before choosing. |

The repository slug, marketplace name, and Beads prefix are independently changeable. The top-ranked option changes only the first of those.
