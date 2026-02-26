# Layout, Typography, and Design Guide

## Typography Scale (clamp-based)

All headings use `clamp()` for fluid sizing across viewport widths. Body text uses fixed minimums to guarantee readability.

| Element | Size | Notes |
|---------|------|-------|
| h1 (title slide) | `clamp(44px, 6.5vw, 80px)` | Largest text in the deck |
| h2 (slide titles) | `clamp(32px, 4.5vw, 56px)` | |
| h3 (section headers) | `clamp(24px, 3vw, 36px)` | |
| Slide label (eyebrow) | `0.75rem` uppercase, tracked wide | Uses accent color |
| Subtitle | `clamp(18px, 2.5vw, 28px)` | |
| Bullet text | `1.15rem` min | Never below 15px |
| Body/prose text | `1.05rem` min | Never below 15px |
| Big statement number | `clamp(64px, 10vw, 140px)` | Single powerful stat |
| Code / mono text | `0.85-0.95rem` | |
| Slide counter | `0.85rem` mono | |

## Font Pairing Guide

Every presentation needs two fonts: **display** (headings) + **body** (prose/bullets).

### Banned Fonts (never use)
Inter, Roboto, Arial, Helvetica, system-ui defaults — generic and forgettable.

### Curated Display Fonts
| Font | Personality | Good for |
|------|------------|----------|
| Fraunces | Warm, editorial, soft serif | Organic, literary, warm decks |
| Cormorant Garamond | Elegant, classical serif | Luxury, refined, academic |
| Playfair Display | Bold, high-contrast serif | Editorial, magazine, dramatic |
| Syne | Geometric, modern sans | Tech, energetic, futuristic |
| Clash Display | Sharp, contemporary | Brutalist, bold, startup |
| Bebas Neue | Tall, condensed, impactful | Headlines, posters, energetic |
| Instrument Serif | Refined, contemporary serif | Minimal, editorial |
| Radio Canada Big | Friendly, rounded | Warm, approachable, playful |
| Libre Baskerville | Classic, trustworthy serif | Academic, traditional, serious |

### Curated Body Fonts
| Font | Personality | Pairs well with |
|------|------------|-----------------|
| DM Sans | Clean geometric sans | Fraunces, Playfair, Instrument Serif |
| Plus Jakarta Sans | Modern, slightly rounded | Syne, Clash Display, Cormorant |
| Outfit | Geometric, versatile | Any display serif |
| Manrope | Technical, precise | Syne, Bebas Neue |
| Lato | Warm, readable | Playfair, Libre Baskerville |
| Literata | Book-like serif body | Syne, Clash Display (serif+sans contrast) |
| Source Serif 4 | Sturdy, readable serif | Syne, Bebas Neue, Clash Display |

### Loading Fonts

Use `<link>` tags (not `@import`) for Google Fonts:
```html
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Fraunces:ital,wght@0,400;0,600;0,700;1,400&family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet">
```

Load display font weights: 400, 600, 700 (and italic if editorial style).
Load body font weights: 400, 500, 600.

## Contrast Requirements (WCAG AA)

| Element | Minimum ratio | Common failure |
|---------|--------------|----------------|
| Body text on dark bg | 4.5:1 | Muted grays (#888, #999) on dark backgrounds |
| Body text on light bg | 4.5:1 | Light gray on white (#aaa on #faf6f0) |
| Headings (24px+ bold) | 3:1 (4.5:1 preferred) | |
| Slide labels (eyebrow) | 3:1 | Accent color on dark bg often fails |
| Links | 3:1 against bg, distinguishable from body text | |

Verify `--text-dark-body` and `--text-light-body` values pass before generating slides.

## Atmospheric Backgrounds

Dark slides must NEVER use plain solid fills. Use one or more of these techniques:

### Radial Gradient Mesh
```css
.slide.dark {
  background:
    radial-gradient(ellipse at 20% 50%, rgba(accent, 0.08) 0%, transparent 50%),
    radial-gradient(ellipse at 80% 20%, rgba(accent, 0.05) 0%, transparent 40%),
    var(--dark-bg);
}
```

### SVG Noise Texture Overlay
```css
.slide.dark::before {
  content: '';
  position: absolute;
  inset: 0;
  background: url("data:image/svg+xml,...") repeat;
  opacity: 0.03;
  pointer-events: none;
}
```

### Layered Gradient + Grid
Combine a subtle grid pattern with gradient washes for depth.

Light slides can use plain backgrounds but benefit from very subtle textures.

## Entry Animations

Every slide animates its `.slide-content` children in when it becomes active.

### CSS
```css
.slide-content > * {
  opacity: 0;
  transform: translateY(28px);
  transition: opacity 0.55s cubic-bezier(0.16, 1, 0.3, 1),
              transform 0.55s cubic-bezier(0.16, 1, 0.3, 1);
}

.slide.active .slide-content > * {
  opacity: 1;
  transform: translateY(0);
}

/* Stagger children: 80-120ms increments */
.slide.active .slide-content > *:nth-child(1) { transition-delay: 0ms; }
.slide.active .slide-content > *:nth-child(2) { transition-delay: 100ms; }
.slide.active .slide-content > *:nth-child(3) { transition-delay: 200ms; }
.slide.active .slide-content > *:nth-child(4) { transition-delay: 300ms; }
.slide.active .slide-content > *:nth-child(5) { transition-delay: 400ms; }
.slide.active .slide-content > *:nth-child(6) { transition-delay: 500ms; }
```

### Reset on Deactivate
When a slide loses `.active`, children revert to `opacity: 0; transform: translateY(28px)` — so the animation replays when revisiting.

The transition handles this automatically: removing `.active` causes the children to transition back to their default hidden state. When `.active` is re-added, they animate in again.

## Slide Layout Patterns

### Alternating Dark/Light
Alternate `class="slide dark"` and `class="slide light"` for visual rhythm.

- **Dark slides**: title, big statement, closing, dramatic content
- **Light slides**: content-heavy, data, details, process flows

### Slide Labels (Eyebrow Text)
Every slide should have a label above the headline:
```html
<div class="slide-label">The Problem</div>
<h2>Current tools are failing developers</h2>
```
Labels use accent color, uppercase, small size, wide letter-spacing.

### Title Slide
```html
<div class="slide dark" data-slide="0">
  <div class="slide-content" style="text-align:center; display:flex; flex-direction:column; align-items:center; justify-content:center; height:100%;">
    <div class="slide-label">Introducing</div>
    <h1>Project Name</h1>
    <div class="subtitle">One-line descriptor of what this is</div>
  </div>
</div>
```

### Big Statement Slide
A single powerful number or claim, oversized:
```html
<div class="slide dark" data-slide="N">
  <div class="slide-content" style="text-align:center; display:flex; flex-direction:column; align-items:center; justify-content:center; height:100%;">
    <div class="slide-label">The Impact</div>
    <div class="big-number">47%</div>
    <p class="subtitle">of developer time is spent on boilerplate</p>
  </div>
</div>
```

### Content Slide (Two-Column)
```html
<div class="slide light" data-slide="N">
  <div class="slide-content">
    <div class="slide-label">How It Works</div>
    <h2>Headline here</h2>
    <div class="two-col">
      <div>
        <ul class="bullets">
          <li>Short point one</li>
          <li>Short point two</li>
        </ul>
      </div>
      <div>
        <!-- Visual: diagram, terminal, chart -->
      </div>
    </div>
  </div>
</div>
```

### Data/Chart Slide
Use pure CSS bar charts:
```html
<div class="chart-bar">
  <span class="chart-label">Category A</span>
  <div class="chart-track">
    <div class="chart-fill" style="width: 78%">78%</div>
  </div>
</div>
```

### Process Flow
Horizontal flow with arrow separators:
```html
<div class="process-flow">
  <div class="process-step">Step 1</div>
  <div class="process-arrow">&rarr;</div>
  <div class="process-step">Step 2</div>
  <div class="process-arrow">&rarr;</div>
  <div class="process-step">Step 3</div>
</div>
```

## Narrative Arc Templates

### Standard / General
1. Title → 2. Problem/Context → 3. Vision/Solution → 4. How It Works → 5. Big Statement → 6. Data/Evidence → 7. Detail → 8. Roadmap → 9. CTA/Close

### Code / Architecture
1. Title → 2. Current structure → 3. Pain points → 4. Proposed structure → 5. Key insight → 6. Benefits → 7. Migration path → 8. Close

### Pitch Deck
1. Hook → 2. Problem → 3. Solution → 4. Market → 5. Product → 6. Traction → 7. Ask

### Research / Academic
1. Question → 2. Method → 3. Findings → 4. Big insight → 5. Implications → 6. Recommendations

### Conference Talk
1. Hook → 2. Context/Setup → 3-6. Demo/content points → 7. Key insight → 8. Takeaways → 9. Thank you / Q&A

## Sizing Reference

| Element | Size |
|---------|------|
| SVG diagrams | 300-500px wide (or use viewBox for scaling) |
| Hero images | max-width: 500px |
| Terminal mocks | max-width: 800px |
| Slide padding | 60px 80px (40px 50px on small screens) |
| Card border-radius | 12px (consistent across all cards) |
| Big number | `clamp(64px, 10vw, 140px)` display font, bold |

## Visual Components

Common slide elements to build with CSS/SVG:

- **Two-column layouts** — `.two-col` grid for text + visual side-by-side
- **Bullet lists** — `.bullets` with colored square markers
- **Terminal mocks** — `.terminal` with traffic-light header dots
- **Flow diagrams** — `.process-flow` flexbox with boxes and arrow separators
- **Graph/node diagrams** — inline SVG with circles, lines, and labels
- **Code blocks** — monospace containers with syntax-colored spans
- **Before/after comparisons** — three-column grid with arrow in center
- **CSS bar charts** — `.chart-bar` with `.chart-track` and `.chart-fill`
- **Stat cards** — grid of cards with large number + label
- **Roadmap** — timeline with phase labels and descriptions
