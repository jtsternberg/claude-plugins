# Walk Through Work History

Explain how work progressed — PR, branch, or project — one page at a time. Works in Claude Code and Codex.

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
claude plugin install walk-through-work-history@jtsternberg

# Codex
codex plugin add walk-through-work-history@jtsternberg
```

## Skills

### `walk-through-work-history`

Research a PR's complete progression, divide it into causal chapters, and explain one concise page per user turn.

Claude Code:

```text
/walk-through-work-history:walk-through-work-history https://github.com/org/repo/pull/123
```

Codex invocation:

```text
$walk-through-work-history:walk-through-work-history Explain https://github.com/org/repo/pull/123 one page at a time.
```

**Workflow:**
1. Collects commits, reviews, comments, inline threads, state changes, checks, and final PR metadata
2. Reconstructs the full event history before narrating
3. Groups events into causal chapters instead of dumping a raw timeline
4. Delivers exactly one adult, ADHD-friendly page per turn
5. Preserves stale approvals, reversals, wrong diagnoses, and later corrections
6. Ends each non-final page by asking whether to turn the page

Although optimized for GitHub PRs, the same method can explain issues, branches, incidents, documents, tickets, and other chronological work records. Google Docs have their own bundled reference: it walks down an access ladder (connected Drive tools, a Workspace CLI, raw Drive REST with any OAuth token, then the browser UI) and is explicit about which parts of a Doc's history the APIs cannot return — comment threads are rich, revision lists are incomplete for busy docs, and accepted suggestions leave no record.

## Additional Documentation

- [skills/walk-through-work-history/SKILL.md](skills/walk-through-work-history/SKILL.md) - Paginated work-history walkthrough
- [skills/walk-through-work-history/references/github-pr.md](skills/walk-through-work-history/references/github-pr.md) - Collecting a pull request's full record
- [skills/walk-through-work-history/references/google-doc.md](skills/walk-through-work-history/references/google-doc.md) - Collecting a Google Doc's revisions, comments, and activity

Part of the pr-workflow bundle — install pr-workflow to get all PR skills at once.
