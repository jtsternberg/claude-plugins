# ADR 002: Codex-native marketplace catalog

**Status:** Accepted and implemented (2026-08-12) — see the amendment note at the end.

## Decision being asked

Should the repository add a Codex-native `.agents/plugins/marketplace.json`, or
continue to publish only `.claude-plugin/marketplace.json`?

## Facts that constrain the decision

- The legacy catalog resolves all 27 entries in Codex today, but it cannot
  express per-plugin Codex availability.
- `beads-workflow` is command-only and has a reader-facing Claude-Code-only
  notice because Codex caches its `commands/` files without surfacing or
  invoking them. `git-commits` was migrated to skills in version 1.1.0.
  README text is the only legacy-format signal for the remaining command-only
  plugin. See
  [commands under Codex](commands-under-codex.md).
- The native catalog can express
  `policy.installation: NOT_AVAILABLE`, which would make the remaining exclusion
  machine-readable. `pr-workflow` must remain available because its skills work
  in Codex even though its three slash commands do not.
- A second 27-entry catalog is a real synchronization risk. A hand-maintained
  native catalog would drift in names, sources, versions, or policy without a
  visible failure.

## Options

| Option | Buys | Costs and limits |
| --- | --- | --- |
| Keep only the legacy catalog | One catalog and no new release machinery. | Codex presents one known-empty plugin as installable; README prose is not machine-readable policy. |
| Commit a hand-maintained native catalog | Native availability policy immediately. | A second 27-entry source of truth and silent drift risk. Not acceptable. |
| Commit a generated native catalog | A checked-out repository can expose native policy, including `NOT_AVAILABLE`, while the legacy catalog remains authoritative. | Requires a generator, a small explicit policy-override input, CI checks, and a Codex smoke test. |
| Generate only at release and do not commit it | One on-disk source tree. | Does not fix users consuming this ordinary repository checkout. It is viable only if the published artifact is proven to be a supported, checked-out/expanded Codex marketplace root; a bare clone is not. |

## Recommendation

**Add a committed, generated native catalog — not a hand-authored duplicate —
provided the first implementation passes the acceptance test below.**

Unlike the manifest-only proposal, this solves a concrete, shipped product
truth: Codex needs to stop offering `beads-workflow` as if it were usable. The
narrow native policy overlay earns its maintenance cost
if generation makes the legacy catalog the sole catalog inventory source.

The initial native policy set is exactly:

| Plugin | Native installation policy | Reason |
| --- | --- | --- |
| `beads-workflow` | `NOT_AVAILABLE` | Commands only; Codex does not surface plugin slash commands. |
| `pr-workflow` | Available | Its skills work in Codex; only its commands are Claude Code only. |

## Required drift-prevention mechanism

The native catalog must be output, not a second hand-maintained declaration.
A generator should read the legacy catalog plus a deliberately small policy
override mapping, and emit `.agents/plugins/marketplace.json` deterministically.
CI and the release process must run the generator in `--check` mode and fail if
the committed output differs. The guard must also assert:

1. all 27 legacy entry names and sources appear exactly once in the native
   catalog;
2. the only initial policy override is the command-only entry above; and
3. a clean isolated Codex marketplace test accepts the generated catalog,
   lists the supported entries, and refuses the `NOT_AVAILABLE` entry.

That last test is a gate, not a follow-up nicety: it establishes whether a
native catalog can coexist with the current legacy per-plugin manifests. If it
cannot, do not land the catalog alone; defer it until a fully generated native
artifact has passed ADR 001's manifest/frontmatter acceptance test.

## If the recommendation is deferred

Keep the legacy catalog only until either the generated-catalog smoke test
passes or a Codex user reports installing the remaining command-only plugin
despite the README notice. The latter is the concrete deprecation-watch trigger
because it demonstrates that prose has failed to communicate a known policy
boundary.

## Consequences

This adds a second published file but not a second authored catalog. It makes
the command-only exclusion visible to Codex while preserving `pr-workflow`'s
working skills. It also deliberately stops short of native plugin manifests:
that larger compatibility and validator problem remains ADR 001's decision.

## Amendment note (2026-08-12) — as implemented

Implemented per the recommendation (generated full-inventory native catalog with
a `--check` drift guard), fixing bug `claude-plugins-0way` where a hand-authored
3-entry native catalog silently shadowed the legacy catalog and made every other
plugin uninstallable in Codex. Three facts discovered during implementation
changed the details above; recording them so the next reader does not have to
rediscover them:

1. **No native plugin manifests are required.** Codex reads a plugin's manifest
   by fallback — `.codex-plugin/plugin.json` if present, else
   `.claude-plugin/plugin.json`. Verified live on Codex CLI 0.147.0: a
   native-catalog entry for a manifest-less plugin (`thinking-tools`) installed
   and reported its Claude manifest version. So the generator emits only the
   catalog; per-plugin native manifests stay out of scope, consistent with
   ADR 001. Version alignment across the two harnesses is therefore automatic.

2. **The command-only premise is stale, so the policy set changed.** When this
   ADR was written, `beads-workflow` was command-only and slated for
   `NOT_AVAILABLE`. Every plugin has since migrated to skills — there are now
   **zero `commands/` directories repo-wide**, and `beads-workflow` ships the
   `fix-findings-beads-tasks` and `tackle-epic` skills, which work in Codex. Its
   override was **dropped**. The plugins that genuinely have nothing Codex can
   run are `publish-insights` (README-only, no `SKILL.md`) and `workspace-status`
   (a Claude Code statusline `.php`, no skills/commands/hooks). Those two carry
   `policy.installation: NOT_AVAILABLE`; nothing else does. `pr-workflow` remains
   available, as this ADR intended, because its skills work in Codex.

3. **Inventory is dynamic, not 27.** The legacy catalog now has 28 entries
   (`agentmail` was added after this ADR), plus the native-only `codex` plugin
   (it ships a `.codex-plugin` manifest and is absent from the legacy catalog),
   for 29 native entries. The generator preserves such native-only extras via a
   `nativeOnly` list in its config; the drift guard asserts against the *current*
   legacy count, never a hardcoded number.

Artifacts: generator `scripts/gen-codex-catalog.mjs` (run bare to write, `--check`
to verify), config `scripts/codex-catalog.config.json` (the only hand-edited
input — policy overlay + native-only extras), output `.agents/plugins/marketplace.json`,
drift guard `tests/codex-catalog-drift.test.mjs` (registered by an explicit line
in `tests/run-all.sh`, since repo-root suites are not glob-discovered). `docs/release.md`
§1 was corrected to describe this resolution behavior.
