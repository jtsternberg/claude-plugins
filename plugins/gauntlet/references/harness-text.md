# Reference harness: text (doc sections, copy, prompts)

For prose judged as prose: a README section, a landing page's copy, an email, a
system prompt.

**Capture.** Copy `capture-text.mjs` (next to this file) into the run dir as
`.gauntlet/<run-id>/capture.mjs`. The spec then reads:

```json
"medium": "text",
"capture": {
  "command": "node .gauntlet/<run-id>/capture.mjs --file docs/guide.md --heading {heading} --out {out}",
  "ext": "md"
}
```

Each piece carries its `heading` in its split entry (`"capture": {"heading": "Install"}`).
Blinding trims leading and trailing whitespace and nothing else.

**References.** A reference is a file of the same kind, saved as `refs/<id>.md`:
the competitor's section pasted in, or the same script run against their doc.

**Judge.** Pairwise works when both texts are about the same thing. When the
reference's own names (product, author) make it obvious which file is which, choose
`judge.mode: "rubric"`.
