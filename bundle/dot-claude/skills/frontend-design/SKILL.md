---
name: frontend-design
description: Create distinctive, production-grade frontend interfaces with high design quality. Use when building web components, pages, or applications where visual craft matters. Avoids generic AI aesthetics by establishing visual direction before code.
argument-hint: "<task>"
disable-model-invocation: true
model: opus
---
# Frontend Design

Build a frontend interface with intentional design quality — not generic, not templated, not AI-looking.

Primary task:

$ARGUMENTS

## Design-first workflow

Before writing any code, establish a visual direction by making explicit decisions about:

1. **Color palette** — Choose 3-5 colors with intention. Derive from the brand, domain, or emotional register. Never use framework defaults. State the palette and rationale before coding.

2. **Typography** — Choose a typeface pairing (display + body) or a single typeface with clear weight/size hierarchy. Define font sizes, weights, and line-heights for headings, body, captions, and labels. Even with system fonts, create a typographic system.

3. **Spacing scale** — Define a spacing system (e.g., 4/8/12/16/24/32/48/64/96). Use it consistently but vary section density — not every section needs the same padding.

4. **Layout approach** — Decide the layout strategy: asymmetric grid, editorial layout, full-bleed sections with contained content, sidebar+main, etc. Avoid defaulting to centered-content-in-a-container for everything.

5. **Visual signature** — Define one distinctive element that makes this interface recognizable. Examples: a bold accent color used sparingly, an unusual card treatment (e.g., thick left border instead of drop shadow), an asymmetric hero layout, a distinctive navigation style, a specific illustration or icon style.

State these five decisions explicitly before writing implementation code.

## Anti-patterns (ban these)

These mark output as AI-generated. Do not produce them:

- Centered headline + subtitle + CTA button hero section over a gradient background
- Three identical feature/benefit cards in a symmetrical row (icon + title + description)
- Default Tailwind blue-500/indigo-500/purple-500 color palette
- Inter, Roboto, or system font with no typographic styling
- Uniform section padding (py-16 or py-24 on every section)
- Generic gradient backgrounds (blue-to-purple, purple-to-pink)
- Symmetrical layouts where every section mirrors the same structure
- Stock-illustration-style SVG decorations
- "Get Started" or "Learn More" as the only CTA copy

## Positive patterns (prefer these)

- Asymmetric layouts that create visual tension and hierarchy
- Varied section structures — alternate between full-width, contained, split, and offset layouts
- Bold typography choices — oversized headings, tight letter-spacing for display, generous line-height for body
- Intentional whitespace — let key elements breathe, cluster related items tightly
- Color used sparingly and with purpose — a single accent color can be more distinctive than a rainbow palette
- Micro-interactions that feel physical — hover states that shift position, transitions that ease naturally, focus indicators that are part of the design
- Content-appropriate styling — a developer tool should feel different from a wellness app which should feel different from a financial dashboard
- Real or realistic content in demos — never "Lorem ipsum" or "Feature 1, Feature 2, Feature 3"

## Implementation

After establishing the visual direction, implement using the `frontend-developer` agent or directly. Apply the design decisions consistently throughout:

- Reference your stated palette, typography, and spacing decisions during implementation
- Verify each section against the anti-patterns list
- When in doubt between "safe and generic" and "bold and distinctive," choose bold
- After implementation, review the full page/component as a whole — does it have a cohesive visual identity?

## Execution rules

- Follow all `/autowork` operating rules: verify, review, don't stop early
- The design-reviewer quality gate will evaluate visual craft — ensure your output passes
- If the user provides a reference (screenshot, URL, mood board), match that direction. If not, make opinionated choices and state them.
- Treat "build a landing page" as "design and build a distinctive landing page" — design is not optional
