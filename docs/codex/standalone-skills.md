# Install standalone skills for Codex

Use a standalone install when you want one self-contained skill from this
repository without installing its whole plugin. For normal distribution,
multiple related skills, or skills shipped with connectors, install the plugin
instead.

**Last verified:** 2026-08-11

**Tested on:** codex-cli 0.147.0

OpenAI's [skill documentation](https://developers.openai.com/codex/skills)
defines the current discovery locations and confirms that Codex follows
symlinked skill directories. Runtime behavior can change between Codex
releases, so recheck that documentation and this repository's tests after an
upgrade.

## Where Codex loads standalone skills

Codex scans `.agents/skills` from the current working directory through each
ancestor up to the repository root. It also loads user, administrator, and
bundled system skills.

| Scope | Location | Use it for |
| --- | --- | --- |
| Working directory | `$CWD/.agents/skills` | Skills for one module or nested working directory |
| Repository ancestors | each `.agents/skills` from `$CWD/..` through `$REPO_ROOT` | Skills shared at the appropriate repository subtree |
| User | `$HOME/.agents/skills` | Personal skills that should be available in every repository |
| Administrator | `/etc/codex/skills` | Machine- or container-wide defaults |
| System | bundled with Codex | OpenAI-provided skills |

The installer defaults to `$HOME/.agents/skills`, which is the preferred place
for one personal skill. For a skill that should travel with a repository, check
it into that repository's `.agents/skills` directory instead.

If multiple discovered skills use the same frontmatter `name`, Codex does not
merge them; both may appear in the selector. Remove or disable the duplicate if
that ambiguity is not intentional.

## Install one skill

Run the installer from this repository checkout and identify the source as
`<plugin>:<skill>`:

```bash
bash scripts/install-standalone-skill.sh research-tools:fetch-docs
```

The default install is an absolute symlink:

```text
$HOME/.agents/skills/fetch-docs -> <checkout>/plugins/research-tools/skills/fetch-docs
```

Symlinks are the default because a later `git pull` updates the installed skill
without creating a stale second copy. Keep the checkout at the same path; if it
moves, reinstall the symlink from the new location.

The standalone invocation uses the skill's frontmatter name, without a plugin
namespace:

```text
$fetch-docs
```

The following Claude-catalog plugins are not offered as Codex-native plugins,
but their self-contained workflows are verified for standalone installation:

| Source | Standalone invocation | Requirement |
| --- | --- | --- |
| `beads-workflow:tackle-epic` | `$tackle-epic` | Configured `bd` CLI |
| `beads-workflow:fix-findings-beads-tasks` | `$fix-findings-beads-tasks` | Configured `bd` CLI |
| `git-commits:commit-staged` | `$commit-staged` | Git working tree |
| `git-commits:commit-unstaged` | `$commit-unstaged` | Git working tree |
| `skill-adapter:adapt-skill` | `$adapt-skill` | Public GitHub access is unauthenticated-only in v1; local and installed sources use read-only access. |

Install each source with the same command form shown above. These unqualified
invocations are different from plugin-qualified names: a standalone install is
`$commit-staged`, not `$git-commits:commit-staged`.

Codex detects skill changes automatically. If a newly installed or updated
skill does not appear, start a fresh Codex session.

### Copy instead of symlinking

Use `--copy` when the checkout will not remain on disk:

```bash
bash scripts/install-standalone-skill.sh --copy research-tools:fetch-docs
```

A copy does not update with the repository. Refresh a copy explicitly:

```bash
bash scripts/install-standalone-skill.sh --copy --force research-tools:fetch-docs
```

`--force` only replaces an install already managed by this script. It refuses
to overwrite an unrelated file, directory, or symlink at the destination.

### Install into a repository scope

Override the destination when you deliberately want a repository-local skill:

```bash
bash scripts/install-standalone-skill.sh \
  --skills-dir "$PWD/.agents/skills" \
  research-tools:fetch-docs
```

Commit that directory only when the source it links or copies is appropriate
for every user of the repository. An absolute symlink to a personal checkout
usually should not be committed.

## Update and uninstall

For a symlink install, update the source checkout normally; no installer command
is needed. For a copied install, rerun the `--copy --force` command shown above.

Remove either managed mode with:

```bash
bash scripts/install-standalone-skill.sh \
  --uninstall research-tools:fetch-docs
```

Uninstall refuses unmanaged destinations. Remove an unrelated destination
manually only after inspecting it and deciding that its contents are no longer
needed.

## Standalone compatibility boundary

A standalone skill must carry everything it runs under its own skill directory:

```text
skill-name/
├── SKILL.md
├── scripts/
├── references/
└── assets/
```

The installer validates the skill layout and rejects skills whose model-read
Markdown references `${CLAUDE_PLUGIN_ROOT}`. Those skills rely on shared
plugin-root scripts or references that a one-skill install does not package;
installing them anyway would create a skill that appears in Codex but fails when
invoked.

The acceptance probe installs `research-tools:fetch-docs`, whose script lives
under its own skill directory. On codex-cli 0.147.0, a fresh isolated session
loaded the standalone workspace skill and ran its bundled
`scripts/fetch-docs.sh --check` command successfully from the installed path.

The installer also fails before installation when the named skill is missing,
`SKILL.md` lacks its required `name` or `description`, a flag is unknown, or the
destination already exists without an allowed managed refresh.
