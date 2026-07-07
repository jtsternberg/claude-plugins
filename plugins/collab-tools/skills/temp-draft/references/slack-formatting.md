# Slack-flavored formatting for drafts

Slack's paste-and-convert (`cmd+shift+f`) only understands a subset of markdown, and everything outside it survives as literal artifacts (`#` headings, stray asterisks from `**bold**`, code-fence language tags, `[text](url)` brackets). Write Slack drafts using only Slack-supported formatting.

## Save as `.txt`, never `.md`

**Slack drafts must use the `.txt` extension.** When the file is `.md`, editors like VS Code treat it as markdown and copy *rich text* (rendered bold/italic styling) to the clipboard — Slack then pastes the styling itself, leaving the raw markup characters half-converted and `cmd+shift+f` broken. A `.txt` file copies as plain text and converts cleanly. (Verified 2026-07-07 by pasting into Slack from both file types.)

## Conversion table

| Instead of (markdown) | Write (Slack) |
|---|---|
| `# Heading` / `## Heading` | `*Bold line*` on its own line (optionally ALL-CAPS or an emoji prefix for hierarchy) |
| `**bold**` | `*bold*` (single asterisks — `**` converts to bold but leaves literal `*` artifacts inside) |
| `*italic*` or `_italic_` | `_italic_` (underscores only — see caveat below) |
| `~~strike~~` | `~strike~` (single tildes) |
| ```` ```php ```` fenced block | ```` ``` ```` fenced block with **no language tag** |
| `[link text](url)` | Works as-is — but ONLY with a plain-text label. Any formatting inside the brackets (bold, emoji, another link, a `#channel` ref) leaves bracket artifacts; in that case use a bare URL or `label: url` |
| Bullet/numbered lists | Flat `-` bullets or `1.` numbered lines — see list caveat below |
| Horizontal rules `---` | Blank line, or a `*Bold*` section label |

## List caveat: paste never creates real Slack lists

`cmd+shift+f` does not convert any list marker (`-`, `*`, `•`, `1.`) into Slack's actual list elements — pasted markers stay literal text. Real lists only come from Slack's as-you-type autoformat (typing `- ` or `1. ` at line start) or the toolbar. Literal `-` hyphens and `1.` numbers read fine, so keep them in drafts; tell the user that if they want native list rendering they'd need to retype the markers in the composer. (Verified 2026-07-07.)

## Italic caveat: no underscores inside the span

`_italic_` fails to convert when the span itself contains an underscore (e.g. `_see oempro_stats_activity for details_` stays literal). Keep italic spans short, and put underscore-bearing identifiers in `` `backticks` `` outside any italic span.

## Supported as-is

`> blockquote`, `` `inline code` ``, emoji `:shortcodes:`, and `#channel` / `@mentions` typed literally (Slack resolves them after paste).

## Structure guidance

Slack has no headings, so express hierarchy with bold section labels, blockquotes, and whitespace. Keep sections short — Slack messages read best as a few tight blocks, not documents.
