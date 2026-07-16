# Plan: Three-rung source routing for `google-doc-to-md` and `md-to-google-doc`

**Date:** 2026-07-14
**Status:** Approved direction — three rungs confirmed by JT
**Home:** `plugins/gws/skills/google-doc-to-md/` and `plugins/gws/skills/md-to-google-doc/` (upgrade in place; no new skill, no wrapper)

## Problem

The gws CLI only authenticates JT's personal Google account. Work-account docs
(jsternberg@awesomemotive.com) are reachable only via the claude.ai Google
Drive MCP connector (`mcp__claude_ai_Google_Drive__*`) or via gcloud
ADC + direct Google APIs. Both skills should route to whatever source can
reach the doc, preferring the highest-fidelity path, and degrade loudly.

## Verified facts (live smoke tests, 2026-07-14 — `/tmp/gdoc-connector-smoke-results.md`)

1. **Connector has no clean markdown export.** Both
   `download_file_content(exportMimeType: "text/markdown")` and
   `read_file_content` return backslash-escaped markdown (`\#`, `\[`, `\*`, …).
   A deterministic de-escaper is required on the connector read path.
2. **Connector `create_file(contentMimeType: "text/markdown")` works** —
   produces a real formatted Google Doc (headings, bold, links, lists, tables).
   Limits: no emphasis inside table cells (stays literal), no `documentMode`
   (pageless) control, `update_file` has no content param (create-only),
   `trash_file` fails with permission error (no delete → no temp-doc tricks).
3. **ADC/Docs-API route works against the work account** — proven by the
   `selfreview-to-gdoc` skill (`~/Library/CloudStorage/Dropbox/Prefs/Claude/skills/selfreview-to-gdoc/`).
   Auth: `gcloud auth login` + `gcloud auth application-default login` with
   full `drive` + `documents` scopes and a quota project. Full Docs API:
   create, update-in-place via batchUpdate, table-cell styling, deletes,
   pageless via batchUpdate. Caveat: depends on Workspace org policy allowing
   the scope grant (works for JT today).

## Routing design

Each skill's SKILL.md gets a "Source routing" section. Rungs are progressively
disclosed — the model attempts rung 1 and only reads deeper instructions and
runs deeper scripts on fallthrough. Detection is try-then-fallback, not
account pre-mapping.

### `google-doc-to-md` (doc → markdown)

1. **gws** (unchanged current behavior): `gws drive files export`
   text/markdown — clean native export. Fall through on auth/403/404-for-account.
2. **ADC** (new, optional-if-configured): if ADC creds exist
   (`gcloud auth application-default print-access-token` succeeds), call Drive
   `files.export(mimeType=text/markdown)` via a small script — same clean
   native export as gws, just different auth. Skip silently if ADC not set up.
3. **Connector**: `download_file_content(exportMimeType: "text/markdown")`
   (base64-decode) → pipe through `deescape.py`. Only if the connector tools
   are available this session. If no rung works: fail with a clear message.

Note: rungs 1 and 2 produce identical output (same server-side exporter); rung
2 exists so a work-account doc gets the clean path when ADC is configured,
instead of the de-escaped connector path.

### `md-to-google-doc` (markdown → Doc)

1. **gws** (unchanged): full create/update/tab-update via native import.
2. **ADC** (new): direct Drive/Docs API. Create via `files.create` with
   markdown upload (same server-side importer), then `batchUpdate` to set
   PAGELESS. Update-in-place: remember created doc IDs in a state file
   (pattern from selfreview-to-gdoc's `rendered.json`) and batchUpdate the
   existing doc on rerun. Steal from selfreview-to-gdoc: `parse_inline`
   tokenizer, single-insertText + offset-keyed style requests, bottom-up
   descending-index batch ordering, 403/404 `doc_exists` fallback, two-client
   auth bootstrap, `--dry-run`.
3. **Connector** (degraded, zero-setup): `create_file` with
   `contentMimeType: "text/markdown"`. Create-only; document the limits
   (paged mode, no table-cell emphasis, no update, no delete). Refuse update
   requests on this rung with a pointer to rung 2 setup.

## Work items

1. **Port from claude-dropbox** (`~/Library/CloudStorage/Dropbox/Prefs/Claude/skills/`):
   `deescape.py` + `tests/test_deescape.py` (14 passing tests) into
   `google-doc-to-md/`; review `extract-doc-id.sh`/`derive-title.sh`/`clean.sh`
   against the gws skill's existing equivalents (gws versions likely win —
   don't duplicate).
2. **New ADC scripts** in each skill (`scripts/adc-*.{sh,py}`): auth-check,
   export (doc→md), create/update (md→doc). Python via `~/.venvs/genai/bin/python3`
   convention noted in SKILL.md; reference selfreview-to-gdoc modules rather
   than vendoring where the code is a pattern, copy where it's a function.
3. **SKILL.md rewrites**: routing section per above; `allowed-tools` grows to
   include the connector MCP tools; connector-rung instructions are
   model-driven tool calls piped to scripts. ADC setup instructions live in a
   `references/adc-setup.md` loaded only on rung-2 fallthrough.
4. **Delete the claude-dropbox skill dirs** after porting
   (`connector-google-doc-to-md/`, `md-to-google-doc/` under Dropbox Prefs) —
   the latter name-collides with the gws skill.
5. **Version bump** gws plugin (minor — new feature), single bump after QA
   per memory `feedback_version_bump_timing`.
6. **AM Skills sync**: check `.amskills.json` for mappings of these two skills;
   publish updates via `managing-am-skills` if mapped.

## Verification

- `deescape.py` tests pass in their new home; add a fixture built from the
  smoke-test excerpts (`\[TEMPLATE\]`, `\#687`).
- ADC rung: live test both directions against a work-account doc (JT session).
- Connector rung: live test in a connector-authed session (doc→md de-escaped
  output clean; md→doc renders formatted).
- gws rung: regression — existing behavior unchanged on a personal-account doc.

## Open items

- JT: manually delete "SMOKE TEST - connector md import (delete me)"
  (id `1OU4T2ipER08uvKYv-kWE1lAWFcwHHt0K0YJceRq48A8`) from work Drive —
  connector couldn't trash it.
- Decide whether ADC state file for update-in-place lives at
  `~/.config/gws-md-to-gdoc/` or inside the skill dir (lean `~/.config`).
- Org-policy caveat: ADC scope grant works for JT today; document as a
  prerequisite check, not an assumption, for other users.
