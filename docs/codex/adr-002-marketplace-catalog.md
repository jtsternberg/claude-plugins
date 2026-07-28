# ADR 002: Codex-native marketplace catalog

**Status:** Proposed — JT decides

## Decision being asked

Should the repository add a Codex-native `.agents/plugins/marketplace.json`, or
continue to publish only `.claude-plugin/marketplace.json`?

## Facts that constrain the decision

- The legacy catalog resolves all 27 entries in Codex today, but it cannot
  express per-plugin Codex availability.
- `beads-workflow` and `git-commits` have now shipped reader-facing
  Claude-Code-only notices because Codex caches their `commands/` files without
  surfacing or invoking them. README text is the only legacy-format signal; a
  Codex user still sees both plugins alongside working ones. See
  [commands under Codex](commands-under-codex.md).
- The native catalog can express
  `policy.installation: NOT_AVAILABLE`, which would make those two exclusions
  machine-readable. `pr-workflow` must remain available because its skills work
  in Codex even though its three slash commands do not.
- A second 27-entry catalog is a real synchronization risk. A hand-maintained
  native catalog would drift in names, sources, versions, or policy without a
  visible failure.

## Options

| Option | Buys | Costs and limits |
| --- | --- | --- |
| Keep only the legacy catalog | One catalog and no new release machinery. | Codex presents two known-empty plugins as installable; README prose is not machine-readable policy. |
| Commit a hand-maintained native catalog | Native availability policy immediately. | A second 27-entry source of truth and silent drift risk. Not acceptable. |
| Commit a generated native catalog | A checked-out repository can expose native policy, including `NOT_AVAILABLE`, while the legacy catalog remains authoritative. | Requires a generator, a small explicit policy-override input, CI checks, and a Codex smoke test. |
| Generate only at release and do not commit it | One on-disk source tree. | Does not fix users consuming this ordinary repository checkout. It is viable only if the published artifact is proven to be a supported, checked-out/expanded Codex marketplace root; a bare clone is not. |

## Recommendation

**Add a committed, generated native catalog — not a hand-authored duplicate —
provided the first implementation passes the acceptance test below.**

Unlike the manifest-only proposal, this solves a concrete, shipped product
truth: Codex needs to stop offering `beads-workflow` and `git-commits` as if
they were usable. The narrow native policy overlay earns its maintenance cost
if generation makes the legacy catalog the sole catalog inventory source.

The initial native policy set is exactly:

| Plugin | Native installation policy | Reason |
| --- | --- | --- |
| `beads-workflow` | `NOT_AVAILABLE` | Commands only; Codex does not surface plugin slash commands. |
| `git-commits` | `NOT_AVAILABLE` | Commands only; Codex does not surface plugin slash commands. |
| `pr-workflow` | Available | Its skills work in Codex; only its commands are Claude Code only. |

## Required drift-prevention mechanism

The native catalog must be output, not a second hand-maintained declaration.
A generator should read the legacy catalog plus a deliberately small policy
override mapping, and emit `.agents/plugins/marketplace.json` deterministically.
CI and the release process must run the generator in `--check` mode and fail if
the committed output differs. The guard must also assert:

1. all 27 legacy entry names and sources appear exactly once in the native
   catalog;
2. the only initial policy overrides are the two entries above; and
3. a clean isolated Codex marketplace test accepts the generated catalog,
   lists the supported entries, and refuses the two `NOT_AVAILABLE` entries.

That last test is a gate, not a follow-up nicety: it establishes whether a
native catalog can coexist with the current legacy per-plugin manifests. If it
cannot, do not land the catalog alone; defer it until a fully generated native
artifact has passed ADR 001's manifest/frontmatter acceptance test.

## If the recommendation is deferred

Keep the legacy catalog only until either the generated-catalog smoke test
passes or a Codex user reports installing one of the two command-only plugins
despite the README notice. The latter is the concrete deprecation-watch trigger
because it demonstrates that prose has failed to communicate a known policy
boundary.

## Consequences

This adds a second published file but not a second authored catalog. It makes
the command-only exclusion visible to Codex while preserving `pr-workflow`'s
working skills. It also deliberately stops short of native plugin manifests:
that larger compatibility and validator problem remains ADR 001's decision.
