---
name: gmail-draft-from-markdown
description: "Draft a Gmail message from a local markdown file via the gws CLI. Converts markdown to HTML, saves as a Gmail draft (never sends), and returns a clickable Gmail drafts URL so the user reviews and sends from Gmail's UI. Triggers on \"draft an email from\", \"gmail draft from markdown\", \"create a draft in gmail\", \"draft a follow-up email\", \"turn this note into an email draft\"."
argument-hint: '[file.md] [recipient-email-or-name] [--subject "Subject"] [--cc EMAIL] [--bcc EMAIL] [--from EMAIL] [--reply-to MESSAGE_ID] [--thread THREAD_ID]'
allowed-tools: 'Bash(gws *) Bash(bash *) Bash(python3 *) Bash(marked *) Bash(pandoc *)'
---

# Gmail Draft from Markdown

Take a local markdown file, convert it to HTML, and save it as a Gmail
**draft** (never sent). Returns a clickable Gmail drafts URL so the user can
review and send from the Gmail UI.

Default is `--draft`, always. Thoughtful emails (coaching follow-ups, client
notes, anything personal) need human review before they go out. This skill
will never send an email directly.

## Prerequisites

```!
gws auth status 2>&1 || echo "NOT AUTHENTICATED — run: gws auth login"
```

Also requires a markdown→HTML converter. The script prefers
[`marked`](https://github.com/markedjs/marked-cli) (`npm i -g marked`) and
falls back to `pandoc`. It errors with a clear message if neither is
installed.

## Task

Run the entrypoint script, passing all arguments through:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/draft.sh $ARGUMENTS
```

If no arguments were provided, ask the user for the markdown file path and
recipient (email or name). Subject is optional — the script derives it from a
`Subject: ...` line at the top of the markdown if present.

## Arguments

| Arg | Required | Notes |
|---|---|---|
| `<markdown-file>` | yes | Path to a local `.md` file. |
| `<recipient>` | yes | Email address, or a name to look up via Gmail search. |
| `--subject "..."` | no | Overrides the `Subject:` line in the markdown. |
| `--cc EMAIL` | no | Comma-separated. |
| `--bcc EMAIL` | no | Comma-separated. |
| `--from EMAIL` | no | Send-as alias (defaults to active account). |
| `--reply-to MESSAGE_ID` | no | Thread the draft onto that message's conversation (see Threading). |
| `--thread THREAD_ID` | no | Attach the draft to a threadId directly, no header lookup. Prefer `--reply-to`. |

## Behavior

### Recipient resolution
- If the recipient contains `@`, it's used verbatim.
- Otherwise, the script searches Gmail for the most recent message matching
  the name (`gws gmail users messages list`) and extracts the email from the
  `From:` header (`gws gmail +read --id ... --headers`).
- If no match is found, the script errors and asks for an email address.

### Threading (reply drafts)
By default the script creates a **standalone** draft. To attach the draft to
an existing Gmail conversation so it shows up as a reply in that thread:

- `--reply-to MESSAGE_ID` — the script looks up that message via
  `gws gmail users messages get` (format `metadata`) and reads its `threadId`,
  `Message-ID`, and `References`. It then:
  - sets `message.threadId` on the draft resource, and
  - injects `In-Reply-To` (the parent's Message-ID) and `References` (the
    parent's References chain plus its Message-ID) into the raw MIME message.
  Gmail needs those RFC 5322 headers — not just `threadId` — to thread the
  reply reliably. If no `--subject` is given, the parent's subject is reused;
  in reply mode a conventional `Re: ` prefix is added when missing.
- `--thread THREAD_ID` — attaches to a threadId directly with no header lookup.
  Weaker than `--reply-to` (no `In-Reply-To`/`References`), so prefer
  `--reply-to` when you have the parent message id.

The `MESSAGE_ID` for `--reply-to` is a Gmail message id (as returned by
`gws gmail users messages list` or the `gws:gmail-read` skill), not the raw
RFC `Message-ID` header value.

### Subject resolution (in order)
1. `--subject "..."` flag
2. A `Subject: ...` line at the top of the markdown (before the body)
3. The parent message's subject, when `--reply-to` is used
4. Error — the user must supply a subject

In reply mode (`--reply-to`), the resolved subject is prefixed with `Re: `
unless it already starts with one.

The `Subject:` line is stripped from the body before conversion.

### Markdown cleaning
Before HTML conversion, the script strips:
- YAML frontmatter (`---` … `---`)
- A leading `Subject: ...` header line
- Obsidian callout headers (`> [!note]` etc.)

### Output
On success, prints the account the draft landed in (stderr) and one URL line
to stdout, addressed to that account explicitly:

```
Draft created in account: you@example.com
https://mail.google.com/mail/?authuser=you@example.com#drafts/<message-id>
```

Open that URL in a browser to review and send the draft. The draft is created
in the **active gws account** (see the `gws:account` skill) — the `authuser=`
URL means the link opens the right mailbox even when multiple Google accounts
are signed in. Always relay the account email to the user along with the URL.

## Examples

```bash
# Email address known
bash ${CLAUDE_SKILL_DIR}/scripts/draft.sh ./coaching-followup.md alice@example.com --subject "Session recap"

# Look up recipient by name (most recent correspondent wins)
bash ${CLAUDE_SKILL_DIR}/scripts/draft.sh ./coaching-followup.md "Alice Smith"

# Subject embedded in markdown as a leading "Subject: ..." line
bash ${CLAUDE_SKILL_DIR}/scripts/draft.sh ./note.md alice@example.com

# Reply draft — thread onto an existing conversation (subject/threading auto-derived)
bash ${CLAUDE_SKILL_DIR}/scripts/draft.sh ./reply.md alice@example.com --reply-to 19f3de2c4f9ee065
```

## Troubleshooting

- **Auth expired:** Run `gws auth login`.
- **Wrong account:** Run `gws auth status` to confirm which account is
  active. The active account is resolved via the gws account helpers (see
  the `gws:account` skill).
- **`No markdown→HTML converter found`:** Install one — `npm i -g marked` or
  `brew install pandoc`.
- **Recipient lookup returned nothing:** Pass an email address instead.
- **Draft didn't appear in Gmail:** Check which account you're looking at —
  the draft lands in the **active gws account**, which may not be the mailbox
  you (or your verification commands) are checking. The script prints the
  account email and an `authuser=`-addressed URL for exactly this reason.
  Bare `gws` verification commands run against the default account unless
  `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` is set to the active account's config.

## Why this skill exists

The `gws` CLI is powerful but the markdown → HTML → draft → drafts-URL
workflow takes 6+ tool calls to discover. This skill collapses it to one
invocation and codifies the **draft, don't send** default.
