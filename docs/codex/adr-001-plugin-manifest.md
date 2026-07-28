# ADR 001: Codex-native plugin manifests

**Status:** Proposed — JT decides

## Decision being asked

Should every plugin gain a Codex-native `.codex-plugin/plugin.json`, or should
the repository continue to rely on the existing
`.claude-plugin/plugin.json` files that Codex already reads?

## Facts that constrain the decision

- The legacy marketplace resolves all 27 plugins in Codex with their real
  manifest versions. Codex accepts both the bare-string legacy source entries
  and legacy plugin manifests. See [the compatibility matrix](compat-matrix.md).
- A native manifest can add `interface.*` metadata such as display name,
  category, capabilities, icons, screenshots, and a default prompt. That is the
  path to a richer Codex `/plugins` presentation.
- The current native-validator path rejects
  `disable-model-invocation: true`, while 24 skills need that field to preserve
  their Claude Code user-only gate. Copying only manifests does not solve that
  incompatibility; a genuinely native artifact may require harness-specific
  skill frontmatter or an upstream validator change.
- Two parallel manifest trees would add 27 synchronized copies and a second
  version-bump obligation. This repository has already needed a parser-drift
  guard after duplicated implementations silently diverged twice.

## Options

| Option | Buys | Costs and limits |
| --- | --- | --- |
| Keep the legacy manifests | Working Codex installs now; one manifest and one version per plugin. | No native `interface.*` metadata in the Codex browser. |
| Commit native mirrors beside legacy manifests | Native UI metadata and an explicit Codex packaging surface. | 27 additional manifests, dual versioning, and no answer to the 24 rejected skill gates. Hand-maintained mirrors invite silent drift. |
| Generate native manifests at release, without committing them | One authored manifest tree on disk; a potentially Codex-specific artifact. | A release attachment is not itself a marketplace source. Codex needs a checked-out root with a supported manifest; a bare clone cannot supply one. This is unproven until an extracted/published artifact can be consumed as a marketplace root. |

## Recommendation

**Do not add committed native manifest mirrors yet. Keep the legacy manifests.**

The current legacy path already delivers functional installation. Native
metadata is desirable presentation work, but it does not solve a blocking
workflow problem, while the validator's rejection of the Claude-only gate makes
the apparently simple duplication incomplete. Adding two manifest trees before
there is a validated, one-source release path would deliberately recreate the
class of drift this repository has already paid to prevent.

### Deprecation-watch trigger

Revisit this decision when either of these concrete observations occurs:

1. Codex stops accepting the legacy `.claude-plugin/plugin.json` path for an
   installed marketplace plugin; or
2. a required Codex user flow cannot be delivered without `interface.*`
   metadata **and** an isolated test demonstrates a native artifact that keeps
   all 24 Claude `disable-model-invocation` gates intact.

Until then, “native looks nicer” is not enough reason to create a second
authoritative manifest tree.

## If duplication is later approved

It must be generated, never hand-maintained. A generator would read the legacy
manifest as the source of truth and emit each native manifest from a documented
mapping. CI must run it in `--check` mode and fail on any byte difference, then
validate every emitted manifest and assert that all 27 names and versions match
their legacy sources. A clean, isolated Codex install from the generated
artifact must be part of that check, including a skill with
`disable-model-invocation: true`.

The release-only alternative is acceptable only after that artifact test proves
that the published artifact is a checked-out/expanded marketplace root Codex can
consume. It does not help a user who points Codex at this repository's ordinary
Git checkout, and the bare-clone experiment rules out treating an arbitrary
bare release repository as the source.

## Consequences

This recommendation preserves a single on-disk manifest source and delays
native browser polish. It also makes the validator/frontmatter conflict an
explicit prerequisite rather than quietly deleting the only working Claude Code
invocation gate.
