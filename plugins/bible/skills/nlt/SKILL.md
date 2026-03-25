---
name: nlt
description: This skill should be used when looking up Bible verses, passages, or references using the NLT API. Triggers on requests to read, quote, or look up Scripture, Bible verses, Bible passages, or biblical references. Also triggers on mentions of NLT, KJV, NTV translations, or requests like "what does the Bible say about", "read me", or "look up [book] [chapter]:[verse]".
---

# NLT Bible Lookup

Look up Bible passages, parse references, and search Scripture using the NLT API at `https://api.nlt.to/api`.

## Authentication

The API key is stored in the environment variable `NLT_API_KEY`. All requests must include `key=$NLT_API_KEY` as a query parameter.

Before any API call, verify the key exists:

```bash
[ -z "$NLT_API_KEY" ] && echo "ERROR: NLT_API_KEY not set" && exit 1
```

If missing, report the error and direct to: `Settings > env > NLT_API_KEY` in Claude global settings.

## Supported Translations

**Only these versions are available:** `NLT` (default), `NLTUK`, `NTV`, `KJV`. Other translations (ESV, NIV, NASB, etc.) are **not available** through this API. If a user requests an unsupported translation, report which versions are available.

## Utility Scripts

Two scripts handle env var validation, URL encoding, API calls, error handling, and HTML conversion automatically.

**Passage lookup:**
```bash
bash scripts/nlt-lookup.sh "John 3:16-17"
bash scripts/nlt-lookup.sh "Romans 8:28-30" KJV
bash scripts/nlt-lookup.sh "Psalm 23;Psalm 91"
```

**Keyword search:**
```bash
bash scripts/nlt-search.sh "love one another"
bash scripts/nlt-search.sh "faith" KJV
```

Both scripts pipe through `html-to-markdown` when available, otherwise output raw HTML for direct parsing.

## Endpoints

### 1. Passages (Primary)

Retrieve the text of one or more Bible passages. Returns HTML.

```
GET https://api.nlt.to/api/passages?ref=<reference>&key=$NLT_API_KEY
```

**Parameters:**
- `ref` (required) - Scripture reference(s), semicolon-separated for multiple (e.g., `John 3:16`, `Romans 8:28-30`, `Psalm 23;Psalm 91`)
- `version` (optional) - Bible translation (`NLT`, `NLTUK`, `NTV`, `KJV`; default: `NLT`)

**Response:** HTML containing the passage text. Extract clean readable text with verse numbers preserved before displaying.

### 2. Search

Search for passages matching keywords.

```
GET https://api.nlt.to/api/search?text=<query>&key=$NLT_API_KEY
```

**Parameters:**
- `text` (required) - Search terms
- `version` (optional) - Translation to search (`NLT`, `NLTUK`, `NTV`, `KJV`; default: `NLT`)

**Response:** HTML with matching passages and contextual excerpts.

### 3. Parse

Parse a reference string into structured data. Useful for validating or normalizing references.

```
GET https://api.nlt.to/api/parse?ref=<reference>&key=$NLT_API_KEY
```

**Parameters:**
- `ref` (required) - Reference to parse
- `language` - Language for parsing (default: English, `es` for Spanish)

**Response:** JSON array of parsed reference objects.

## Workflow

### Looking Up a Passage

1. Run `bash scripts/nlt-lookup.sh "<reference>"` (or with optional version: `bash scripts/nlt-lookup.sh "<reference>" KJV`)
2. Display the passage with the reference as a header
3. Preserve verse numbers in the output

### Searching Scripture

1. Run `bash scripts/nlt-search.sh "<query>"`
2. Display results with references and excerpts
3. To fetch full text of a result, follow up with `nlt-lookup.sh` using the returned reference

### Handling Multiple References

Separate multiple references with semicolons in a single request:
```
bash scripts/nlt-lookup.sh "Genesis 1:1;John 1:1;Revelation 22:21"
```

## Formatting Guidelines

- Display the reference as a header above the passage text
- Preserve verse numbers in the output
- For long passages, display the full text unless the user requests a summary
- When the user asks about a topic without a specific reference, search first with `nlt-search.sh`, then fetch the most relevant passages with `nlt-lookup.sh`

## Error Handling

- **Missing API key:** The scripts exit with a clear error message directing to settings
- **Invalid reference:** The API returns an empty response. Report that the reference was not recognized and suggest checking the format (e.g., `Book Chapter:Verse`)
- **Unsupported version:** The scripts validate the version parameter and report available options
- **Rate limit exceeded:** Report the limit and suggest waiting before retrying
- **Network failure:** Report the connection error and suggest retrying

## Rate Limits

The API allows 50 verses per request and 500 requests per day with a test key. With a proper API key these limits may differ. For large requests, split into multiple smaller calls.
