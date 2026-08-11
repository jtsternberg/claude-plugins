# Explicit-only invocation policy

Status as of 2026-08-11: Codex and Claude Code still use different declarations for user-only skills.

- Claude Code: `disable-model-invocation: true` in `SKILL.md` frontmatter.
- Codex: `policy.allow_implicit_invocation: false` in the sibling `agents/openai.yaml`.

OpenAI's current skill docs describe `agents/openai.yaml` as the place to set invocation policy and say `allow_implicit_invocation: false` prevents automatic routing while leaving explicit `$skill` invocation available. The Responses API skill docs still describe model-visible routing from `SKILL.md` name/description, so the repo keeps Codex routing vocabulary in `description` for implicitly invocable skills.

Upstream state checked on 2026-08-11:

- openai/codex#23454 remains open for explicit `$skill` failures involving explicit-only skills absent from the implicit list.
- openai/codex#29989 remains open for native support of `disable-model-invocation` in `SKILL.md`.
- openai/codex#32169 remains open for explicit-only activation loss after compaction.

## Decision

Mirror every Claude explicit-only skill into Codex's policy file, regardless of side-effect class.

That means:

```yaml
policy:
  allow_implicit_invocation: false
```

Any skill with `disable-model-invocation: true` must have the Codex policy above, and any skill with that Codex policy must also have `disable-model-invocation: true`. The guard is intentionally bidirectional so a skill cannot be explicit-only in only one harness.

Read-only/advisory explicit-only skills keep the same policy. The point is not only side-effect safety; it is preserving the author's selected invocation contract across harnesses.

## Current inventory

Regenerate this inventory with:

```bash
node scripts/audit-explicit-invocation-policy.mjs
```

Current summary:

- Explicit-only skills: 33
- Codex explicit-only policies: 33
- coordination-side-effect: 1
- external-side-effect: 4
- local-side-effect: 19
- read-only-or-advisory: 9

| Skill | Side-effect risk | Policy |
| --- | --- | --- |
| `beads-workflow:fix-findings-beads-tasks` | local-side-effect | explicit-only in both harnesses |
| `beads-workflow:tackle-epic` | local-side-effect | explicit-only in both harnesses |
| `bible:bible-nlt-lookup` | read-only-or-advisory | explicit-only in both harnesses |
| `export-presentation:export-presentation` | local-side-effect | explicit-only in both harnesses |
| `generating-blog-images:blog-image-prompts` | read-only-or-advisory | explicit-only in both harnesses |
| `git-commits:commit-staged` | local-side-effect | explicit-only in both harnesses |
| `git-commits:commit-unstaged` | local-side-effect | explicit-only in both harnesses |
| `git-tree:create-git-tree` | local-side-effect | explicit-only in both harnesses |
| `gws:google-doc-to-md` | local-side-effect | explicit-only in both harnesses |
| `gws:md-to-google-doc` | external-side-effect | explicit-only in both harnesses |
| `headline-refiner:headline-refiner` | read-only-or-advisory | explicit-only in both harnesses |
| `hotline:hotline-add-contact` | local-side-effect | explicit-only in both harnesses |
| `hotline:hotline-pickup` | local-side-effect | explicit-only in both harnesses |
| `hotline:hotline-ringing` | coordination-side-effect | explicit-only in both harnesses |
| `hotline:hotline-whoami` | read-only-or-advisory | explicit-only in both harnesses |
| `mac-caffeinate:caffeinate-computer` | local-side-effect | explicit-only in both harnesses |
| `paperclip:paperclip` | local-side-effect | explicit-only in both harnesses |
| `pr-workflow:address-pr-comments-human` | local-side-effect | explicit-only in both harnesses |
| `pr-workflow:address-pr-comments` | external-side-effect | explicit-only in both harnesses |
| `pr-workflow:qa-walkthrough-pr` | local-side-effect | explicit-only in both harnesses |
| `pr-workflow:update-pr-description` | external-side-effect | explicit-only in both harnesses |
| `pr-workflow:watch-pr-then-action` | external-side-effect | explicit-only in both harnesses |
| `session-tools:note-to-self` | local-side-effect | explicit-only in both harnesses |
| `session-tools:sessions-catch-up` | read-only-or-advisory | explicit-only in both harnesses |
| `session-tools:sessions-fork` | read-only-or-advisory | explicit-only in both harnesses |
| `session-tools:sessions-weekly-recap` | local-side-effect | explicit-only in both harnesses |
| `skill-tools:create-skill` | local-side-effect | explicit-only in both harnesses |
| `skill-tools:create-slash-command` | local-side-effect | explicit-only in both harnesses |
| `skill-tools:create-subagent` | local-side-effect | explicit-only in both harnesses |
| `skill-tools:review-skill` | read-only-or-advisory | explicit-only in both harnesses |
| `skill-tools:review-slash-command` | read-only-or-advisory | explicit-only in both harnesses |
| `skill-tools:validate-dual-harness-skill` | read-only-or-advisory | explicit-only in both harnesses |
| `slides-presentation:create-slides-presentation` | local-side-effect | explicit-only in both harnesses |

## Live Codex probe

Installed runtime: `codex-cli 0.147.0`.

Probe shape:

1. Create a temporary workspace with only a repo-local `.agents/skills/explicit-only-probe-20260811` fixture.
2. Give the fixture a distinctive marker in its `description`, `disable-model-invocation: true`, and `agents/openai.yaml` with `allow_implicit_invocation: false`.
3. Run a fresh `codex exec --ignore-user-config --ephemeral --skip-git-repo-check` session with an ordinary prompt containing the marker.
4. Run a second fresh session with direct `$explicit-only-probe-20260811`.
5. Run a positive-control implicit fixture with `allow_implicit_invocation: true`.

Result:

- Explicit-only implicit prompt: exit 0, did not read `SKILL.md`, and answered that the ordinary prompt did not trigger the special probe instructions.
- Explicit `$explicit-only-probe-20260811`: exit 0, read `.agents/skills/explicit-only-probe-20260811/SKILL.md`, and returned `EXPLICIT_PROBE_SKILL_LOADED`.
- Positive-control implicit skill: exit 0, read `.agents/skills/implicit-positive-probe-20260811/SKILL.md`, and returned `IMPLICIT_POSITIVE_SKILL_LOADED`.

Codex emitted a description-budget warning during the probes because bundled/system skills were still present even with `--ignore-user-config`. That does not weaken the result: the positive control with the same setup implicitly activated, while the explicit-only skill did not.

## Retest triggers

Repeat the probe and re-run the audit when any of these changes:

- Codex CLI version changes.
- OpenAI docs change the `agents/openai.yaml` policy contract.
- openai/codex#23454, #29989, or #32169 is closed or materially updated.
- A skill adds or removes `disable-model-invocation`.
- Long-task or compaction behavior for explicit-only skills changes. This audit covers invocation policy only; the `handoff` plugin is not part of the explicit-only inventory as of this check.
