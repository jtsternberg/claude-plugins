# PR Workflow (bundle)

A dependency-only bundle. It ships no skills of its own — installing it installs the five PR plugins that do:

- [address-pr-comments](../address-pr-comments) — resolve review feedback, automatically or with your approval first
- [qa-walkthrough-pr](../qa-walkthrough-pr) — guided manual QA with a generated test plan
- [update-pr-description](../update-pr-description) — regenerate a PR description from its diff
- [walk-through-work-history](../walk-through-work-history) — explain how work progressed, one page per turn
- [watch-pr-then-action](../watch-pr-then-action) — poll a PR for an event, then run a follow-up

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install all five PR plugins
claude plugin install pr-workflow@jtsternberg
```

Codex (0.148.0) does not resolve the `dependencies` field, so the bundle is not offered
there. Install the children directly instead:

```bash
codex plugin add walk-through-work-history@jtsternberg
```

## Breaking change in 2.0.0

Every skill moved into its own plugin, so every invocation namespace changed:

| Before | After |
|---|---|
| `/pr-workflow:address-pr-comments` | `/address-pr-comments:address-pr-comments` |
| `/pr-workflow:address-pr-comments-human` | `/address-pr-comments:address-pr-comments-human` |
| `/pr-workflow:qa-walkthrough-pr` | `/qa-walkthrough-pr:qa-walkthrough-pr` |
| `/pr-workflow:update-pr-description` | `/update-pr-description:update-pr-description` |
| `/pr-workflow:walk-through-work-history` | `/walk-through-work-history:walk-through-work-history` |
| `/pr-workflow:watch-pr-then-action` | `/watch-pr-then-action:watch-pr-then-action` |

Codex uses the same names with `$` instead of `/`.

## Keeping only the skills you want

The reason this bundle exists as a wrapper rather than one multi-skill plugin: you can drop
the children you don't want. Order matters (verified 2026-08-20 on Claude Code 2.1.237) —
**a child cannot be disabled while the bundle is enabled**; `claude plugin disable <child>`
fails with "still required by pr-workflow". Disable the bundle first:

```bash
claude plugin disable pr-workflow@jtsternberg   # children stay installed and enabled
claude plugin disable update-pr-description     # now this works
```

Uninstalling a child while the bundle is still enabled appears to succeed but leaves the
bundle with an unsatisfied dependency — disable the bundle first there too.

New children added to the bundle later arrive via `claude plugin update pr-workflow`
followed by `/reload-plugins`; auto-update is off by default for non-Anthropic marketplaces.

## Example Usage

Claude Code:

```text
# After making changes based on code review
/address-pr-comments:address-pr-comments

# After adding more commits to your PR
/update-pr-description:update-pr-description

# Wait for Copilot to finish, then review
/watch-pr-then-action:watch-pr-then-action 2165

# Wait for a draft PR to be marked ready, then review
/watch-pr-then-action:watch-pr-then-action 2165 for ready

# QA walkthrough for the current branch's PR
/qa-walkthrough-pr:qa-walkthrough-pr

# QA walkthrough for a specific PR
/qa-walkthrough-pr:qa-walkthrough-pr 519

# Explain a PR's work history one page at a time
/walk-through-work-history:walk-through-work-history https://github.com/org/repo/pull/123
```

Codex:

```text
# After making changes based on code review
$address-pr-comments:address-pr-comments

# After adding more commits to your PR
$update-pr-description:update-pr-description

# Wait for Copilot to finish, then review
$watch-pr-then-action:watch-pr-then-action 2165

# QA walkthrough for a specific PR
$qa-walkthrough-pr:qa-walkthrough-pr 519

# Explain a PR's work history one page at a time
$walk-through-work-history:walk-through-work-history Explain https://github.com/org/repo/pull/123.
```
