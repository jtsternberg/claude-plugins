# QA Walkthrough PR

Guide manual QA of a pull request with a generated walkthrough and checklist. Works in Claude Code and Codex.

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
claude plugin install qa-walkthrough-pr@jtsternberg

# Codex
codex plugin add qa-walkthrough-pr@jtsternberg
```

## Skills

### `qa-walkthrough-pr`

Guided manual QA walkthrough for a PR — extracts a test plan, builds beads tasks, and walks you through each test one at a time.

Invoke `qa-walkthrough-pr` with an optional PR number or URL.

**Workflow:**
1. Gathers PR context (description, diff, HANDOFF.md if present)
2. Extracts testing steps from the PR description (or drafts a plan from the code changes)
3. Evaluates test coverage and suggests additional cases
4. Builds a beads epic with dependent tasks reflecting the testing order
5. Walks through each test interactively — one at a time, waiting for pass/fail
6. On failure: creates a bug issue with `discovered-from` linking and prepares a handoff prompt for another agent
7. Cleans up the QA epic and tasks after all tests pass

**Bundled scripts:**
- `extract-test-plan.sh` — deterministic test section extraction from PR description
- `build-qa-epic.sh` — creates epic + tasks + deps from a JSON plan in one shot
- `qa-cleanup.sh` — safe cleanup of QA artifacts with `--dry-run` support

**Prerequisites:**
- GitHub CLI (`gh`) must be installed and authenticated
- [beads](https://github.com/jtsternberg/beads) (`bd`) must be installed

## Example Usage

Claude Code:

```text
# QA walkthrough for the current branch's PR
/qa-walkthrough-pr:qa-walkthrough-pr

# QA walkthrough for a specific PR
/qa-walkthrough-pr:qa-walkthrough-pr 519
```

Codex:

```text
$qa-walkthrough-pr:qa-walkthrough-pr 519
```

## Additional Documentation

- [skills/qa-walkthrough-pr/SKILL.md](skills/qa-walkthrough-pr/SKILL.md) - Guided manual QA walkthrough

Part of the pr-workflow bundle — install pr-workflow to get all PR skills at once.
