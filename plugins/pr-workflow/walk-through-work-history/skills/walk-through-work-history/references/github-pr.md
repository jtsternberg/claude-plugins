# GitHub pull request walkthroughs

Use this reference when the work artifact is a GitHub pull request.

## Collect the complete record

Prefer connected GitHub tools for structured PR data. Use `gh` when it exposes chronology, pagination, or local repository context more clearly.

Collect before writing page 1:

- PR metadata: title, author, state, draft transitions, creation, closure, merge, base/head refs, final head SHA, merge SHA, and diff size.
- Every PR commit with authored/committed time, author, SHA, subject, and body.
- Conversation comments.
- Review submissions with author, state, timestamp, anchored commit, and body.
- Inline review comments and replies, including paths and whether threads were later resolved.
- Important timeline events: review requests, dismissals, ready-for-review changes, base updates, and merge.
- CI/check results at the heads that mattered to the story.
- The final PR description and diff surface.

Useful `gh` starting points:

```bash
gh pr view <number> --repo <owner/repo> \
  --json number,title,state,isDraft,createdAt,updatedAt,closedAt,mergedAt,mergedBy,author,baseRefName,headRefName,headRefOid,mergeCommit,additions,deletions,changedFiles,commits,reviews,comments,statusCheckRollup

gh api --paginate repos/<owner>/<repo>/pulls/<number>/comments
gh api --paginate repos/<owner>/<repo>/pulls/<number>/reviews
gh api --paginate repos/<owner>/<repo>/issues/<number>/comments
```

Use GraphQL or a connected GitHub review-thread tool when thread resolution state or timeline events are important. Keep retrieval read-only unless the user explicitly asks to change the PR.

## Build the event ledger

Normalize every meaningful event into:

| Field | Meaning |
|---|---|
| Time | When it happened |
| Actor | Who acted |
| Event | Review, comment, commit, merge, check, or state transition |
| Why | Stated rationale or finding |
| Consequence | What changed or what became necessary next |
| Evidence | Direct GitHub URL or SHA |

Sort chronologically, then connect related rows. A review and its twenty inline comments are usually one narrative event; the answering commits form the next event.

## Choose chapter boundaries

Good boundaries include:

- initial implementation and first review;
- inactivity followed by branch refresh;
- mocked tests passing but live validation failing;
- approval followed by meaningful new commits;
- blast-radius discoveries that expand scope;
- a contract redesign rather than a local fix;
- re-test, corrected diagnosis, and deferred follow-ups;
- final verification, description correction, and merge.

Do not create a chapter solely because the calendar month changed.

## Avoid common history errors

- GitHub shows the latest PR body, which may have been rewritten before merge. Do not quote it as the opening description without evidence.
- A review's current `DISMISSED` state does not mean it was non-blocking when submitted.
- Resolved threads can still represent major earlier blockers.
- An approval applies to the reviewed commit. Later scope can make it stale even if GitHub still displays the approval.
- Merge-from-base commits are synchronization events, not product features.
- Bot-authored PRs can contain human-authored follow-up commits and decisions; attribute each event individually.
- Commit messages describe intent, not proof. Cross-check behavior claims against review replies, tests, or live-validation comments.
- Later comments may correct an earlier root-cause claim. Tell both parts: the original diagnosis and the correction.

## Page content pattern

Each page should normally contain:

1. A phase title.
2. The state entering the phase.
3. Two to four consequential events.
4. Why those events changed the next phase.
5. One concise transition or cliffhanger.
6. The exact turn-page prompt.

On the final page, replace the turn-page prompt with the outcome and a compact progression summary.
