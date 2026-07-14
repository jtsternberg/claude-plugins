# Setting up gcloud ADC for the google-doc-to-md rung-2 fallback

This is only needed if `gws` can't reach the target account (e.g. a work
Google account) and you want the clean native export instead of the
de-escaped connector path. If you don't need this, skip it — the connector
rung (rung 3) works with zero setup, just with a de-escape pass.

## 1. Auth (gcloud ADC, your own account)

```bash
gcloud auth login
gcloud auth application-default login \
  --scopes=openid,https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/drive,https://www.googleapis.com/auth/documents
```

The **full `drive` scope is required** (not `drive.file`) — exporting an
arbitrary pre-existing doc needs read access to a file this script did not
create, which `drive.file` (the app-sandbox scope) cannot grant.

## 2. A GCP project with the Drive API enabled, set as the ADC quota project

```bash
gcloud projects create <a-project-id> --name="ADC gdoc export"   # or reuse an existing one
gcloud services enable drive.googleapis.com --project=<PROJECT>
gcloud auth application-default set-quota-project <PROJECT>
```

(Drive API quotas are free — no billing account required.)

## Gotchas

- **`GOOGLE_APPLICATION_CREDENTIALS` shadows ADC.** If this env var is set
  globally (e.g. pointing at a Firebase/service-account key from an unrelated
  project), it silently overrides the `gcloud auth application-default login`
  credentials. Unset it (`env -u GOOGLE_APPLICATION_CREDENTIALS …`) or scope
  it to only the shells/projects that need it.
- **Full `drive` scope, not `drive.file`.** `drive.file` only sees files the
  authenticating app created — it 404s on docs you didn't create through
  this credential. This bit selfreview-to-gdoc during its own auth spike.
- **Org policy caveat.** Whether a Workspace org allows granting the full
  `drive` scope via ADC is an org-policy decision, not something this script
  controls. It works for the author's account as of 2026-07 — verify the
  `adc-check.sh` preflight passes on your own account before relying on this
  rung; don't assume it will work for every Workspace.

## Verifying it worked

```bash
gcloud auth application-default print-access-token >/dev/null && echo "ADC OK"
```

or just run the skill's `adc-check.sh` — it does exactly this check and
prints an actionable message if it fails.
