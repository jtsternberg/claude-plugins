# Manual Workflow (if scripts unavailable)

## Step 1: Clean the file

Strip YAML frontmatter and Obsidian callout headers (`> [!TYPE] Label` lines):

```bash
awk '
  BEGIN {skip=0}
  NR==1 && /^---$/ {skip=1; next}
  skip==1 && /^---$/ {skip=0; next}
  skip==0 && /^> \[!.+\]/ {next}
  skip==0 {print}
' "source.md" > "__tmp-clean-copy.md"
```

## Step 2: Upload

```bash
gws drive files create \
  --json '{"name": "Title", "mimeType": "application/vnd.google-apps.document", "parents": ["FOLDER_ID"]}' \
  --upload ./__tmp-clean-copy.md \
  --upload-content-type text/markdown
```

Parse the `id` field from the JSON response using:
`python3 -c "import sys,json; print(json.load(sys.stdin)['id'])"`

## Step 3: Set pageless format

```bash
gws docs documents batchUpdate \
  --params '{"documentId": "DOC_ID"}' \
  --json '{"requests": [{"updateDocumentStyle": {"documentStyle": {"documentFormat": {"documentMode": "PAGELESS"}}, "fields": "documentFormat"}}]}'
```

## Step 4: Verify and return URL

```bash
gws drive files get --params '{"fileId": "DOC_ID", "fields": "id,name,webViewLink"}'
```

URL format: `https://docs.google.com/document/d/DOC_ID/edit`

## Step 5: Cleanup

Delete any temp file created in step 1.
