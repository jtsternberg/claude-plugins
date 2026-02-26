---
name: slides-presentation
description: Creates self-contained HTML slide presentations from talk prompts, outlines, or content descriptions. Use when user asks to "create a presentation", "make slides", "build a slide deck", "present this", or mentions giving a talk. Generates a polished single .html file with opinionated design, entry animations, and alternating dark/light slides. No PowerPoint, no external tools needed.
---

# Slides Presentation Builder

Build self-contained HTML/CSS/JS slide presentations that run in any browser. No dependencies, no build step — open the file and present.

See `references/slide-template.html` for the base template with all mechanics.
See `references/LAYOUT-GUIDE.md` for typography, layout patterns, animation specs, and narrative arc templates.

## Phase 1: Brief

Ask the user two things (can be combined in one message):

1. **Content** — What should the presentation cover? Accept any of:
   - Free-form description ("I want to present our Q3 results")
   - Code/files to analyze ("analyze this repo and make slides about the architecture")
   - A problem statement ("here's our product problem, make a pitch deck")
   - Slide-by-slide outline ("slide 1: title, slide 2: the problem we solve...")
   - A talk prompt file to read

2. **Style** — Do they have a website or reference whose visual style they'd like to draw from?
   - If yes: fetch/browse the URL and extract the color palette, font personality, and vibe
   - If no: ask for a mood (e.g., "minimal & editorial", "bold & techy", "warm & approachable") — then derive a fresh palette

Do NOT ask for exact hex colors or font names. You will derive these.

## Phase 2: Design

**Commit to a BOLD aesthetic direction first.** Pick one and execute it with conviction — the worst result is a timid middle ground:

- **Editorial/Magazine**: large italic display type, strong vertical rhythm, high contrast
- **Luxury/Refined**: tight tracking, generous whitespace, subtle textures, restrained palette
- **Energetic/Techy**: gradient fills, sharp geometric shapes, dynamic grid
- **Warm/Organic**: earth tones, soft curves, generous roundness
- **Brutalist/Raw**: off-grid placement, unexpected color, unapologetic weight

From the style reference (URL or mood), derive:

- A `--dark-bg` and `--light-bg` (two slide background colors for alternation)
- An `--accent` color
- `--text-dark` / `--text-dark-body` for text on dark slides
- `--text-light` / `--text-light-body` for text on light slides
- Card borders, label colors derived from the palette
- Atmospheric dark backgrounds: gradient meshes, layered SVG textures, or radial gradients — **never plain solid fills on dark slides**

### Font Rules

Choose a **two-font pairing**: a distinctive display font for headings + a refined readable body font.

**NEVER use Inter, Roboto, Arial, or system fonts** — they are generic and forgettable.

Display font options (pick one that fits the aesthetic):
- Fraunces, Cormorant Garamond, Playfair Display, Syne, Clash Display, Bebas Neue, Instrument Serif, Radio Canada Big, Libre Baskerville

Body font options:
- DM Sans, Plus Jakarta Sans, Outfit, Manrope, Lato, Literata, Source Serif 4

Load both via Google Fonts `<link>` tag with the weights needed (300, 500/600, 700 for display; 400, 500 for body).

### Contrast Rules (WCAG AA)

- Body text: minimum **4.5:1** contrast ratio against its background
- `--text-dark-body` is a common failure point — muted colors on dark backgrounds often fail; verify the value
- Large headings (24px+ bold): minimum **3:1** acceptable, 4.5:1 preferred
- Slide labels (uppercase eyebrow text): must pass 3:1 minimum — accent color on dark bg commonly fails
- Never rely on light gray body text on white — it almost always fails

### Theme Customization

Override CSS variables in `:root`. See the template for the full set. Always use `var(--x)` in layout CSS — never hardcode hex values.

**Link color rule:** Always use a distinct `--link` color for hyperlinks — never reuse `--accent` or body text color. Links must be visually identifiable.

## Phase 3: Structure

Plan the slides based on the content brief. Standard narrative arc:

1. **Title** — Brand/project name, one-line descriptor
2. **Problem / Context** — Stats, current pain points
3. **Vision / Solution** — What you're building and why
4. **How It Works** — Process flow, architecture, or method
5. **Big Statement** — A single powerful number or insight (large text, minimal slide)
6. **Data / Evidence** — Charts, breakdowns, comparisons
7. **Detail / Deep Dive** — Technical or operational specifics
8. **Roadmap** — Phases, milestones, timeline
9. **CTA / Close** — Call to action, contact, next steps

Adjust this arc for the content type:
- **Code/architecture**: problem → current structure → pain points → proposed structure → benefits → migration path → close
- **Pitch deck**: hook → problem → solution → market → product → traction → ask
- **Research**: question → method → findings → implications → recommendations
- **Conference talk**: hook → context → demo points → key insight → takeaways

Each slide needs: a **slide-label** (eyebrow text), a headline, and supporting content.

Keep slides minimal — one idea per slide, short bullets (max 8 words per bullet), no paragraphs. For live demos, add a single placeholder slide (not full demo slides).

**Alternate dark and light slides** for visual rhythm. Title, big statement, and closing slides work well as dark. Content-heavy slides work well as light.

## Phase 4: Build the Presentation

Read `references/slide-template.html` and use it as the starting point. Copy it to the project directory and customize.

Requirements:
- All CSS in a `<style>` block — no external stylesheets
- All JS in a `<script>` block — no external libraries
- Google Fonts loaded via `<link>` tag (both display and body fonts)
- Charts as pure CSS div-based bars (no Chart.js, no D3)
- Diagrams as SVG or styled HTML — no canvas
- File saved as `[topic]-presentation.html` in the working directory

For layout patterns, component sizing, and visual element specs, see [references/LAYOUT-GUIDE.md](references/LAYOUT-GUIDE.md).

### Entry Animations (Required)

Every slide MUST animate its content in when it becomes active:
- Default state: `opacity: 0; transform: translateY(28px)` on child elements
- Active state: `opacity: 1; transform: translateY(0)` over 0.55s with `cubic-bezier(0.16, 1, 0.3, 1)` easing
- Stagger direct child elements with 80-120ms `transition-delay` increments
- Reset animation when slide deactivates so it replays on revisit

The template includes the animation CSS and JS — just use the `.slide-content` wrapper and it works automatically.

### Navigation

The template includes: arrow keys, Space, PageDown/PageUp, number keys to jump, `F` for fullscreen, touch/swipe, progress bar, and slide counter.

## Phase 5: Generate Illustrations (if needed)

For visuals difficult to create in SVG (realistic objects, organic shapes, complex scenes), use an image generation skill. Prefer `compound-engineering:gemini-imagegen` if available, but any image generation skill in the environment will work. If none is available, use SVG/CSS diagrams or ask the user to provide images.

**Practical notes:**
- Use `16:9` aspect ratio and `2K` resolution for slide-sized images
- Prompt for the slide's background color so the image blends seamlessly

**When to use SVG vs generated images:**

| SVG/CSS | Image generation |
|---------|-----------------|
| Geometric diagrams, graphs, flowcharts | Realistic objects, scenes |
| Terminal/code mockups | Artistic/illustrative graphics |
| Simple icons, shapes, arrows | Complex visual metaphors |
| File trees, dependency graphs | Anything organic (brains, people) |

## Phase 6: Validate and Audit

### Automated Validation

1. Run: `bash scripts/validate-presentation.sh presentation.html`
2. Fix any reported issues (unreplaced placeholders, slide numbering gaps, broken images)
3. Re-run validation until clean

### Self-Audit Checklist

Before delivering, verify against this checklist:

**Design**
- [ ] Dark and light slides genuinely alternate (not all one color)
- [ ] Committed to a single bold aesthetic direction — not a timid middle ground
- [ ] Dark slide backgrounds have atmospheric depth (gradient mesh, radial gradient, or texture), not plain solid fills
- [ ] Accent color appears consistently on labels, stats, and highlights
- [ ] Two distinct fonts: a display font for headings and a body font for prose (never Inter/Roboto/Arial)
- [ ] Typography uses `clamp()` for headings — title slides at least `clamp(44px, 6.5vw, 80px)`
- [ ] Body/prose text is 15px minimum — never 12-13px for paragraph content
- [ ] Cards have consistent border-radius and border style
- [ ] No slide feels empty — every slide has a visual element beyond text

**Contrast & Readability**
- [ ] Body text on dark slides passes 4.5:1 contrast
- [ ] Body text on light slides passes 4.5:1 contrast
- [ ] Slide labels (uppercase eyebrow text) pass 3:1 minimum

**Animation**
- [ ] Every slide animates its content in when activated
- [ ] Children stagger with 80-120ms delays (not all at once)
- [ ] Animations reset when slide deactivates (replay on revisit)

**Content**
- [ ] Slide 1 is a strong title slide with a clear one-line descriptor
- [ ] At least one "big statement" slide (large number or bold claim)
- [ ] Bullet points are concise (max 8 words per bullet)
- [ ] Narrative has a clear arc with a strong closing slide

**Technical**
- [ ] Slide counter reads "X / N" correctly
- [ ] Progress bar width matches current position
- [ ] Keyboard navigation works (arrows, Space, number keys, F)
- [ ] File is self-contained (no broken external links except Google Fonts)

Fix any failures before delivering.

## Delivery

Tell the user:
- The filename and path
- How many slides were generated
- How to navigate: arrow keys, Space, number keys, F for fullscreen, touch/swipe
- The design choices made (aesthetic direction, palette source, font pairing)

## File Structure

A typical presentation project:

```
talk-name/
├── presentation.html    (self-contained slide deck)
├── hero-image.png       (generated illustrations, if any)
└── talk-prompt.md       (original brief, optional)
```

## Utility Scripts

- **`scripts/validate-presentation.sh <file>`** — Checks for unreplaced placeholders, sequential slide numbering, counter mismatches, and broken image paths.
- **`scripts/new-presentation.sh <title> [output-dir]`** — Scaffolds a new presentation from the template with the title pre-filled.

All images use relative paths so the folder is portable.
