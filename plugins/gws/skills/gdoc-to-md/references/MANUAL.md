# Manual Workflow (if scripts unavailable)

## Step 1: Get the doc ID

Extract from a Google Docs URL — it's the long string between `/d/` and `/edit`:
`https://docs.google.com/document/d/DOC_ID_HERE/edit`

## Step 2: Fetch the document title

```bash
gws drive files get --params '{"fileId": "DOC_ID", "fields": "name"}'
```

Parse the `name` field from the JSON response using:
`python3 -c "import sys,json; print(json.load(sys.stdin)['name'])"`

## Step 3: Export as HTML

```bash
gws drive files export \
  --params '{"fileId": "DOC_ID", "mimeType": "text/html"}' \
  --output ./exported.html
```

## Step 4: Convert to Markdown

```bash
html-to-markdown ./exported.html ./output.md
```

## Step 5: Cleanup

Delete the temp HTML file created in step 3.

```bash
rm -f ./exported.html
```
