# Art-Taste Doctrine — Canonical Principles for Screen Craft

A craft reference for **recognizing** and **producing** UI work with aesthetic depth — not a checklist. The principles below are distilled from primary-source writings (Rams's *Ten Principles*, Albers's *Interaction of Color*, Tschichold's *New Typography*, the Vignelli *Canon*, Müller-Brockmann's *Grid Systems*, Klein's monochrome manifesto, Cartier-Bresson's own definition of the decisive moment, Sottsass's Memphis rejection of "good design," documented Hokusai pigment use, and Vermeer's optical technique).

This doctrine exists because the workflow's design-side agents (`visual-craft-lens`, `design-reviewer`, `frontend-developer`, `frontend-design`, `ios-ui-developer`) were previously critiquing UI in generic, vocabulary-only terms: "palette," "hierarchy," "spacing." Generic vocabulary produces generic taste. **Real taste is grounded in real artists.** When you (the agent) are evaluating or creating UI work, read this file once and apply the principles below — not as rules to recite, but as **eyes to see with**.

The doctrine is organized as **principles that transfer to UI**, not biography. For each artist or movement, you get: (a) what they *did differently*, (b) the canonical UI transfer. If you have time only for the conclusions, jump to **§8 Non-obvious calls** and **§9 How to use this doctrine**.

---

## §1. Color masters

### Mark Rothko — color as emotional architecture
Rothko's late color-field paintings work by **edge dissolution**: the boundary between two color zones is feathered, not stated, so the field "breathes" rather than abuts. Three things distinguish a Rothko from a colorblock:
1. **Edge dissolution** — the boundary is feathered, not stated; there is a *zone of transition*.
2. **Translucent layering** — Rothko's reds are not "a red," but 5–12 thin glazes; lower colors *show through*. The color is alive because it has *depth*.
3. **Body-scale proportion** — Rothkos are 8 feet tall for a reason. They *surround* the viewer.

**UI transfer:** Gradients should feather, not stop. A "background" is rarely one color — it's a stack, even at small scale. A solid hex value over a noise/gradient base, slightly translucent, reads as substance; a flat hex reads as a colorblock. Always evaluate composition at *delivery dimensions*, not at Figma 2x.

### Josef Albers — *Interaction of Color* (Yale, 1963)
Albers's central thesis, stated outright: *"In order to use color effectively it is necessary to recognize that color deceives continually."* **Simultaneous contrast** is the rule — a swatch is never the color it is *by itself*; it is the color it becomes when set next to its neighbor. The same gray reads warm next to cool, cool next to warm.

**UI transfer:** Never approve a color from a swatch. Approve it *in situ*. A button color tested against `#FFFFFF` will misbehave against the panel color it actually lives on. Tokens should be tuned to their *neighborhood*, not to a global palette spec. The "neighbor effect" check is one of the highest-yield audits on any UI.

### Henri Matisse — chromatic boldness as structure
Matisse used color as *drawing*. A red interior is not "red walls" — it's a structural decision about which plane carries the weight. He flattens space deliberately so color, not perspective, organizes the picture.

**UI transfer:** Color hierarchy can substitute for shadow/depth hierarchy. A flat UI can read structured if one color carries the load. "Flat" is not a constraint; it's a *redirection* of the structural work onto color.

### Yves Klein — saturation as substance (IKB)
Klein patented International Klein Blue (1960) with a matte synthetic-resin binder *specifically because traditional oil binders desaturated ultramarine*. He treated saturation not as decoration but as *material*. He wrote that monochromy was "the only physical way of painting that enables access to a spiritual absolute."

**UI transfer:** A truly saturated single color, used at scale, has weight that no palette can replicate. The temptation to "soften" a brand color almost always reduces it. The binder matters — translate to: rendering, sub-pixel anti-aliasing, contrast against neighboring elements.

### Gustav Klimt — gold as field, pattern as ground
Klimt's gold-period work (*The Kiss*, *Adele Bloch-Bauer I*) treats ornament as *the ground*, not as decoration laid on top. The figure emerges from the pattern; the pattern doesn't sit on the figure.

**UI transfer:** Decorative texture works when it is the *ground*, not a sticker. If you can lift the ornament off without changing the composition, it's stuck on. Klimt's ornament could not be removed.

### Hokusai — limited palette discipline
*The Great Wave off Kanagawa* uses **three pigments**: Prussian blue (multiple shades), a yellow hue for boats and sky, and black/gray. The Prussian blue itself was a 19th-century European synthetic — a deliberate, technical, single-pigment choice that made the print's identity.

**UI transfer:** A constrained palette executed with discipline outperforms an expanded one used casually. *The constraint is the design.* Three colors used at five lightness values each beats fifteen colors used once.

### Vermeer — light as material
Vermeer's interiors work because light is *modeled*, not lit. He likely used a camera obscura to study the optical "discs of confusion" — small blurred highlights — and painted those highlights as if they were objects with mass (the bread crust in *The Milkmaid*, the metal jug). Light has surface texture.

**UI transfer:** A highlight is not a +20% lightness step on a base color. It's a *material* with its own optical behavior — softer near matte surfaces, sharper near specular. Most UI "shine" fails because it's drawn, not modeled. A composed UI has one consistent light direction whose behavior agrees across every surface; a captured UI has shadows pointing different directions because each component was designed in isolation.

### J. M. W. Turner — atmospheric color
Turner's late work (*Norham Castle, Sunrise*, c.1845) dissolves form into color and light. Just enough representational anchor remains to keep the eye oriented; everything else is atmosphere. He treats light as the *subject*, not the illumination.

**UI transfer:** A "background" can carry as much meaning as the foreground when atmospheric. Empty space tinted with care reads as *weather*, not as void.

### James McNeill Whistler — tonal harmony, the "nocturne"
Whistler titled his paintings *Nocturne in Blue and Silver*, *Symphony in White* — he treated paintings as **arrangements of tone**, not depictions. Hue is constrained; *value* does the work. A nocturne might span 8 colors, all within a 15% value range.

**UI transfer:** A tonally restricted UI (narrow value range, narrow hue range) reads as *composed*; a tonally scattered one reads as *designed-by-features*. Match values across surfaces before optimizing hues.

---

## §2. Composition masters

### Piet Mondrian — asymmetric grid balance
Mondrian's *Compositions* are not symmetric — they are *balanced* by mass and color weight against negative space. A small red block balances a large white field because red has visual mass. The grid is the *invisible* structure that organizes the asymmetry.

**UI transfer:** Symmetric layouts are the easy default and the boring one. Asymmetric layouts can be more stable if mass is balanced against void. **A small color-saturated element holds a large empty one.**

### Hokusai — negative space and *ma*
*The Great Wave* gives the wave two-thirds of the frame; Mount Fuji is small, distant, vulnerable. The composition works because the *empty* sky between them carries the tension. The pause is the picture.

**UI transfer:** Empty space is not "unfinished" — it is the field against which content reads. The strongest move on a crowded screen is usually subtraction.

### Vermeer — window-light geometry
Vermeer's interiors are almost always lit from a single source — a window at left, usually. The light enters at a known angle; objects model accordingly; the geometry of the room is *implied* by the falloff.

**UI transfer:** A single, consistent light direction across an interface reads as a coherent world. Mixed lighting (drop shadows pointing different ways, conflicting highlights) reads as collage.

### Henri Cartier-Bresson — the decisive moment
Cartier-Bresson's own definition: *"the simultaneous recognition, in a fraction of a second, of the significance of an event as well as of a precise organization of forms which give that event its proper expression."* Geometry — leading lines, rule of thirds, diagonals — was instinct, not method; he said geometric analysis was for *after* the shot.

**UI transfer:** The strongest screen-moments — first paint, empty state, success state, error state — are decisive moments. The composition either lands at the right instant or it doesn't. **Don't compose for the average state; compose for the moments that matter.**

### Caravaggio — chiaroscuro as composition
Caravaggio's tenebrism is not "dramatic lighting" — it is **composition by darkness**. Most of the canvas is plunged into shadow; the lit subject is a spotlight. The dark is not background; *the dark is the frame*.

**UI transfer:** Dark mode is not light mode inverted. The dark surface IS the composition, not the absence of one. The accent color carries the entire weight and must be chosen for it.

### Rothko — compression and field
Rothko's late paintings compress emotion into two or three large fields stacked vertically. The fields aren't bordered; they bleed. The painting works at body-scale — you stand close, the field surrounds you. At thumbnail size the same painting is inert.

**UI transfer:** Composition must be designed for *its rendered size*. A hero designed at Figma 2x scale loses its compression at viewport size.

### Kazimir Malevich — the suprematist void
*Black Square* (1915) is famously a black square on white. The point is not "minimalism" — Malevich placed it in the corner of a room normally reserved for an Orthodox icon. The void is *charged*. Empty becomes meaningful through *placement*, not absence.

**UI transfer:** A blank state has to be *positioned*, not just empty. The void at the center of a hero says one thing; the void in the lower-right says another. Empty is never neutral.

### Sol LeWitt — instructional systems
LeWitt's wall drawings were specified as instructions ("draw 10,000 lines, each 10 inches long, in pencil") and executed by anyone. The art was the *system*, not the artifact.

**UI transfer:** A design system is a LeWitt — the specification is the work; the rendered screen is one execution. If the system cannot be re-executed by another team and yield the same character, the spec is incomplete. **Tokens, not screens, are the design.**

---

## §3. Restraint vs maximalism — when each serves

### Restraint as taste (not fear)

- **Dieter Rams — Ten Principles** (Vitsoe, late 1970s). Verbatim: Good design is *innovative; useful; aesthetic; makes a product understandable; honest; unobtrusive; long-lasting; thorough down to the last detail; environmentally friendly;* and **as little design as possible**. *"Less, but better — because it concentrates on the essential aspects."* Note: aesthetic is principle #3, not an afterthought.
- **Jony Ive — subtractive design.** Apple-era Ive is Rams applied to glass slabs — radii tuned to the millimeter, materials chosen for how they age, removals justified by what they *enable*. The Apple aesthetic is Rams principle #10 shipped at scale.
- **Massimo Vignelli — typographic discipline.** Vignelli's *Canon*: typography is a discipline to organize information *objectively*, not a vehicle for self-expression. His "you can design good work with five typefaces" claim wasn't austerity — it was the assertion that constraints sharpen judgment.
- **Bauhaus / form follows function** (Gropius, 1919). The Bauhaus *Vorkurs* drilled material study before form-making. Function-led, but with the Bauhaus reading of function — *psychological* fit, not just utility.
- **Josef Müller-Brockmann — Swiss grid** (*Grid Systems in Graphic Design*, 1981). Rationality as ethics: the grid was a *moral* commitment to clarity, sans-serif typography, generous white space, and the absence of decoration.

### Maximalism as decision (not clutter)

- **Klimt** — pattern *is* the ground (above). Maximalist *because the maximalism is structural*.
- **Antoni Gaudí** — every surface is structural. Sagrada Família has no decorative element that is not also load-bearing.
- **Hundertwasser** — anti-grid as ideology. He wrote that the straight line is "godless and immoral."
- **William Morris / Arts & Crafts** — pattern as care. The repeat is hand-drawn; the eye finds variation within the repetition.
- **Memphis (Sottsass, 1981–1987)** — anti-modernism by manifesto. Sottsass: rejection of "the cult of good design"; bright colors, plastic laminates, irrational patterns, jokes. Memphis's maximalism is **rhetorical** — a position against the prior generation.

### When restraint serves
- High-frequency interactions (the user will touch this 200 times today).
- Information-density screens (data tables, dashboards, IDEs).
- Trust-required surfaces (banking, medical, legal).
- Long lifespans (the design must survive 10 years of feature additions).

### When maximalism serves
- Identity moments (marketing pages, brand expression, onboarding).
- One-time or rare interactions (signup, celebration, achievement).
- Differentiation in a crowded category where everyone is Swiss.
- Emotional surfaces where neutrality reads as cold.

### The diagnostic
- **Restraint as taste:** a clear hierarchy of *what was kept and why*. Removals were active choices.
- **Restraint as fear:** absence of decisions disguised as minimalism. Everything is gray. The screen reads as a wireframe shipped.
- **Maximalism as decision:** every additional element has a job. Removal would *break* something specific.
- **Maximalism as clutter:** elements accreted because nothing was removed. Removal would *improve* something specific.

**The single-question diagnostic:** *can you remove any single element without the composition collapsing?* If yes — it was clutter, not maximalism. If no — it was a decision, regardless of element count.

---

## §4. Movement principles for digital craft

- **Bauhaus** — geometric primaries (circle, square, triangle) mapped to primary colors (red, yellow, blue) by Itten/Kandinsky/Klee in the *Vorkurs*. UI: geometric primitives are not "boring shapes" — they are the most-expressive units when used at the right scale.
- **De Stijl / Mondrian** — orthogonal grid + primaries + black/white only. The rule is the design. UI: a self-imposed constraint shipped consistently across 100 screens reads as identity; the same constraint broken at screen #4 reads as failure.
- **Swiss / International Typographic Style** — grid, sans-serif, ample white space, ragged-right alignment, photography over illustration. UI: the Swiss grid is the spiritual ancestor of the 8pt baseline grid. Most modern UI is Swiss-with-decoration.
- **Japanese aesthetics:**
    - **ma** (間) — the meaningful pause; *charged* space, not "white space."
    - **wabi-sabi** — beauty in imperfection, impermanence. UI: hand-drawn moments inside a systematic interface; the occasional asymmetry that signals "made by humans."
    - **kanso** (簡素) — elimination of the superfluous. Stricter than minimalism — it asks *"is this necessary?"* not "does this feel clean?"
    - **shibui** (渋い) — understated elegance, quality that does not announce itself. UI: a button that just works.
    - **yūgen** (幽玄) — profound suggestion; beauty felt rather than described. UI: micro-interactions that hint at depth without explaining themselves.
- **Memphis** — playful breakage of modernist rules; bright colors, irrational patterns, humor. UI: humor and weirdness applied as *position*, not as filler.
- **Brutalism (architectural; web-Brutalism is a derivative)** — raw materiality, exposed structure, anti-decoration. The point isn't ugliness; it's *honesty about the medium*. UI: default browser-monospace, exposed semantic HTML, no decorative gradients — when the rhetorical move is honesty.
- **Art Nouveau** — organic line, integrated ornament, the curve as ideology (Mucha, Beardsley, the Paris Métro). UI: a curve is a *political* choice against the orthogonal grid.
- **Constructivism (Rodchenko, El Lissitzky)** — geometric activism, diagonal energy, photomontage, type as image. UI: a 15° rotated element among orthogonal elements *will* dominate the page — use only when the rhetorical weight is intentional.

---

## §5. Typography / lettering masters

- **Jan Tschichold — *The New Typography* (1928).** Asymmetric composition, sans-serif, white space as compositional element, hierarchy via size/weight/position not decoration. *"Asymmetry is the rhythmic expression of functional design."* Tschichold later *recanted* (Penguin Books, 1947+) and moved to centered classical typography — which is its own lesson: **the doctrine that produces the best work depends on what the work has to do.** UI: marketing landing pages need 1928 Tschichold. Long-form reading needs 1947 Tschichold.
- **Herb Lubalin** — expressive typography. Type as image. The letterform as graphic event. UI: display type can carry meaning beyond its words; body type must not.
- **Saul Bass** — *"Design is thinking made visual."* Identity through motion (*Vertigo* titles), 80 corporate identities. Bass's title sequences treated typography as cinema — letters moved with intent. UI: motion is typography's fourth dimension. *Where a letter arrives from* communicates as much as where it sits.
- **Paula Scher** — typographic scale as expression (Public Theater). Type at architectural scale, words as composition. UI: the size differential between H1 and body is the editorial voice. A timid 1.5x ratio reads as committee; a 5x ratio reads as authored.
- **David Carson** — *Ray Gun*, "the end of print." Grunge typography, illegibility as a statement. Carson's point was that *legibility is not communication* — sometimes the affect IS the message. UI: Carson is the corrective when everyone is Swiss. He is wrong for medical interfaces.
- **Massimo Vignelli — the five-typeface principle.** Vignelli claimed everything could be designed with: Garamond, Bodoni, Century Expanded, Times Roman, Helvetica (later, Univers). The argument: typeface choice is rarely the bottleneck; *use* is. UI: **font shopping is procrastination. Pick two and master them.**
- **Erik Spiekermann** — everyday utility (Berlin transit, Meta, FF Unit). Faces designed for *the conditions they'll be read in* — bad printing, low light, small sizes. UI: test the body face at 14px on a phone in sunlight. **Not in Figma.**

---

## §6. Industrial / product design masters

- **Dieter Rams — the Ten Principles** (above). The benchmark for every adjacent field, including UI.
- **Charles & Ray Eames** — warmth + function. The Eames Lounge, the molded plywood chair, *Powers of Ten*. The Eameses showed that functional design can be *affectionate* — playfulness was a Bauhaus output, not an opposition to it. UI: **humanity and rigor are not opposed.**
- **Achille Castiglioni** — wit and the ready-made. The *Toio* lamp (1962) uses a car headlight and a surplus transformer; the *Sella* stool uses a bicycle saddle. A "rational expressionist" — improving products through *recognition* of an existing form's new use. UI: the strongest interactions are often *recognized gestures* (Fukasawa's MUJI pull-string), not invented ones.
- **Naoto Fukasawa — "Without Thought."** Design that integrates into life so completely it disappears. The MUJI wall CD player is operated by pulling a string — an *archetypal gesture* from ventilation fans, requiring no learning. UI: **the best interaction is one the user does not consciously notice.** If the user thinks about *how* to use it, the design failed; if they only think about *what* to do, it succeeded.
- **Jasper Morrison — Super Normal** (with Fukasawa, 2006). Two hundred objects "absent of identity, originality, and elements that leave an impression." The argument: novelty is overrated; refinement is undervalued. UI: **"the boring choice that just works" is often the highest-craft choice.** Originality should be earned.
- **Marc Newson** — sculptural product form (Lockheed Lounge, Apple Watch industrial design). Products as objects, not as assemblies. UI: the *whole* of a screen has a form, not just its parts.
- **Jonathan Ive** — Rams principles + materials science + tolerance discipline. Ive's contribution wasn't aesthetic; it was *executional rigor* at scale. UI: a 1px difference is a 1px difference; **tolerances matter at every magnification.**

---

## §7. Photographers with applicable visual judgment

- **Cartier-Bresson** (above) — decisive moment, geometry-as-instinct.
- **Richard Avedon** — subject isolation. White seamless backgrounds, formal portraits, the subject *only*. The void around the subject *is* the portrait. UI: isolated UI elements (the modal, the focused input) work by what is *removed* from around them.
- **Hiroshi Sugimoto** — long-exposure simplification. Seascapes are a horizon line, an exposure of an entire movie compressed to a single frame. Time *averaged* into stillness. UI: what a state looks like *averaged over time* is what the design feels like. Optimize the steady-state, not the peak.
- **Saul Leiter** — color as emotion. Shooting through rain-soaked glass, framing through obstructions, color as mood not object. UI: color does not have to identify; it can simply *feel*. Background washes that signal mood without naming anything are the Leiter move.
- **Robert Frank — *The Americans*** — gritty truth, off-kilter framing, the deliberate refusal of the magazine-perfect shot. UI: sometimes the "wrong" framing — a slight crop, an unexpected silence, an absence — reads as more honest than the polished alternative.

---

## §8. Non-obvious calls (the highest-leverage section)

These are the calls a generic critic cannot make. If you read nothing else from this doctrine, read these.

### Rothko vs colorblock
Three things distinguish them: **(1) edge dissolution** (feathered boundary, not stated); **(2) translucent layering** (5–12 thin glazes; lower colors show through; the color is *alive*); **(3) body-scale proportion** (8 feet tall for a reason — surrounds the viewer). A Rothko-style composition at thumbnail size loses 80% of its function. **UI diagnostic:** flat hex value = colorblock; same hex over a noise/gradient base, slightly translucent, at the right size = Rothko-adjacent.

### Vermeer interior vs stock photo of an interior
A Vermeer is *modeled*, not *captured*. Light has a single direction, decided in advance. Falloff is mathematically consistent across every surface. Highlights have *mass* — they sit on the bread crust as a separate optical event, not as a render artifact. A stock photo accepts the light it found; a Vermeer composes the light. **UI diagnostic:** ask of every screen "does the light agree across all surfaces?" Most don't. The ones that do read as designed.

### "Designed by committee" vs "designed by a person with taste"
- **Committee:** every stakeholder's feature is visible somewhere. Hierarchy is flat because no one would accept being second. Palette has 11 hues. Multiple competing emphases per screen. Padding values are even but arbitrary (someone said "use 8-multiples") rather than tuned.
- **Person:** ruthless hierarchy — one thing dominates per screen. Palette is constrained (3–5 hues, multiple values each). Spacing is tuned by eye *after* the system is set — some 12s, some 14s, where they read better. Things are visibly *removed*, not just *not added*. The screen has *a point of view*.

The diagnostic question: **what does this screen care about?** A committee-designed screen cares about everything equally; a person-designed screen cares about one thing more than the others.

### Restraint as taste vs restraint as fear
- **Taste restraint** is *editorial* — you can name what was removed and why. Remaining elements got *more* attention, not less. There is hierarchy, just within a tight range. Rams ships fewer features *and* the features he ships are more refined.
- **Fear restraint** is *avoidant* — gray on gray, no commitment to a color, no commitment to a typeface, decorative neutrality. The screen reads as *"I didn't want to be wrong."* A wireframe shipped to production.

Diagnostic: **what does the designer believe?** If you can't name a belief from the artifact, it's fear, not taste.

### Maximalism as decision vs maximalism as clutter
- **Decision maximalism** — every additional element has a *role*: structural (Klimt — pattern is the ground), rhetorical (Memphis — wrongness is the point), or affective (Art Nouveau — the curve is the worldview). Removal would *break* something specific.
- **Clutter maximalism** — elements accreted because no one removed them. Three competing CTAs. Decorative gradient + decorative pattern + decorative illustration *behind* the actual content. Removal would *improve* something specific.

Diagnostic: **try mentally removing each element**. If removal makes the composition collapse — it was a decision. If removal makes it clearer — it was clutter. **Klimt's ornament cannot be removed. A SaaS landing page's hero illustration usually can be.**

---

## §9. How to use this doctrine

When reviewing or creating a UI artifact, ask in order:

1. **What is this trying to *do*?** (decisive moment, identity moment, information-density, trust surface) — this picks the family of principles.
2. **What did it *decide*?** Hierarchy, palette discipline, light direction, typographic scale, grid commitment. **Name the decisions; if you can't, the design didn't make any.**
3. **What did it *remove*?** A design's character is as much in the absences as the presences. If nothing is visibly missing, the design has not been *edited*.
4. **Does it have *a* point of view, or *several* points of view?** Several = committee. One = person with taste. (Several can be intentional — Memphis is several — but it has to be *one decision* to be several.)
5. **Where is the *neighbor effect*?** (Albers) — does the design account for what each element looks like *in situ*, or only in the swatch panel?
6. **Where is the *neighborhood*?** (Vermeer) — does the light/shadow/highlight system agree across surfaces, or do surfaces each have their own world?

When **producing** UI, run the same questions on your own draft before shipping it. Most generic AI-produced UI fails at #2 ("name the decisions") and #3 ("name the removals"). If you can't answer those, you don't have a design yet — you have a default.

---

## §10. The art-taste failure modes (catalog of what generic UI does wrong)

Catalog format: *symptom → which principle it violates → the concrete UI move that fixes it*.

- **Centered hero with CTA over a generic blue-to-purple gradient** → §3 fear restraint + §1 Hokusai limited palette → commit to a single saturated color (Klein) or a designed-feather two-tone (Rothko) at the right body-scale (§2 Rothko field).
- **Three identical feature cards in a symmetric row** → §2 Mondrian asymmetric balance violation → vary mass; let one card hold three; balance via void, not via mirror.
- **Default `bg-blue-500` / `.systemBlue` / generic indigo** → §1 Hokusai discipline + §1 Klein saturation as substance → pick one committed hex; reject "tailwind blue" as evidence of zero decision.
- **Inter / SF Pro at default weight everywhere** → §5 Vignelli use-not-typeface + §5 Paula Scher scale-as-voice → commit to a weight axis and a 4–5x H1/body ratio. Two faces (or two weights) mastered, not five faces shopped.
- **Uniform `py-16` on every section** → §2 Hokusai *ma* + §2 Rothko compression → vary density. The empty space between sections should differ by purpose, not by template.
- **`shadow-lg` everywhere** → §1 Vermeer light direction + §6 Ive tolerance → either remove shadow (Bauhaus / Swiss) or commit to a designed 3–5 level stack with one consistent light direction.
- **No visual signature element** → §3 restraint-as-fear → name one thing that, if removed, would change the brand. If nothing qualifies, the design has no taste yet.
- **"Get Started" / "Learn More" as the only CTA copy** → §6 Fukasawa "Without Thought" violation — the user must *think about how to start* when the design should make the next move obvious — replace with verb+object that names the next action.
- **Decorative pattern + decorative gradient + decorative illustration behind content** → §8 clutter maximalism — try removing each. If the screen improves, it was clutter.
- **Dark mode that is light mode inverted** → §2 Caravaggio chiaroscuro violation — dark mode IS the composition; the accent must carry the entire weight.
- **A "designed by committee" screen** (§8) — name the *one thing* this screen cares about. If you can't, neither will the user.

---

## §11. Motion and digital-native masters

UI is increasingly motion-driven, and the canon's main strength is in static composition. This section names the masters whose work translates directly to screen-motion and digital-native craft — distinct from the static-image principles above.

### Motion-design canon

- **Disney's 12 Basic Principles of Animation** (Thomas & Johnston, *The Illusion of Life*, 1981) — squash and stretch, anticipation, staging, straight-ahead vs pose-to-pose, follow-through and overlapping action, slow in / slow out (the *ease curve*), arcs, secondary action, timing, exaggeration, solid drawing, appeal. **UI transfer:** the spring (slow-in/slow-out), anticipation (a button "wind-up" before it acts), follow-through (a card that overshoots then settles), and arcs (no linear translates — natural motion follows curves) are the four principles every UI motion designer applies whether or not they name them. A flat `linear` easing curve is the UI equivalent of *not animating at all*.
- **Saul Bass — title sequence as motion typography** (1955–1990s). Beyond the one-line earlier: Bass treated the *arrival* and *exit* of every letter as cinematography. The *Vertigo* opening pulls type out of an eye; *Psycho* shears the type apart on the stab. UI: where a notification arrives from, how a modal exits — these are typographic decisions, not transition decisions.
- **Pixar's emotional motion** (Lasseter onwards) — *Luxo Jr.* (1986) established that motion alone can carry character. A desk lamp with no face can be a child. **UI transfer:** a loading spinner with the right ease and pause timing reads as *patient* or *impatient*; an error shake reads as *firm* or *frustrated*. Motion has character whether you design it or not.
- **Material Design motion principles** (Google, Matías Duarte, 2014) — *responsive* (acknowledges input), *natural* (matches physical-world expectation), *aware* (knows context), *intentional* (every motion has a reason). Google's contribution wasn't inventing motion principles but *codifying* them for a generation of UI designers. **UI transfer:** when in doubt about whether a transition belongs, Material's *intentional* test settles it — if you can't name what the motion communicates, remove it.
- **Apple's "Designed for iOS" motion vocabulary** (since iOS 7, refined through iOS 17 spring system, iOS 26 Liquid Glass) — physics-based springs with mass/stiffness/damping; matched-geometry effects that morph an element across views; haptic-coupled motion that arrives with a tactile receipt. **UI transfer:** Apple's spring defaults are tuned by people who tested them on 10⁹ devices — start there, deviate only with reason.

### Digital-native masters

- **Susan Kare** (Apple Macintosh icons, 1983–86; NeXT; Microsoft; General Magic; Pinterest). Kare invented *visual literacy* for the desktop GUI — the trash, the bomb dialog, the watch cursor, Chicago typography. Her constraint was brutal: 32×32px monochrome bitmap, no anti-aliasing. **UI transfer:** the more constrained the canvas, the more the design DECISIONS show. Kare's icons are studied today because every pixel was a choice. Application: at favicon scale, mobile splash, badge counter scale, every pixel still has to *decide*.
- **John Maeda — *The Laws of Simplicity* (2006)**. Maeda's ten laws: *Reduce* (shrink, hide, embody), *Organize* (multiple appear fewer), *Time* (savings in time feel like simplicity), *Learn* (knowledge makes everything simpler), *Differences* (simplicity and complexity need each other), *Context* (what lies in the periphery is not peripheral), *Emotion* (more emotions are better than fewer), *Trust* (in simplicity we trust), *Failure* (some things can never be made simple), and *the One* (simplicity is about subtracting the obvious and adding the meaningful). **UI transfer:** Maeda is what happens when Rams meets the screen. "Organize: multiple appear fewer" is the single best framing for information-density screens (dashboards, IDEs, settings panels).
- **Edward Tufte — *The Visual Display of Quantitative Information* (1983), *Envisioning Information* (1990), *Beautiful Evidence* (2006)**. Tufte's principles: *data-ink ratio* (every drop of ink should carry information), *chartjunk* (decorative chart elements are the enemy), *small multiples* (the same chart repeated with one variable changed beats one large chart with many variables), *sparklines* (word-sized graphics that integrate into text), *the smallest effective difference* (tonal/color contrast should be the *minimum* that distinguishes, not the maximum). **UI transfer:** any data-dense UI is a Tufte exercise. A dashboard with decorative axes, gradient bar fills, and 3D pie charts has lost Tufte's data-ink fight before the data was even read. Sparklines belong inline in tables; charts belong only when sparklines are insufficient.
- **Khoi Vinh** (Behance, NYT design director, *Subtraction.com*) — grid systems applied to editorial digital design at scale. Vinh's argument: the grid is a *structural commitment* the reader can feel, not a tool the designer uses. **UI transfer:** a designed grid (12-column or otherwise) that is visibly *honored* across the product — not just used as a layout tool — reads as editorial care; an ad-hoc layout reads as default.
- **Bret Victor — *Inventing on Principle* (2012), *Magic Ink* (2006), *Ladder of Abstraction*** — direct manipulation, immediate visual feedback, *information graphics* as the medium of computation. Victor's tools (Apparatus, Dynamicland) embody his argument: the future of UI is *making the underlying system visible and manipulable*. **UI transfer:** "modify a value, immediately see the effect everywhere it appears" is Victor's principle applied to a settings panel, a CSS editor, a flowchart UI.
- **Don Norman — *The Psychology of Everyday Things* (1988; retitled *The Design of Everyday Things* 1990; revised 2013)** — affordances (what an object *suggests* it can do), signifiers (the perceived signals of affordances), feedback, mapping (the relationship between controls and effects), constraints, and conceptual models. The hidden-door anti-pattern: a door that requires a push but has a handle that affords a pull. **UI transfer:** a button that looks like text, or text that behaves like a button, fails Norman's affordance test. A toggle that doesn't visually shift on activation fails his feedback test.

### What this section consciously does NOT cover

Animation timing functions in detail (cubic-bezier math); specific motion libraries (Framer Motion, GreenSock, Lottie); game-design canon (Schell, Koster); academic HCI literature (Shneiderman beyond the 8 golden rules); spatial computing / AR design (Apple's HIG visionOS, Meta's HIG). These extend the doctrine but were scoped out to keep the reference under 5000 words. Future revisions may expand if shipping product needs name a specific gap.

---

## Primary sources

- Rams's Ten Principles — Vitsoe (canonical: https://www.vitsoe.com/us/about/good-design)
- Albers, *Interaction of Color* (Yale, 1963; expanded 2013)
- Tschichold, *Die neue Typographie* (1928); later Penguin Books work (1947+)
- *The Vignelli Canon* (RIT Vignelli Center, free PDF, 2010)
- Müller-Brockmann, *Grid Systems in Graphic Design* (Niggli, 1981; reissue 2015)
- Rothko, *The Artist's Reality* (written c. 1940–41; published 2004, Yale)
- Klein, IKB Soleau envelope — INPI, Paris, 19 May 1960 (Édouard Adam binder formulation)
- Hokusai, *The Great Wave off Kanagawa* (c. 1831)
- Vermeer and the camera obscura — Essential Vermeer
- Bauhaus principles and *Vorkurs* — Getty Research
- Memphis Group / Sottsass (1981–1987) — anti-modernism manifesto
- Fukasawa / Morrison, *Super Normal* exhibition (2006)
- Cartier-Bresson, *The Decisive Moment* (1952)
- Caravaggio and tenebrism — TheArtStory
- Japanese aesthetic principles — *ma, wabi-sabi, kanso, shibui, yūgen*
- Thomas & Johnston, *The Illusion of Life: Disney Animation* (1981) — the 12 principles
- John Maeda, *The Laws of Simplicity* (MIT Press, 2006)
- Edward Tufte, *The Visual Display of Quantitative Information* (Graphics Press, 1983)
- Don Norman, *The Psychology of Everyday Things* (Basic Books, 1988; retitled *The Design of Everyday Things* in the 1990 paperback; revised 2013)
- Susan Kare, original Macintosh icon set (Apple, 1983–86)
- Bret Victor, *Inventing on Principle* (CUSEC 2012 talk; transcript at worrydream.com)
