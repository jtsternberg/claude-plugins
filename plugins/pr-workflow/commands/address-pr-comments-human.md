---
description: Address PR comments with human review before push and reply (draft then approve)
argument-hint: <pr-number-or-comment-url>
---

# Address PR Comments (Human-in-the-Loop)

## Argument Parsing

Parse `$ARGUMENTS` to determine the mode:

- **Specific comment URL** — matches pattern `https://github.com/{owner}/{repo}/pull/{number}#discussion_r{id}` or `#pullrequestreview-{id}`
  - Extract: `owner`, `repo`, `pr_number`, and `comment_anchor` (the fragment after `#`)
  - This is **single-comment mode**: only address the targeted comment/review
- **PR number** (plain numeric) — address all unresolved comments on the PR

Do NOT push commits or post replies until the user approves. Write drafts first, then after approval: push and post.

## Step 1: Gather PR Comments

Use GraphQL to get the true resolution status of every thread. Do NOT guess resolution based on replies.

1. **Get the PR details**: `gh pr view {pr_number}` (use `-R {owner}/{repo}` if the URL points to a different repo than cwd)
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
   ' -f owner='{owner}' -f repo='{repo}' -F pr={pr_number}
   ```
3. **Also fetch general issue-style comments**: `gh api repos/{owner}/{repo}/issues/{pr_number}/comments`
4. **Filter to actionable items**:

   **If single-comment mode** (URL with `#discussion_r{id}` or `#pullrequestreview-{id}`):
   - Find the specific thread/review matching the anchor ID from the URL
   - For `discussion_r{id}`: match against comment `databaseId` fields in `reviewThreads` — the target thread is the one containing a comment with that `databaseId`
   - For `pullrequestreview-{id}`: match against review `databaseId` fields in `reviews`
   - **Only address that single thread/review** — ignore everything else
   - Still skip if `isResolved == true` (tell the user it's already resolved)

   **If all-comments mode** (PR number only):
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
   - Do NOT push yet
5. **Reply to the reviewer** — every comment MUST get a reply, regardless of outcome:
   - If fixed: draft a reply explaining what you changed
   - If low priority / deferred: draft a reply acknowledging the feedback, explaining why it's being deferred, and note any follow-up plans (e.g., "Good catch — this is lower priority so we'll track it separately")
   - If not valid: draft a respectful explanation of why no change is needed
   - Write the draft to `human-in-loop-drafts/pr-{number}/comment-{comment_id}.md`. Do NOT post via `gh api`.
   - Draft file format:
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
6. Mark the task complete: `bd close <task-id>`

## Step 4: Present for Approval

1. Run `bd dolt push`
2. Present the user with:
   - Path to `human-in-loop-drafts/pr-{number}/`
   - Summary table: comment ID, author, file, resolution type (fix/explanation)
   - Full commit log: `git log --oneline origin/HEAD..HEAD`
3. Ask the user to review the drafts and confirm before proceeding.

## Step 5: After User Approves

When the user approves (or asks you to proceed):

1. Run `git push`
2. Post all replies using the drafted content: `gh api repos/{owner}/{repo}/pulls/{pr_number}/comments/{comment_id}/replies -f body="<reply>"`
3. Delete the `human-in-loop-drafts/` directory
