---
name: slides-presentation
description: Creates self-contained HTML slide presentations from talk prompts, outlines, or content descriptions. This skill should be used when the user asks to create a presentation, slide deck, or talk slides, or mentions giving a talk. Supports dark/light themes, SVG diagrams, and AI-generated illustrations via Gemini.
---

# Slides Presentation Builder

Build self-contained HTML/CSS/JS slide presentations that run in any browser. No dependencies, no build step — open the file and present.

## Workflow

### Step 1: Gather Requirements

Determine from the user or provided materials:

- **Topic and structure** — number of slides, sections, key points per slide
- **Constraints** — time limit, slide count, one idea per slide
- **Visual style** — dark/light theme, accent colors, level of illustration
- **Existing materials** — reference PDFs, outlines, or brand guidelines to match
- **Illustrations needed** — whether AI-generated images would help

If a talk prompt file is provided, read it to extract all of the above.

### Step 2: Plan the Deck

Before writing HTML, outline the slide structure:

1. Map each slide: title, key bullet points, visual element (diagram/image/code/terminal mock)
2. Keep slides minimal — one idea per slide, short bullets, no paragraphs
3. Identify which slides need illustrations vs CSS/SVG diagrams
4. For live demos, add a single placeholder slide (not full demo slides)

### Step 3: Build the Presentation

Read `references/slide-template.html` and use it as the starting point. Copy it to the project directory and customize.

#### Layout: Fluid with rem Units

The template uses a **fluid layout** — the deck fills 100% of the viewport, typography uses `rem` units, and the user scales with browser zoom (Cmd +/-). A `@media (max-width: 1200px)` breakpoint reduces sizes for smaller screens.

For sizing guidelines and visual component patterns, see [references/LAYOUT-GUIDE.md](references/LAYOUT-GUIDE.md).

#### Navigation

The template includes: arrow keys, Space, PageDown/PageUp, number keys to jump (type digits for slide number), `F` for fullscreen, touch/swipe, progress bar, and slide counter.

#### Theme Customization

Override CSS variables in `:root`:

```css
:root {
  --bg: #1e1e1e;        /* Slide background */
  --accent: #4ade80;     /* Primary accent color */
  --danger: #ef4444;     /* Warning/problem color */
  --link: #67b7f7;       /* Links — complementary to accent, not the same color */
  --text: #f0f0f0;       /* Primary text */
}
```

**Link color rule:** Always use a distinct `--link` color for hyperlinks — never reuse `--accent` or `--text-mid`. Links should be visually identifiable without competing with accent-colored content like code highlights or bullet markers.

### Step 4: Generate Illustrations (if needed)

For visuals difficult to create in SVG (realistic objects, organic shapes, complex scenes), use an image generation skill. Prefer `compound-engineering:gemini-imagegen` if available, but any image generation skill in the environment will work. If none is available, use SVG/CSS diagrams or ask the user to provide images.

**Practical notes:**

- Use `16:9` aspect ratio and `2K` resolution for slide-sized images
- Prompt for the slide's background color (e.g., "on a #1e1e1e charcoal background") so the image blends seamlessly

**When to use SVG vs generated images:**

| SVG/CSS | Image generation |
|---------|-----------------|
| Geometric diagrams, graphs, flowcharts | Realistic objects, scenes |
| Terminal/code mockups | Artistic/illustrative graphics |
| Simple icons, shapes, arrows | Complex visual metaphors |
| File trees, dependency graphs | Anything organic (brains, people) |

### Step 5: Validate and Review

1. Run: `bash scripts/validate-presentation.sh presentation.html`
2. Fix any reported issues (unreplaced placeholders, slide numbering gaps, broken images)
3. Re-run validation until clean
4. Open in browser for visual review:
   - Text overflow — bullets too long for slide width
   - Diagram sizing — SVGs filling their allocated space
   - Image blending — generated images matching slide background
   - Slide count — within the target range
   - One idea per slide — split if overloaded

## File Structure

A typical presentation project:

```
talk-name/
├── presentation.html    (self-contained slide deck)
├── hero-image.png       (generated illustrations)
└── talk-prompt.md       (original brief, optional)
```

## Utility Scripts

- **`scripts/validate-presentation.sh <file>`** — Checks for unreplaced placeholders, sequential slide numbering, counter mismatches, and broken image paths. Run after building and after each edit pass.
- **`scripts/new-presentation.sh <title> [output-dir]`** — Scaffolds a new presentation from the template with the title pre-filled.

All images use relative paths so the folder is portable.
