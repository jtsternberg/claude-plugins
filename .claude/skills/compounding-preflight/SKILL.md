---
name: compounding-preflight
description: Scan a change-set against docs/compounding.md before review, PR creation, or release. Use when reviewing or creating a PR, when asked to "run the preflight" or "check against the gotchas", and as the publish-release runbook's compound step. Reports violations with the entry each one breaks, and proposes new entries the change-set teaches.
---

# Compounding Preflight

Diff-check a change-set against the ledger at [`docs/compounding.md`](../../../docs/compounding.md),
both directions: does the change **violate** an entry, and does it **teach** one?

## Steps

1. **Resolve the change-set.** Default `git diff main...HEAD` (or the staged/working
   diff if no branch delta); a PR number or explicit range wins when given.
2. **Read `docs/compounding.md` in full** — the bold headlines are the rules; the
   Known False Positives section is the list of things to NOT report.
3. **Scan the diff against each headline.** For docs/skills rules, include changed
   `*.md` files AND script headers/`--help` text. Cheap greps first (the phrases and
   patterns entries name), judgment second.
4. **Report violations** as `rule headline → file:line → one-line fix`, most severe
   first. Anything matching a Known False Positive is not a finding.
5. **Propose compounding.** If the change-set fixed a bug class, absorbed a review
   correction, or removed accreted text, draft the entry (headline + ≤3 sentences +
   provenance) and ask whether to add it — the write gate at the top of the doc
   decides format; a one-time incident does not qualify.
6. **Prune check.** Name any existing entry this change-set made obsolete or turned
   into a mechanical guard (then the entry's catch text becomes a pointer to the
   guard, or the entry is deleted).

Empty report = say so in one line. Do not restate the ledger back at the reader.
