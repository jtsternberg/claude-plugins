# Setting up gcloud ADC for the md-to-google-doc rung-2 fallback

This is only needed if `gws` can't reach the target account (e.g. a work
Google account) and you want create + **update-in-place**, PAGELESS-mode
control, and table-cell fidelity that the connector rung (rung 3) can't do.
If you don't need update-in-place or those extras, skip it — rung 3 works
with zero setup (create-only, no PAGELESS control, no emphasis inside table
cells).

## 1. Auth (gcloud ADC, your own account)

```bash
gcloud auth login
gcloud auth application-default login \
  --scopes=openid,https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/drive,https://www.googleapis.com/auth/documents
```

The **full `drive` scope is required** (not `drive.file`) — updating a doc
this script may not have created itself (e.g. state file lost, or first run
targets an existing doc) needs read/write access beyond the app sandbox.

## 2. A GCP project with the Drive + Docs APIs enabled, set as the ADC quota project

```bash
gcloud projects create <a-project-id> --name="ADC md-to-gdoc"   # or reuse an existing one
gcloud services enable drive.googleapis.com docs.googleapis.com --project=<PROJECT>
gcloud auth application-default set-quota-project <PROJECT>
```

(Drive/Docs API quotas are free — no billing account required.)

## Update-in-place state file

Rendered docs are tracked in `~/.config/gws-md-to-gdoc/rendered.json`,
keyed by the absolute path of the source markdown file. Rerunning
`adc-create.sh` against the same source file updates that doc's content in
place instead of creating a duplicate; pass `--new` to force a fresh doc.
If the remembered doc ID no longer exists or isn't accessible (403/404),
the script falls back to creating a new one and updates the state entry
automatically.

## Gotchas

- **`GOOGLE_APPLICATION_CREDENTIALS` shadows ADC.** If this env var is set
  globally (e.g. pointing at a Firebase/service-account key from an
  unrelated project), it silently overrides the
  `gcloud auth application-default login` credentials. Unset it
  (`env -u GOOGLE_APPLICATION_CREDENTIALS …`) or scope it narrowly.
- **Full `drive` scope, not `drive.file`.** Same reasoning as
  selfreview-to-gdoc's auth spike — `drive.file` 404s on files this
  credential didn't create.
- **Org policy caveat.** Whether a Workspace org allows granting the full
  `drive` scope via ADC is an org-policy decision. Works for the author's
  account as of 2026-07 — verify `adc-check.sh` passes on your own account
  before relying on this rung; don't assume it for every Workspace.

## Verifying it worked

```bash
gcloud auth application-default print-access-token >/dev/null && echo "ADC OK"
```

or just run the skill's `adc-check.sh` — same check, actionable message on
failure.
