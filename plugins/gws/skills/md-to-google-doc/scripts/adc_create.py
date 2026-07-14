#!/usr/bin/env python3
"""Create or update-in-place a Google Doc from a local markdown file via
gcloud Application Default Credentials (ADC) + the Drive/Docs APIs — rung 2
of the md-to-google-doc source-routing plan (used when `gws` can't reach the
target account).

Update-in-place: this script remembers which source file produced which doc
ID in a state file (~/.config/gws-md-to-gdoc/rendered.json, see
adc_state.py). Rerunning against the same source file updates that doc's
content instead of creating a new one, unless --new is passed. If the
remembered doc was deleted/inaccessible (403/404), falls back to creating a
fresh doc and updating the state entry — same doc_exists-fallback pattern as
selfreview-to-gdoc's gdocs.py.

Usage:
    adc_create.py <cleaned-markdown-file> --title "Title" [--folder FOLDER_ID] [--new]

Expects the caller (adc-create.sh) to have already stripped frontmatter /
Obsidian callouts (via clean.sh) and derived a title.
"""
import argparse
import os
import re
import sys

from adc_state import DEFAULT_STATE_FILE, get_entry, load_state, save_state, set_entry

SCOPES = [
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/documents",
]

FOLDER_ID_RE = re.compile(r"/folders/([^/?#]+)")


def extract_folder_id(folder_id_or_url: str) -> str:
    m = FOLDER_ID_RE.search(folder_id_or_url)
    return m.group(1) if m else folder_id_or_url


def _clients():
    try:
        import google.auth
        from googleapiclient.discovery import build
    except ImportError as e:
        raise SystemExit(
            "ERROR: google-api-python-client / google-auth not installed in "
            "this Python. Install with: pip install google-api-python-client "
            "google-auth (prefer ~/.venvs/genai on macOS). "
            f"Original error: {e}"
        )
    try:
        creds, _ = google.auth.default(scopes=SCOPES)
    except Exception as e:
        raise SystemExit(
            "ERROR: no usable ADC credentials. Run `gcloud auth application-default "
            "login` with the full drive + documents scopes — see "
            f"references/adc-setup.md for the exact command. Original error: {e}"
        )
    return (
        build("drive", "v3", credentials=creds, cache_discovery=False),
        build("docs", "v1", credentials=creds, cache_discovery=False),
    )


def doc_exists(drive, doc_id: str) -> bool:
    from googleapiclient.errors import HttpError

    try:
        drive.files().get(fileId=doc_id, fields="id").execute()
        return True
    except HttpError as e:
        if e.status_code in (403, 404):
            return False
        raise


def _set_pageless(docs, doc_id: str) -> None:
    docs.documents().batchUpdate(
        documentId=doc_id,
        body={
            "requests": [
                {
                    "updateDocumentStyle": {
                        "documentStyle": {"documentFormat": {"documentMode": "PAGELESS"}},
                        "fields": "documentFormat",
                    }
                }
            ]
        },
    ).execute()


def create_doc(drive, docs, md_path: str, title: str, folder_id: str | None) -> str:
    from googleapiclient.http import MediaFileUpload

    body = {"name": title, "mimeType": "application/vnd.google-apps.document"}
    if folder_id:
        body["parents"] = [folder_id]
    media = MediaFileUpload(md_path, mimetype="text/markdown")
    doc = drive.files().create(body=body, media_body=media, fields="id").execute()
    doc_id = doc["id"]
    _set_pageless(docs, doc_id)
    return doc_id


def update_doc(drive, doc_id: str, md_path: str, title: str) -> None:
    from googleapiclient.http import MediaFileUpload

    media = MediaFileUpload(md_path, mimetype="text/markdown")
    drive.files().update(fileId=doc_id, body={"name": title}, media_body=media).execute()


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("md_path")
    parser.add_argument("--title", required=True)
    parser.add_argument("--folder", default=None)
    parser.add_argument("--source", default=None, help="original (uncleaned) source path, for state-file keying")
    parser.add_argument("--new", action="store_true", help="force a new doc, ignore state file")
    parser.add_argument("--state-file", default=DEFAULT_STATE_FILE)
    args = parser.parse_args(argv)

    if not os.path.isfile(args.md_path):
        sys.exit(f"ERROR: file not found: {args.md_path}")

    source_for_state = args.source or args.md_path
    folder_id = extract_folder_id(args.folder) if args.folder else None

    drive, docs = _clients()
    state = load_state(args.state_file)
    existing = None if args.new else get_entry(state, source_for_state)

    if existing and doc_exists(drive, existing["doc_id"]):
        update_doc(drive, existing["doc_id"], args.md_path, args.title)
        doc_id = existing["doc_id"]
        print(f"https://docs.google.com/document/d/{doc_id}/edit (updated in place)")
    else:
        doc_id = create_doc(drive, docs, args.md_path, args.title, folder_id)
        print(f"https://docs.google.com/document/d/{doc_id}/edit (created)")

    state = set_entry(state, source_for_state, doc_id, args.title)
    save_state(state, args.state_file)


if __name__ == "__main__":
    main(sys.argv[1:])
