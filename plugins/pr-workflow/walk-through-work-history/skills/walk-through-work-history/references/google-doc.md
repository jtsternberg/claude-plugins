# Google Doc walkthroughs

Use this reference when the work artifact is a Google Doc. The same Drive endpoints cover
Sheets and Slides; only the "final content" call differs.

## What the evidence is, and where it stops

A Doc's history is only partly retrievable. Establish which parts you can actually get
**before** promising a walkthrough:

| Source | What you get | Limit |
|---|---|---|
| Comments and replies | author, create/modify time, quoted anchor text, resolved state, deleted threads | none significant — the richest evidence a Doc has |
| Revisions | timestamp and last modifying user per listed revision, plus export links for that revision's content | the list is **incomplete for frequently edited Docs** — Drive's own API reference says older revisions may be omitted and the editor UI may show more |
| Suggested edits | only *pending* suggestions, from the Docs API | accepted and rejected suggestions leave no retrievable record |
| Drive activity | per-actor edit, comment, rename, and move events with timestamps | event classes only, no content diffs |
| Current document | final text and structure | one point in time |

So a Doc walkthrough is normally a story of **comment threads and coarse revision
milestones**, not a fine-grained edit history. State that limit once, early, rather than
implying the record is complete.

## Establish an access path first

Assume nothing is installed. Work down this ladder until a rung answers, and name the rung
to the user whenever it limits the story.

The `fileId` is the URL segment after `/document/d/`:
`https://docs.google.com/document/d/<fileId>/edit`.

**Rung 1 — connected Drive or Docs tools.** If the harness exposes them (an MCP connector,
for example), they typically read file content and metadata and expose **no comments and no
revisions**. Enough for final state, not for progression.

**Rung 2 — a Google Workspace CLI.** Check, don't assume:

```bash
command -v gws
```

If present it wraps the Drive and Docs REST APIs directly; see the commands below. Add
`--dry-run` to any call to check the URL and parameters it would send without sending it.

**Rung 3 — raw Drive REST with any OAuth token.** The APIs are the substrate, so anything
that yields a bearer token carrying a Drive read scope works: a token already in the
environment, one the user supplies, or Application Default Credentials.

```bash
command -v gcloud && TOKEN="$(gcloud auth application-default print-access-token)"
```

An ADC token carries only the scopes its `gcloud auth application-default login --scopes=…`
granted — `cloud-platform` alone does **not** include Drive. If the ADC credentials file
names a `quota_project_id`, send it as an `X-Goog-User-Project` header or the call fails
with `SERVICE_DISABLED`.

**Rung 4 — no API access.** The history then lives only in the UI, which is *more* complete
than the API. Ask the user for what only they can reach: File → Version history → See
version history (named versions plus the per-session list), and the comment pane's All
comments view, which includes resolved threads. Browser automation driving their
already-authenticated session is a valid substitute. Read what the user pointed you at;
never route doc content through an unrelated service.

If no rung answers, say so before page 1. A thin history narrated confidently is worse than
naming what you can and cannot see.

Scopes: comments and revisions need `drive.readonly`, `drive.file`, or `drive`; Drive
activity needs `drive.activity.readonly`. A 403 usually means a missing scope. A 404 on a
doc the user can open in a browser usually means the token belongs to a different Google
account than the doc — check which account is authenticated before concluding the doc is
gone.

## Fetch commands

Comments with replies. The API requires the `fields` parameter, and `includeDeleted`
recovers deleted threads:

```bash
gws drive comments list --params '{"fileId":"<fileId>","fields":"*","includeDeleted":true,"pageSize":100}' --page-all
```

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://www.googleapis.com/drive/v3/files/<fileId>/comments?fields=*&includeDeleted=true&pageSize=100"
```

Revisions:

```bash
gws drive revisions list --params '{"fileId":"<fileId>","fields":"*","pageSize":1000}' --page-all

curl -s -H "Authorization: Bearer $TOKEN" \
  "https://www.googleapis.com/drive/v3/files/<fileId>/revisions?fields=*&pageSize=1000"
```

Exporting consecutive revisions and diffing them is the only way to see *what* changed. For
Docs editors files, `alt=media` does not work — use the revision's own `exportLinks`, which
already carry the right format and revision parameters:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://www.googleapis.com/drive/v3/files/<fileId>/revisions/<revisionId>?fields=exportLinks" \
  -o rev-<revisionId>.json
# then fetch the text/plain (or text/markdown, if structure carries the story) link from that JSON
curl -sL -H "Authorization: Bearer $TOKEN" "<exportLink>" -o rev-<revisionId>.txt
```

Save each export to a file and diff the files. Do not pipe API output straight into a
parser — when a call returns an error page instead of content, the raw response on disk is
what tells you.

Per-actor activity, useful when the revision list is sparse:

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"itemName":"items/<fileId>","pageSize":100}' \
  https://driveactivity.googleapis.com/v2/activity:query
```

Final content, including pending suggestions:

```bash
gws docs documents get --params '{"documentId":"<fileId>","suggestionsViewMode":"SUGGESTIONS_INLINE"}'
```

Keep every call read-only. Never write, resolve a comment, or restore a revision while
researching.

## Build the event ledger

Normalize into the ledger fields SKILL.md step 2 names, with Doc-specific sourcing:

- A comment thread is one event, not one per reply. Its resolution is a separate, later
  event — often by a different actor.
- Use each comment's `quotedFileContent` as the evidence of what the commenter was reacting
  to. It preserves the anchor text as it was; the live document does not.
- Pair a revision with the comment thread it answers by timestamp, then verify against the
  exported diff. Adjacency alone is not causation.
- Evidence links: a comment thread is usually addressable as `…/edit?disco=<commentId>`; a
  revision has no shareable URL, so cite its id and timestamp instead of inventing one.

## Chapter boundaries

Good ones:

- first complete draft, then the first round of comments;
- an objection that changed the document's structure rather than its wording;
- a new actor starting to edit — ownership handoff;
- a rewrite, visible as a large delta between consecutive exported revisions;
- a suggestion-mode phase versus direct editing;
- threads going quiet, then resolved in bulk, then sign-off.

Do not chapter by revision. Most revisions are autosaves.

## Avoid common history errors

- Missing revisions are gaps, not calm periods. Sparse revisions plus a large delta means
  "we cannot see how this changed," not "it changed in one step."
- A resolved thread is not a withdrawn objection. Describe its state at each point in time.
- The current text is the *final* text. Never quote it as what a commenter was reacting
  to — quote that comment's `quotedFileContent` instead.
- Anchors go stale. When a comment points at text that no longer exists, say the anchor was
  lost instead of guessing what it meant.
- A comment's `modifiedTime` moves when it is edited or replied to. Only `createdTime`
  places it in the timeline.
- `lastModifyingUser` is populated only for signed-in users, and org-owned docs can withhold
  actor detail from outside accounts. Attribute cautiously when actors come back empty.
- A named version's title is an author's claim about the state, not evidence of it.
- Accepted suggestions are invisible after the fact. Do not read a clean document as
  evidence that no one proposed changes.
