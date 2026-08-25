#!/usr/bin/env python3
"""Compose the RFC 5322 message for a Gmail draft.

Single source of truth for header composition, so the two ways a draft reaches
the Gmail API cannot drift apart. The message is built once; its encoded size
picks the route:

  inline route (small messages)
      Prints ``{"message": {"raw": "<base64url>", ...}}`` on stdout, ready to
      hand to ``gws gmail users drafts create --json``. ``OUT_EML`` is left
      untouched, which is how the caller knows this route was taken.

  upload route (anything larger than ``MAX_JSON_BYTES``)
      Writes the full message to ``OUT_EML`` for ``--upload`` and prints only
      the draft *metadata* JSON — ``{"message": {"threadId": "..."}}``, or
      nothing at all when there is no thread to attach to.

Size, not the presence of attachments, is what decides — because the limit
being dodged is argv's, and a long enough HTML body reaches it with no
attachments at all. Two separate kernel limits bind, whichever comes first:

  * total argv+env, 1048576 bytes on this macOS (measured via ``getconf
    ARG_MAX``); 620KB of PDFs encodes to a 1118017-byte argument and is
    refused outright.
  * a single argument, which Linux caps at ``MAX_ARG_STRLEN`` = 32 pages =
    131072 bytes no matter how large ``ARG_MAX`` is. This is the binding one
    there, and it lands at roughly 96KB of message.

``MAX_JSON_BYTES`` therefore defaults well under the smaller of the two rather
than to either. Set it to 0 to force the upload route.

Inputs are environment variables (TO, SUBJECT, CC, BCC, FROM, IN_REPLY_TO,
REFERENCES, HTML_FILE, THREAD_ID, OUT_EML, MAX_JSON_BYTES); attachment paths
are positional arguments.
"""

import base64
import json
import mimetypes
import os
import sys
from email.message import EmailMessage
from email.utils import formatdate

# Gmail rejects messages over 25MB. Check the raw bytes and let base64 overhead
# be the caller's margin — a clear error here beats a 400 from the API.
MAX_ATTACHMENT_BYTES = 25 * 1024 * 1024

# Largest --json argument to put on the command line. Comfortably under Linux's
# 131072-byte per-argument cap, which binds long before ARG_MAX does.
DEFAULT_MAX_JSON_BYTES = 100_000


def die(message):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def build(html, attachments):
    msg = EmailMessage()
    msg["To"] = os.environ["TO"]
    msg["Subject"] = os.environ["SUBJECT"]
    msg["Date"] = formatdate(localtime=True)
    for header, env in (("Cc", "CC"), ("Bcc", "BCC"), ("From", "FROM")):
        if os.environ.get(env):
            msg[header] = os.environ[env]

    # RFC 5322 threading headers — present only when replying. Gmail needs
    # these, not just threadId, to thread a reply reliably.
    if os.environ.get("IN_REPLY_TO"):
        msg["In-Reply-To"] = os.environ["IN_REPLY_TO"]
    if os.environ.get("REFERENCES"):
        msg["References"] = os.environ["REFERENCES"]

    msg.set_content(html, subtype="html")

    total = 0
    for path in attachments:
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError as exc:
            die(f"Could not read attachment {path}: {exc}")
        total += len(data)
        if total > MAX_ATTACHMENT_BYTES:
            die(
                f"Attachments exceed Gmail's 25MB limit "
                f"({total} bytes so far, at {os.path.basename(path)})."
            )
        ctype, _ = mimetypes.guess_type(path)
        maintype, _, subtype = (ctype or "application/octet-stream").partition("/")
        msg.add_attachment(
            data,
            maintype=maintype,
            subtype=subtype or "octet-stream",
            filename=os.path.basename(path),
        )
    return msg


def main(argv):
    html_file = os.environ.get("HTML_FILE")
    if not html_file:
        die("HTML_FILE is required.")
    with open(html_file, encoding="utf-8") as fh:
        html = fh.read()

    msg = build(html, argv)

    thread_id = os.environ.get("THREAD_ID") or ""
    out_eml = os.environ.get("OUT_EML")

    raw_env = os.environ.get("MAX_JSON_BYTES")
    try:
        max_json_bytes = (
            DEFAULT_MAX_JSON_BYTES if raw_env in (None, "") else int(raw_env)
        )
    except ValueError:
        die(f"MAX_JSON_BYTES must be an integer, got {raw_env!r}.")

    message = {"raw": base64.urlsafe_b64encode(msg.as_bytes()).decode().rstrip("=")}
    if thread_id:
        message["threadId"] = thread_id
    inline = json.dumps({"message": message})

    if len(inline.encode("utf-8")) <= max_json_bytes:
        print(inline)
        return

    if not out_eml:
        die(
            f"Message is {len(inline)} bytes encoded, over the "
            f"{max_json_bytes}-byte inline limit, and no OUT_EML path was given "
            f"to write it to."
        )
    with open(out_eml, "wb") as fh:
        fh.write(msg.as_bytes())
    # Only the threadId travels in --json on this route; the message itself is
    # the uploaded media. No thread means no metadata worth sending at all.
    if thread_id:
        print(json.dumps({"message": {"threadId": thread_id}}))


if __name__ == "__main__":
    main(sys.argv[1:])
