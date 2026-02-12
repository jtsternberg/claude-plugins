---
description: Address all PR comments by reviewing, fixing, committing, and replying
argument-hint: <pr-number> [--human]
---

# Address PR Comments

Parse `$ARGUMENTS` to extract:
- **PR number**: the numeric argument
- **`--human` flag**: if present, enable Human-in-the-Loop mode

## Human-in-the-Loop Mode (`--human`)

When the `--human` flag is passed, do NOT push commits or post replies automatically. Instead:

1. **After making code changes and committing locally**, write a draft file to `human-in-loop-drafts/pr-{number}/` for each comment:
   - File name: `comment-{comment_id}.md`
   - Contents:
     ```
     # Comment by @{author}
     **File:** {file}:{line}
     **Comment:** {comment text}
     **Link:** {html_url}

     ## Code Changes
     {`git show --stat` output for the commit, or "No changes — explanation only"}

     ## Commit Message
     {full commit message}

     ## Proposed Reply
     {the reply you would post}
     ```
2. **Do not run `git push` or post any `gh api` replies.**
3. After all comments are drafted, present the user with:
   - The path to the drafts directory
   - A summary table: comment ID, author, file, resolution type (fix/explanation)
   - The full commit log: `git log --oneline origin/HEAD..HEAD`
4. **Wait for the user to review.** When the user approves (or asks you to proceed):
   - Run `git push`
   - Post all replies using the drafted content
   - Clean up the `human-in-loop-drafts/` directory

## Step 1: Gather PR Comments

Use GraphQL to get the true resolution status of every thread. Do NOT guess resolution based on replies.

1. **Get the PR details**: `gh pr view $ARGUMENTS`
2. **Fetch all review threads with resolution status** using GraphQL:
   ```
   gh api graphql -f query='
     query($owner: String!, $repo: String!, $pr: Int!) {
       repository(owner: $owner, name: $repo) {
         pullRequest(number: $pr) {
           reviews(last: 50) {
             nodes {
               id, databaseId, state, author { login }, body, url
             }
           }
           reviewThreads(last: 100) {
             nodes {
               isResolved
               comments(first: 50) {
                 nodes {
                   id, databaseId, author { login }, body, path, line, url
                 }
               }
             }
           }
         }
       }
     }
   ' -f owner='{owner}' -f repo='{repo}' -F pr=$ARGUMENTS
   ```
3. **Also fetch general issue-style comments**: `gh api repos/{owner}/{repo}/issues/$ARGUMENTS/comments`
4. **Filter to actionable items only**:
   - **SKIP** threads where `isResolved == true` — these are already resolved in GitHub
   - **SKIP** your own comments (not replies to others)
   - **INCLUDE** all unresolved review threads — from human reviewers and bots alike (Copilot, sentry[bot], etc. can surface real issues)
   - **INCLUDE** top-level reviews with state `CHANGES_REQUESTED` that have not been superseded by a newer `APPROVED` or `DISMISSED` review from the same author
   - **INCLUDE** unresolved review threads even if you previously replied — a reply does NOT mean resolved

## Step 2: Create Beads Tasks

For each comment that needs addressing, create a beads (`bd create`) task.

Include in the description:
- The comment author
- The file and line referenced
- The full comment text
- A link to the comment (use the `html_url` field)

## Step 3: Address Each Comment

For each task (one at a time, in order):

1. Mark the task in progress: `bd update <task-id> --status=in_progress`
2. **Read the code** at the file and line referenced in the comment
3. **Evaluate the comment**:
   - Is this a valid issue? Understand the reviewer's concern fully.
   - If valid and worth fixing now: implement the fix
   - If valid but low priority: note it as acknowledged but deferred
   - If not valid: prepare a clear, respectful explanation of why the current code is correct
4. **If a fix was made**:
   - Stage only the affected files
   - Commit with a message referencing the PR comment (e.g., `Fix: address review feedback on <file> — <what changed>`)
   - **If `--human`**: do NOT push yet
   - **If not `--human`**: push the commit: `git push`
5. **Reply to the reviewer** — every comment MUST get a reply, regardless of outcome:
   - If fixed: draft a reply explaining what you changed
   - If low priority / deferred: draft a reply acknowledging the feedback, explaining why it's being deferred, and note any follow-up plans (e.g., "Good catch — this is lower priority so we'll track it separately")
   - If not valid: draft a respectful explanation of why no change is needed
   - **If `--human`**: write the draft to `human-in-loop-drafts/pr-{number}/comment-{comment_id}.md` (see format above). Do NOT post via `gh api`.
   - **If not `--human`**: post immediately using `gh api repos/{owner}/{repo}/pulls/$ARGUMENTS/comments/{comment_id}/replies -f body="<reply>"`
6. Mark the task complete: `bd close <task-id>`

## Step 4: Final Summary

After all comments are addressed:

**If `--human`:**
1. Run `bd sync --flush-only`
2. Present the user with:
   - Path to `human-in-loop-drafts/pr-{number}/`
   - Summary table of all comments and their resolutions
   - Full commit log: `git log --oneline origin/HEAD..HEAD`
3. Ask the user to review the drafts and confirm before proceeding
4. Once approved: push all commits, post all replies, and delete `human-in-loop-drafts/`

**If not `--human`:**
1. Run `bd sync --flush-only`
2. Summarize what was done:
   - How many comments were addressed (with links to each comment)
   - How many resulted in code changes vs. explanations
   - List each comment and its resolution
