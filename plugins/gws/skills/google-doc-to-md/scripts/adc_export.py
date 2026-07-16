#!/usr/bin/env python3
"""Export a Google Doc as markdown via gcloud Application Default Credentials
(ADC) + the Drive API, for accounts `gws` can't authenticate to (rung 2 of
the google-doc-to-md source-routing plan).

This is the same server-side `files.export(mimeType=text/markdown)` call the
`gws` CLI uses (rung 1) — just authenticated via ADC instead. Output is
identical clean markdown, no de-escaping needed (that's only required on the
rung-3 connector path — see deescape.py).

Usage:
    adc_export.py <doc-id-or-url> [output.md]

Pure argument-parsing / doc-ID logic is factored into functions so it's
testable without any network access or Google client libraries installed —
see tests/test_adc_export.py.
"""
import re
import sys

SCOPES = [
    # Full drive (not drive.file): exporting an arbitrary pre-existing doc
    # requires read access to a file this script did not create — drive.file
    # cannot see it. Same reasoning as selfreview-to-gdoc's gdocs.py.
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/documents",
]

DOC_ID_RE = re.compile(r"/d/([^/?#]+)")


def extract_doc_id(doc_id_or_url: str) -> str:
    """Pull the doc ID out of a Google Docs URL, or pass through a bare ID."""
    m = DOC_ID_RE.search(doc_id_or_url)
    return m.group(1) if m else doc_id_or_url


def _clients():
    """Build the Drive client via ADC. Raises a clear, actionable error if
    ADC creds or the Google client libraries aren't available — this is the
    expected failure mode until ADC is set up (see references/adc-setup.md)."""
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
    return build("drive", "v3", credentials=creds, cache_discovery=False)


def export_markdown(doc_id: str) -> bytes:
    drive = _clients()
    return drive.files().export(fileId=doc_id, mimeType="text/markdown").execute()


def main(argv):
    if len(argv) < 1:
        sys.exit("Usage: adc_export.py <doc-id-or-url> [output.md]")
    doc_id = extract_doc_id(argv[0])
    output_path = argv[1] if len(argv) > 1 else None

    content = export_markdown(doc_id)
    if isinstance(content, str):
        content = content.encode("utf-8")

    if output_path:
        with open(output_path, "wb") as f:
            f.write(content)
        if not content:
            sys.exit("ERROR: export produced empty content. The document may be empty.")
        print(output_path)
    else:
        sys.stdout.buffer.write(content)


if __name__ == "__main__":
    main(sys.argv[1:])
