# Codex compatibility research

This directory is a dated research archive for Codex compatibility work in
this repository. It contains probe results, decision records, measurements,
and superseded options—not a promise that every observation still describes
the current Codex release.

For the short, maintained, user-facing summary, see the
[Codex compatibility guide](compatibility.md). The guide is the right link for
users and plugin authors; this directory is the right place to preserve the
evidence behind it.

## How to read this directory

| Area | Contents | Audience |
| --- | --- | --- |
| [Compatibility guide](compatibility.md) | Current support boundaries and authoring guidance | Users and plugin authors |
| [Release checklist](release.md) | Version, publish, refresh, and cache-verification procedure | Maintainers |
| Evidence | `compat-matrix.md`, `*-under-codex.md`, `*-semantics.md`, `install-from-git.md`, and `path-resolution-evidence.md` | Maintainers rechecking behavior |
| Decisions | `adr-*.md`, `path-resolution-options.md`, and `rename-viability.md` | Maintainers reviewing trade-offs |
| Measurements | `skill-description-budget.md`, `skill-description-rewrites.md`, and `proposed-descriptions.json` | Maintainers changing discovery metadata |

The evidence and decision files are intentionally retained because a Codex
upgrade can invalidate a conclusion without changing this repository. They
are not polished support documentation and may contain historical issue
references, internal decision language, or scratch-probe detail.

## Version-sensitive evidence

Every runtime claim should be read with its test version and date. The current
archive spans codex-cli 0.144.6, 0.145.0, and 0.146.0; findings from one build
must not be silently generalized to another. **Reverify after any Codex
upgrade**, especially claims about skill discovery, hook environments,
frontmatter, command surfaces, and cache layout.

When adding or revising a probe, record:

1. the exact `codex --version` output;
2. the test date and whether the run used an isolated `CODEX_HOME`;
3. the observed result, including a failure result; and
4. the guide or decision that should change if the result moves.

## What belongs in Beads

Beads is the task and decision-status record: capture the conclusion, scope,
follow-up, and a link to the relevant evidence there. Do not use an issue note
as a replacement for a reproducible probe log, and do not use this archive as a
task queue. The durable split is:

- **Beads:** what was decided, what remains, and who/what is blocked;
- **the compatibility guide:** the current user-facing contract;
- **this archive:** why the contract says that, including dated evidence; and
- **the scripts:** repeatable measurements and report generation.

If an archive document is superseded, keep it and mark the newer result in the
guide rather than rewriting history. Delete raw material only when its result
has been captured elsewhere and the probe can no longer help explain or
reproduce a compatibility decision.

## Public-safety boundary

Only `compatibility.md` is intended to be a public-facing guide. The remaining
files are maintainer research. Before linking one from user documentation,
remove internal process references and confirm that paths, issue identifiers,
and scratch details are appropriate to publish.
