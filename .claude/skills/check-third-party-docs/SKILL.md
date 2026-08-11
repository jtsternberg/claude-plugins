---
name: check-third-party-docs
description: "Refresh this repo's cached upstream/third-party docs and propose improvements to the local skills/docs that wrap those tools. Use when the user says 'check for updated third party docs', 'check for updated third-party docs to improve our docs', 'refresh the cached docs', or 'sync upstream docs'."
when_to_use: |
  Invoke when the user asks to check for updated third-party docs, refresh the
  cached upstream docs, or sync our docs against the tools they wrap. Repo-private
  maintainer workflow for github.com/jtsternberg/claude-plugins — keeps each local
  skill in step with the upstream CLI/API it documents.
---

# Check third-party docs

We vendor copies of the upstream docs for the external tools our skills wrap
(e.g. the MacWhisper `mw` CLI behind `work-with-media:macwhisper-cli`). This skill
re-fetches those upstream docs, shows what changed since the last cache, and
proposes edits to the local skills/docs that the change affects — so our
wrapper docs never silently drift behind the tool.

**Cached docs live in `docs/third-party/cached/*.md`.** Each is self-describing —
its frontmatter names the upstream `source` URL, when it was `last_updated`, and
the local skills/docs it informs (`related`). There is no separate manifest; the
cache dir *is* the registry. Run everything from the repo root.

## Frontmatter contract (every cached doc)

```yaml
---
source: <upstream URL>                     # what to re-fetch
cached_from: research-tools:fetch-docs --md # how it was fetched (for a matching refetch)
last_updated: <YYYY-MM-DD>                  # bumped on every refresh
related:                                    # what this doc informs, so review is mechanical
  - work-with-media:macwhisper-cli          # a skill (plugin:skill) …
  # - plugins/<plugin>/README.md            # … or an explicit repo-relative doc path
---
```

## Refresh workflow

Do this for each cached doc (all of them, or the one the user named). The order
matters — overwrite the cached file *before* diffing so `git diff` naturally
shows the committed (old upstream) version against the working-tree (new) version.

1. **Read the cached doc's frontmatter** to get its `source`, `cached_from`, and `related`.

2. **Re-fetch the source** with the `research-tools:fetch-docs` skill, matching
   `cached_from` (use `--md` when the cached copy is markdown). It writes the fresh
   copy to a `/tmp/fetch-docs-*.md` path and returns that path. Pass `--ttl=0` to
   force a live refetch and bypass fetch-docs' 24h cache.

3. **Overwrite the cached file** — replace its body with the fresh `/tmp` fetch and
   refresh the frontmatter: keep `source`/`cached_from`/`related`, bump `last_updated`
   to today (`date +%F`). Store the fetch **body exactly as fetched** — never hand-clean
   it — so the next refresh diffs against the same pipeline output instead of fighting
   your edits. Example, run from the repo root:

   ```bash
   DATE=$(date +%F)
   CACHED=docs/third-party/cached/<name>.md
   TMP=<the /tmp path fetch-docs returned>
   {
     printf -- '---\n'
     printf 'source: %s\n' "<source url>"
     printf 'cached_from: research-tools:fetch-docs --md\n'
     printf 'last_updated: %s\n' "$DATE"
     printf 'related:\n'
     printf '  - <plugin:skill or repo path>\n'
     printf -- '---\n\n'
     cat "$TMP"
   } > "$CACHED"
   ```

4. **Diff to see what changed upstream:**

   ```bash
   git diff -- docs/third-party/cached/<name>.md
   ```

   `last_updated` in the frontmatter always shows as changed — ignore it. Read the
   **body** hunks: new/removed flags, changed defaults, renamed commands, new
   features, new gotchas.

5. **Propose local edits.** For each entry in `related`, open that skill/doc and
   compare it against what the diff revealed. Surface concrete, specific suggestions
   (new flag to document, corrected default, a gotcha worth a troubleshooting bullet).
   **Do not auto-apply** — present the suggestions and let the user pick. Applying is a
   follow-up once they choose.

6. If a cached doc's upstream is unchanged, say so and move on — no edits, no noise.

## Adding a new cached doc

To bring a new third-party tool under this workflow:

1. Fetch it with `research-tools:fetch-docs` (`--md` for HTML sources).
2. Write it to `docs/third-party/cached/<name>.md` with the frontmatter contract
   above — set `related` to the skill(s)/doc(s) that wrap that tool.
3. Commit it. It's now part of every future refresh automatically (the cache dir is
   globbed, not listed).

## Notes

- **No baseline?** A brand-new cached doc has nothing to diff against, but you can
  still review its `related` skill/docs against the doc's *content* — that's exactly
  how the seed MacWhisper entry was reviewed.
- **First-fetch review vs. refresh review** produce the same deliverable: a list of
  concrete improvement suggestions for the `related` files.
- This is a **repo-private** skill (`.claude/skills/`), not a published plugin — it's
  a maintainer workflow specific to this repository's layout.
