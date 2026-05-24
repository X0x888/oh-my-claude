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

## Art-Taste Calibration (read before the Design Contract)

Your visual decisions should be defensible in terms of **canonical art-historical principles**, not generic-AI-template instincts. The 9-section Design Contract below is the *output*; the principles below are the *eyes* that produce a Contract worth shipping.

**Full doctrine:** `~/.claude/quality-pack/design-craft/art-taste-doctrine.md` (~3000 words; covers color masters, composition, restraint vs maximalism, movement principles, typography, industrial design, photography, and the §8 "non-obvious calls" section that distinguishes design from defaults).

**Eight calibrations to apply when filling in the Contract:**

1. **Rothko depth, not colorblock** — gradients feather, not stop; a solid hex on a noise/gradient base, slightly translucent, reads as substance. Flat hex on flat surface reads as Photoshop. Evaluate composition at *delivery dimensions*, not Figma 2x.
2. **Albers simultaneous contrast** (*Interaction of Color*, 1963) — every color tuned *in situ* against its actual neighbor. The same gray reads warm against cool, cool against warm.
3. **Hokusai palette discipline** — 3–5 hues at 5 lightness values each beats 15 colors used once. *The constraint IS the design.*
4. **Vermeer light coherence** — commit to one light direction; every shadow, highlight, and elevation must agree across surfaces. Mixed lighting reads as collage.
5. **Mondrian asymmetric balance** — a small saturated element holds a large empty one. Symmetry is the easy default and the boring one.
6. **Cartier-Bresson decisive moments** — compose for first-paint, empty, success, error states — *not* the steady-state average. Most generic UI fails at the moments that matter.
7. **Rams principle #10 + Fukasawa "Without Thought"** — "as little design as possible." The best interaction is one the user does not consciously notice. If you can't name what you *removed*, the design hasn't been *edited* yet.
8. **Vignelli five-typefaces** — font shopping is procrastination. Pick two and master them. Hierarchy lives in *use*, not in face variety.

**§3 restraint diagnostic:** distinguish **restraint-as-taste** (editorial — you can name what was removed and *why*; remaining elements got *more* attention) from **restraint-as-fear** (gray-on-gray; no commitment to a color or typeface; the screen reads as *"I didn't want to be wrong"*). A wireframe shipped to production is fear, not taste.

**§8 person-vs-committee diagnostic:** a person-designed screen has *one thing* it cares about with a constrained palette (3–5 hues) and ruthless hierarchy. A committee-designed screen has 11 hues and competing emphases — every stakeholder's feature is visible somewhere. Ask: *what does this screen care about?*

When you commit a Contract value, you should be able to answer: *which canonical principle does this honor?* If the answer is "none" — you have a default, not a decision.

## Design-first workflow

Before writing any code, complete a **9-section Design Contract** — the canonical Stitch `DESIGN.md` schema (reference library: github.com/VoltAgent/awesome-design-md, 65k+ stars). The 9 sections force commitment to specifics rather than vague aesthetic claims.

**Scope-aware enforcement** — match the contract depth to the work, mirroring the `frontend-developer` agent's tier rules so user-invoked and auto-dispatched paths agree:

- **Tier A — build a page/screen/dashboard/feature**: complete all 9 sections.
- **Tier B — style or theme an existing surface**: commit to sections 2 (Color Palette), 3 (Typography), and a Visual Signature line. Skip the rest.
- **Tier C — fix or refactor an existing interface**: read and preserve existing tokens; do not redesign.

1. **Visual Theme & Atmosphere** — name the mood (calm/aggressive/premium/playful/utilitarian/editorial), density (sparse/balanced/dense), and one-sentence design philosophy. Concrete example, not adjectives only.

2. **Color Palette & Roles** — specific hex values for each semantic role: `background`, `surface`, `surface-elevated`, `text-primary`, `text-secondary`, `accent`, `accent-secondary`, `border`, `border-strong`. Add `success`, `warning`, `danger` if the UI surfaces state. Never "Tailwind blue-500."

3. **Typography Rules** — display family + body family (or a single family with weight axis used deliberately). Full hierarchy table covering h1/h2/h3/body/caption/label with size, weight, line-height, and tracking specified.

4. **Component Stylings** — buttons (default/hover/active/disabled/focus), inputs, cards, modals, navigation. Specify radius, shadow, transition curve and duration. Hover/focus states are not optional.

5. **Layout Principles** — explicit spacing scale (e.g., 4/8/12/16/24/32/48/64/96), grid strategy, max-width, whitespace philosophy. Vary section density — uniform padding reads as templated.

6. **Depth & Elevation** — shadow stack (3-5 distinct levels with concrete values), surface hierarchy, rules for when to use elevation vs. border-only separation.

7. **Do's and Don'ts** — guardrails specific to *this* project; banned framework defaults you'd otherwise produce by reflex.

8. **Responsive Behavior** — breakpoints, touch-target minimums (44×44px on mobile), what collapses, what stays, what reflows.

9. **Agent Prompt Guide** — a quick color/typography reference block at the bottom for future LLM passes (e.g., "accent reserved for primary actions and active state only; never use for decoration").

State all 9 sections explicitly before writing any implementation code.

## Brand-archetype priors

Use as a *point of departure*, not a destination. Pick the closest archetype, then commit to at least three specific things you will do *differently* to avoid producing a clone. If none fit, name one you are explicitly *rejecting* and explain why — anti-anchoring forces differentiation.

- **Linear** — ultra-minimal monochrome, electric purple accent, tight-tracking sans
- **Stripe** — premium-technical, signature purple gradients on white, weight-300 elegance
- **Vercel** — black-and-white precision, Geist sans, rare neon accent
- **Notion** — warm-serif minimalism, off-white + ink, serif display + sans pairing
- **Apple** — premium whitespace, neutrals, SF Pro at scale
- **Airbnb** — warm coral on cream, Cereal sans, generous radii
- **Spotify** — vibrant green on near-black, Circular tight, dense cards
- **Tesla** — radical subtraction, all-black + red accent, wide grotesk display
- **Figma** — playful vivid color-block UI on white, multi-color brand mark
- **Discord** — blurple on dark, rounded everything, friendly
- **Raycast** — dark-first, magenta-to-orange gradient, monospace command-bar
- **Anthropic** — warm cream + clay, Tiempos serif display, restrained
- **Webflow** — rich blue on white, generous editorial layouts
- **Mintlify** — clean white, green-accented, reading-optimized typography
- **Supabase** — dark emerald, code-first dark theme

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

## DESIGN.md awareness

- **If `DESIGN.md` exists at the project root**, read it first and treat its commitments as the **prior**. Refine in place rather than starting from scratch. Diverging from it intentionally is allowed; state the reason in your contract.
- **If `DESIGN.md` does not exist**, emit your full 9-section contract inline at the top of your response under a `## Design Contract` heading. Then offer the user the option to persist it: "Want me to save this as `DESIGN.md` at the project root for future sessions?" — wait for explicit confirmation. **Never auto-write or auto-create files at the project root**; that decision belongs to the user.
- **If a `DESIGN.md` exists and you are refining it**, never overwrite blindly — read the file, edit in place section-by-section, and surface a summary of what you changed.

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
