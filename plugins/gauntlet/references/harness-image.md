# Reference harness: image (web page sections)

For anything that renders in a browser: landing pages, components, dashboards.

**Capture.** Copy `capture-image.mjs` (next to this file) into the run dir as
`.gauntlet/<run-id>/capture.mjs`. The spec then reads:

```json
"medium": "image",
"artifact": { "workspace": "/abs/path/to/site", "serve": "npm run dev -- --port 5173" },
"capture": {
  "command": "node .gauntlet/<run-id>/capture.mjs --url http://localhost:5173/ --selector {selector} --out {out}",
  "ext": "png",
  "timeout_s": 120
}
```

Each piece carries its `selector` in its split entry (`"capture": {"selector": "#hero"}`),
and `{selector}` is replaced with it. The dev server must be running while the loop
runs; the capture does not start it. Playwright must be installed in the workspace.

**References.** Capture each reference URL with the same script into
`refs/<id>.png` (same viewport), so a ref and a candidate come out of one pipeline:

```bash
node .gauntlet/<run-id>/capture.mjs --url https://example.com --out .gauntlet/<run-id>/refs/ref-example.png
```

**Judge.** The bundled pairwise template works as is. A reference with a famous,
recognizable look (a brand's own homepage) tells the critic which file is which; for
those, choose `judge.mode: "rubric"`.
