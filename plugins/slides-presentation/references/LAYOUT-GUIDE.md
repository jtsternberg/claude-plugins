# Layout and Sizing Guide

## Sizing Guidelines (rem-based)

| Element | Size |
|---------|------|
| h1 (title slide) | 3.2rem |
| h2 (slide titles) | 2.6rem |
| Subtitle | 1.6rem |
| Bullet text | 1.35rem |
| Code / mono text | 0.85-0.95rem |
| SVG diagrams | 300-500px wide (or use viewBox for scaling) |
| Hero images | max-width: 500px |
| Terminal mocks | max-width: 800px |
| Slide padding | 60px 80px |

## Visual Components

Common slide elements to build with CSS/SVG:

- **Two-column layouts** — `.two-col` grid for text + visual side-by-side
- **Bullet lists** — `.bullets` with colored square markers (`.red` variant)
- **Terminal mocks** — `.terminal` with traffic-light header dots
- **Flow diagrams** — flexbox with boxes and arrow separators
- **Graph/node diagrams** — inline SVG with circles, lines, and labels
- **Code blocks** — monospace containers with syntax-colored spans
- **Before/after comparisons** — three-column grid with arrow in center
