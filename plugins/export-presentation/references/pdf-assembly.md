# PDF Assembly

Combine per-slide PNG screenshots into a single PDF file.

## Tool Priority

### 1. img2pdf (preferred — lossless)

[img2pdf](https://pypi.org/project/img2pdf/) embeds PNG images directly into the PDF without re-encoding. No quality loss, no JPEG compression artifacts.

**Check availability:**

```bash
python3 -c "import img2pdf" 2>/dev/null && echo "available" || echo "not found"
```

**Assemble PDF:**

```python
python3 -c "
import img2pdf, os, sys

dir = sys.argv[1] if len(sys.argv) > 1 else 'screenshots'
output = sys.argv[2] if len(sys.argv) > 2 else 'presentation.pdf'

files = sorted([
    os.path.join(dir, f)
    for f in os.listdir(dir)
    if f.startswith('slide-') and f.endswith('.png')
])

with open(output, 'wb') as f:
    f.write(img2pdf.convert(files))

print(f'PDF created: {output} ({len(files)} pages)')
" screenshots presentation.pdf
```

**Install if missing:**

```bash
pip install img2pdf
```

### 2. ImageMagick (fallback)

[ImageMagick](https://imagemagick.org/) can combine images into PDF. Uses `magick` (v7+) or `convert` (v6).

**Check availability:**

```bash
which magick 2>/dev/null || which convert 2>/dev/null
```

**Assemble PDF:**

```bash
# ImageMagick 7+
magick screenshots/slide-*.png presentation.pdf

# ImageMagick 6 (legacy)
convert screenshots/slide-*.png presentation.pdf
```

**Note on macOS:** The system has a `/usr/bin/convert` (sips wrapper) that is NOT ImageMagick. Check with `convert --version` — it should say "ImageMagick". If using Homebrew: `brew install imagemagick`.

## Why Not Pillow?

Pillow's `Image.save("output.pdf", save_all=True)` applies JPEG compression by default, producing blurry results for text-heavy slide screenshots. img2pdf preserves the original PNG quality exactly.

## Output Naming

Default: `<input-basename>.pdf` in the same directory as the source HTML file.

Examples:
- Input: `/path/to/presentation.html` → Output: `/path/to/presentation.pdf`
- Input: URL `https://example.com/talk/` → Output: `./presentation.pdf` in current directory
