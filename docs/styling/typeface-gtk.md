# Typeface probe — GTK4 / libadwaita (kaya-linux container)

Measure-first probe for docs/styling-plan.md Slice 2b. NO repo files
touched; every artifact lives under the session scratchpad.

Platform under test: `kaya-linux` image (debian trixie
@sha256:fac46bff…), GTK 4.18.6, libadwaita 1.7.6, Pango 1.56.3,
fontconfig 2.15.0, on BOTH lane display backends — `GDK_BACKEND=x11`
under `xvfb-run -a -s "-screen 0 1024x768x24"` and `GDK_BACKEND=wayland`
under headless sway, matching tools/linux/run-suites.sh:305/323.

## The three answers in one paragraph

Apply with a `GtkCssProvider` at `STYLE_PROVIDER_PRIORITY_APPLICATION`
holding `:root { font-family: "<family>"; }` — the exact provider shape
the accent already uses (gtk.rs:6275). The whole libadwaita type ramp
keeps its sizes and weights to the pixel; only the family moves. Read
back by loading the font the widget's own `PangoContext` resolves and
asking the FONT what it is — `ctx.load_font(ctx.font_description())`
then `font.describe().family()`, cross-checked with
`font.face().family().name()`. Never read `ctx.font_description()`
itself: that is the request, and it echoes a nonsense family back
verbatim. `KayaNoSuchFamily-9x` resolves to **`DejaVu Sans`** on this
image, on both display backends, and — the finding that decides the
slice — **the fallback render is byte-identical to the unbranded
render** (same PNG sha256, 0 differing pixels), so no pixel assertion
can ever see it.

---

## §0 — what fonts the lane image actually has (MEASURED)

`fc-list : family` reports THREE real families and nothing else:

```
DejaVu Sans
DejaVu Sans Mono
DejaVu Serif
```

Packages: `fonts-dejavu-core 2.37-8`, `fonts-dejavu-mono 2.37-8`. No
Cantarell, no Adwaita Sans, no Noto, no Liberation. **The Dockerfile
installs no font package by name** — DejaVu arrives as a transitive
dependency, so the lane's font set is incidental, not chosen.

`pango-list` adds the aliases fontconfig synthesizes: `Sans`, `Serif`,
`Monospace`, `System-ui`. The realized `PangoFontMap` agrees:

```
DejaVu Sans, DejaVu Sans Mono, DejaVu Serif, Monospace, Sans, Serif, System-ui
```

**fc-match never fails.** Every one of these returns DejaVu Sans:

```
sans                   -> DejaVuSans.ttf: "DejaVu Sans" "Book"
serif                  -> DejaVuSerif.ttf: "DejaVu Serif" "Book"
monospace              -> DejaVuSansMono.ttf: "DejaVu Sans Mono" "Book"
Cantarell              -> DejaVuSans.ttf: "DejaVu Sans" "Book"
Adwaita Sans           -> DejaVuSans.ttf: "DejaVu Sans" "Book"
system-ui              -> DejaVuSans.ttf: "DejaVu Sans" "Book"
KayaNoSuchFamily-9x    -> DejaVuSans.ttf: "DejaVu Sans" "Book"
```

Cantarell — GNOME's default, and what the WAYLAND leg actually asks for
(§4) — is absent and already falling back silently. So is `Adwaita
Sans`, libadwaita 1.7's own default. **The silent-fallback pathology is
not hypothetical on this lane; it is the lane's steady state today.**

### Safely present family names for a cross-platform demo

Only `DejaVu Sans`, `DejaVu Serif`, `DejaVu Sans Mono`. For the linux
row of `brand_typeface`'s per-platform table, **`DejaVu Serif`** is the
right demo value: it is present, and it is visibly different from the
default (`DejaVu Sans`), so the positive leg of the scene actually
discriminates. `DejaVu Sans` would be useless as a demo value — it is
what the fallback produces, so a scene asserting it would pass with the
lowering deleted.

RECOMMENDATION: name the font package in tools/linux/Dockerfile
explicitly (`fonts-dejavu-core`), so the expected string in the scene
rests on a reviewed line rather than on somebody else's dependency. If
a more distinctive demo face is wanted, `fonts-cantarell` also makes the
Wayland leg's DEFAULT correct instead of silently substituted.

---

## §1 — THE APPLY ROUTE (question 1)

### The route

```css
:root { font-family: "DejaVu Serif"; }
```

in a `GtkCssProvider` added to the display at
`GTK_STYLE_PROVIDER_PRIORITY_APPLICATION` (600). This is precisely the
position the accent lowering already argued for and holds: above
libadwaita's stylesheet (THEME, 200) and above the settings-derived
values (SETTINGS, 400), below the user's `~/.config/gtk-4.0/gtk.css`
(USER, 800) — so a user who overrides the app still wins, which is D2
holding structurally with no code.

### It keeps the platform's ramp — measured, to the pixel

Nine surfaces (`.title-1`, `.title-2`, `.title-4`, `.heading`,
`.caption`, `.monospace`, a `.suggested-action` button, an entry, plain
body text) on a presented window. CSS-computed size in px / weight,
baseline vs branded:

```
widget      A_baseline      B :root=DejaVu Serif   C :root=nonsense
body        13.33/400       13.33/400              13.33/400
title-1     24.13/800       24.13/800              24.13/800
title-2     18.13/800       18.13/800              18.13/800
title-4     15.73/700       15.73/700              15.73/700
heading     13.33/700       13.33/700              13.33/700
caption     10.93/400       10.93/400              10.93/400
monospace   14.67/400       14.67/400              14.67/400
button      13.33/700       13.33/700              13.33/700
entry       13.33/400       13.33/400              13.33/400
```

Identical in every cell. Family only.

### `:root` vs `*` — NOT interchangeable, and `:root` is the correct one

Measured with the same provider content under both selectors:

| selector | `.monospace` request | `.monospace` resolved |
|---|---|---|
| `:root` | `Monospace 14.667px` | DejaVu Sans Mono |
| `*` | `DejaVu Serif 14.667px` | **DejaVu Serif** |

`* { font-family: … }` clobbers the monospace slot, because `*` matches
the `.monospace` element itself and beats the theme rule; `:root` sets
an inherited value the theme's own rule overrides where it should.
Extracting libadwaita's compiled stylesheet
(`gresource extract libadwaita-1.so.0 /org/gnome/Adwaita/styles/base.css`)
gives the complete list of selectors that declare `font-family` at all
— and it is only the monospace family:

```
.monospace                          { font-family: var(--monospace-font-family); … }
row.entry.monospace                 { font-family: inherit; … }
row.entry.monospace text            { font-family: var(--monospace-font-family); … }
row.property.monospace, …           { font-family: inherit; … }
row.property.monospace > … .subtitle{ font-family: var(--monospace-font-family); … }
```

GTK's own built-in Adwaita (`libgtk-4.so.1`) declares `font-family`
nowhere. So `:root` reaches EVERYTHING except the deliberate monospace
slot. **Use `:root`. Never `*`** — kaya's own text editor is monospace,
and `*` would swap the editor's face to the brand family.

### The monospace slot has its own documented knob (bonus)

libadwaita 1.7 declares `.monospace` off a custom property, so kaya can
reach it symmetrically if a mono brand slot is ever wanted:

```
:root { --monospace-font-family: "DejaVu Serif"; }   -> .monospace resolves DejaVu Serif  (natW 212 -> 222)
:root { --monospace-font-family: "KayaNoSuchMono-9x"; } -> resolves DejaVu SANS           (natW 217)
```

TRAP if that is ever used: the property replaces the whole family
string, `monospace` generic included, so a missing family there loses
monospacing entirely (falls to the proportional DejaVu Sans, not to
DejaVu Sans Mono). Out of scope for slice 2b; recorded so it is not
rediscovered.

### The SETTINGS route is REJECTED — it rescales the ramp

`GtkSettings:gtk-font-name = "DejaVu Serif 11"` swaps the family AND
moves every size, because the theme's ramp is relative to the settings
font size:

```
widget      baseline(px)   gtk-font-name="DejaVu Serif 11"
body        13.33          14.67
title-1     24.13          26.55
title-2     18.13          19.95
title-4     15.73          17.31
caption     10.93          12.03
```

That is "substitutes the scale", which DESIGN.md ratified against. It
CAN be repaired by parsing the current value and splicing only the
family (`Pango.FontDescription.from_string` → `set_family` →
`to_string`), which I measured preserving the ramp exactly — but it is
still the wrong route: it stomps a session-global setting from inside an
app, it is a string round-trip through a `PangoFontDescription` parse,
and it sits at SETTINGS priority where the CSS route already outranks
it. Rejected. `brand_typeface` writes CSS and nothing else.

### The provider lifecycle: add ONCE, rewrite content

Two patterns were run against the same sequence of family changes.

- **Add once at startup, rewrite with `load_from_string`** (what
  `brand_css` already does, gtk.rs:6275/6288): applied on every pass of
  every round — empty → good → nonsense → empty → mono-property →
  nonsense-mono, 100% take rate.
- **Create/add a fresh provider per change, removing the old one**: one
  pass in a seven-pass sequence silently did not apply — the widget's
  request stayed at the settings default while the provider sat
  installed with correct, error-free content. **Reproducible 3 out of 3
  runs**, deterministic, with `parsing-error` never firing. The pass
  before it wrote `GtkSettings:gtk-font-name` in the same main-loop
  turn; a two-turn isolation of that same pair did NOT reproduce it, so
  I cannot state the mechanism, only that the pattern showed a silent
  no-apply and the add-once pattern never did.

CONSEQUENCE: the typeface lowering gets **its own provider**, created
and added once in `activate` beside `brand_css` / `inset_css` /
`container_inset_css`, empty until a typeface arrives, rewritten through
`load_kaya_css`.

**It must NOT share `brand_css`.** `load_kaya_css` replaces a provider's
entire content, and `brand_css` is rewritten from scratch by the
`AdwStyleManager::dark` notify handler (gtk.rs:6317) with only
`brand_css_for()`'s output. A `font-family` parked in that provider
would vanish the first time the session's appearance flipped, with no
error anywhere — a silent failure of exactly the shape this slice
exists to prevent.

---

## §2 — THE HONEST READ (question 2)

Four read routes were measured on realized widgets. Naming them by what
they actually are:

| id | call | reports |
|---|---|---|
| R1 | `widget.pango_context().font_description()` | **the REQUEST** — the CSS-computed description. LIES. |
| R2 | `ctx.load_font(&req)` then `font.describe().family()` | the RESOLVED family |
| R3 | `font.face().family().name()` | the RESOLVED family (font-map object name) |
| R4 | layout run → `item.analysis().font().describe()` | the SHAPED font, per run |

Measured, baseline (no brand), x11 leg:

```
widget      R1 request              R2 resolved            R3 face family
body        Sans 13.333px           DejaVu Sans 9.999      DejaVu Sans
title-1     Sans Ultra-Bold 24.134px DejaVu Sans Bold 18.1 DejaVu Sans
monospace   Monospace 14.667px      DejaVu Sans Mono 11    DejaVu Sans Mono
```

R1 says `Sans`; the text system says `DejaVu Sans`. R2 and R3 agree in
every pass of every round. R4 agrees too (measured separately:
`DejaVu Sans 9.999`, matching R2 exactly).

**Good request, resolved honestly:** `:root { font-family: "DejaVu
Serif" }` → R2/R3 report `DejaVu Serif` on all nine surfaces except
`.monospace`, which correctly stays `DejaVu Sans Mono`.

Two properties of the honest read worth knowing before writing the
observation:

1. **It reports the FACE, not the request, for weight too.** `.title-1`
   requests `Ultra-Bold` (w800); the resolved description says `Bold`
   (w700), because DejaVu has no 800. So `expect_typeface` must assert
   the FAMILY and nothing else — a weight assertion would be brittle for
   reasons that have nothing to do with kaya.
2. **Units change across the boundary.** R1 gives absolute px (GTK CSS);
   R2 gives points (13.333px × 0.75 = 10pt at 96 dpi). Consistent, but
   do not compare the two numbers.

### The Rust chain (checked against pango 0.22.8, the pinned version)

```rust
use gtk4::prelude::*;          // WidgetExt::pango_context
use gtk4::pango::prelude::*;   // FontExt, FontFaceExt, FontFamilyExt

let ctx  = widget.pango_context();
let req  = ctx.font_description();                  // Option<FontDescription> — the ECHO
let font = ctx.load_font(&req.unwrap());            // Option<pango::Font>
let resolved = font.describe().family();            // Option<GString>  <- the honest read
let cross    = font.face().map(|f| f.family().name());
```

All present: `Context::load_font` (auto/context.rs:134),
`FontExt::describe` / `FontExt::face` (auto/font.rs:51/79),
`FontFaceExt::family` (auto/font_face.rs:48), `FontFamilyExt::name`
(auto/font_family.rs:50), `FontDescription::family`
(auto/font_description.rs:63).

The R4 run route is also available and memory-safe in Rust —
`pango::Analysis::font()` is `from_glib_none`, i.e. it takes a reference
(analysis.rs:17), reached via `Label::layout()` → `Layout::iter()` →
`LayoutIter::run_readonly()` → `GlyphItem::item()` →
`Item::analysis()`. It is not needed: R2 is simpler, it agrees, and it
works on widgets that have no `PangoLayout` (buttons, entries).

PROBE ARTIFACT, NOT A GTK ONE: reading `analysis.font` through
PyGObject segfaults — the borrowed pointer inside the `PangoAnalysis`
struct gets a fresh Python wrapper that takes ownership. Chaining
`font.get_face().get_family().get_name()` crashes the same way. Rust's
bindings annotate both correctly. Anyone writing another python probe
here should bind intermediates to locals and expect the run route to be
fragile; the C and Rust APIs are fine.

---

## §3 — THE FALLBACK (question 3), and why it decides the slice

Request `KayaNoSuchFamily-9x`, `:root`, APPLICATION priority:

```
widget      R1 request                          R2/R3 resolved
body        KayaNoSuchFamily-9x 13.333px        DejaVu Sans
title-1     KayaNoSuchFamily-9x Ultra-Bold …    DejaVu Sans
heading     KayaNoSuchFamily-9x Bold 13.333px   DejaVu Sans
caption     KayaNoSuchFamily-9x 10.934px        DejaVu Sans
monospace   Monospace 14.667px                  DejaVu Sans Mono   (untouched)
button      KayaNoSuchFamily-9x Bold 13.333px   DejaVu Sans
entry       KayaNoSuchFamily-9x 13.333px        DejaVu Sans
```

**The exact fallback family this platform reports: `DejaVu Sans`.**
`GtkCssProvider::parsing-error` never fires — a nonsense family is
perfectly valid CSS. Same answer on the Wayland leg.

The fallback does NOT key on the session font: with
`gtk-font-name = "DejaVu Serif 10"` AND a nonsense `:root` family, the
resolution is still `DejaVu Sans`. It keys on fontconfig's `sans-serif`
alias, which is why `fc-match KayaNoSuchFamily-9x` predicts it exactly.
So the expected string for the negative is derivable from the image
without running kaya: `fc-match <nonsense>`.

### The measurement that makes `expect_typeface` mandatory

The same widget tree rendered to PNG through the realized
`GskRenderer`, three cases, both display backends:

```
x11-baseline.png            sha256 a95301b7…    (Sans      -> DejaVu Sans)
x11-KayaNoSuchFamily_9x.png sha256 a95301b7…    (nonsense  -> DejaVu Sans)   IDENTICAL
x11-DejaVu_Serif.png        sha256 37ab8c55…

compare -metric AE  baseline vs DejaVu Serif   = 7643 pixels differ
compare -metric AE  baseline vs nonsense       =    0 pixels differ
wayland: 10145 differ / 0 differ, same conclusion
```

A good family swap moves seven to ten thousand pixels — pixels prove
the apply route. **A nonsense family moves zero, and the PNG is
byte-identical to the unbranded render.** Widget natural widths behave
the same way (198 baseline / 202 branded / 198 nonsense).

So on GTK there is NO pixel, size, geometry or screenshot assertion that
can distinguish "the typeface lowering fell back silently" from "the
typeface lowering never ran" — because on this image those two states
render the same bytes. Only the resolved-family read separates them.
That is the argument for `expect_typeface` stated as a measurement
rather than as a worry.

### …and it forces the shape of the negative test

Because the lane's default resolved family IS the fallback family
(`DejaVu Sans` both ways), an `expect_typeface DejaVu Sans` assertion
after requesting nonsense **passes with the whole lowering deleted**.
That is the vacuous negative CLAUDE.md's invariant 3 has already been
burned by twice. The negative is only a test as a PAIR:

1. request `DejaVu Serif` → `expect_typeface "DejaVu Serif"`. This is
   the discriminating leg; it goes red when the lowering breaks, and it
   is the one to watch failing.
2. request `KayaNoSuchFamily-9x` → `expect_typeface "DejaVu Sans"`,
   with leg 1 in the same scene so the pair cannot both be satisfied by
   a dead lowering.

And the GTK arm's why-not must print **both numbers it measured** — the
CSS-computed request AND the resolved family — because neither alone can
tell the two causes apart:

```
requested "KayaNoSuchFamily-9x", CSS delivered "KayaNoSuchFamily-9x", resolved "DejaVu Sans"
                                                 -> applied, family not installed
requested "DejaVu Serif",       CSS delivered "Sans",                resolved "DejaVu Sans"
                                                 -> the provider never reached the widget
```

A sentence naming only the resolved family is a sentence printed for
both causes, which is the `kayaOpenPanelWhyNot` shape exactly.

---

## §4 — the two linux legs DISAGREE about the default font

Unbranded, same container, same image, same window:

```
leg        R1 request (body)     R2 resolved   natural width
x11        Sans 13.333px         DejaVu Sans   198 px
wayland    Cantarell 14.667px    DejaVu Sans   217 px
```

Under headless sway, GTK's settings default is `Cantarell 11`;
Cantarell is not installed, so the Wayland leg has been silently
rendering a substituted font for its whole life. The X11 leg gets
`Sans 10`. Consequences:

- **Never assert a size or a geometry in the typeface scene.** The two
  legs of one container have different ramp base sizes (13.33 vs 14.67
  px body), and every derived number differs with them.
- The resolved FAMILY is stable across both legs in all three cases
  (default `DejaVu Sans`, branded `DejaVu Serif`, nonsense
  `DejaVu Sans`), so a family-only observation is byte-comparable across
  legs — which invariant 6 requires of the shared `.steps` file.
- Cross-leg pixel comparison is off the table anyway: the two baselines
  differ by 13767 pixels.

---

## §5 — the recipe for the GTK arm, in one block

```rust
// activate(), beside brand_css:
//   let typeface_css = gtk4::CssProvider::new();
//   watch_css_errors(&typeface_css, &css_error);
//   style_context_add_provider_for_display(
//       &display, &typeface_css, STYLE_PROVIDER_PRIORITY_APPLICATION);
// Empty until a typeface arrives; an app that requests none contributes
// no rule at all. Its OWN provider — never brand_css, whose content is
// replaced wholesale on every appearance flip.

fn typeface_css_for(family: &str) -> String {
    // `:root`, never `*`: `*` also matches `.monospace` and would swap
    // the editor's face. font-family inherits, so :root reaches every
    // widget the theme does not deliberately claim.
    format!(":root {{\n  font-family: \"{family}\";\n}}\n")
}

// ApplyOp::SetTypeface { family } =>
//   load_kaya_css(&core.typeface_css, "brand typeface",
//                 &typeface_css_for(family), &core.css_error);

// The observation (expect_typeface): resolved family, never the request.
fn resolved_family(w: &impl IsA<gtk4::Widget>) -> Option<String> {
    let ctx  = w.as_ref().pango_context();
    let req  = ctx.font_description()?;
    let font = ctx.load_font(&req)?;
    font.describe().family().map(|g| g.to_string())
}
```

Notes carried into the arm:
- The family name needs escaping/validation before it lands in CSS —
  a family containing `"` or `}` would rewrite the stylesheet. The
  provider's `parsing-error` catches malformed CSS (`watch_css_errors`
  already wired), but a family that is merely *absent* is valid CSS and
  produces no error at all, which is the whole point of §3.
- No adwaita feature bump is needed. `:root` needs GTK ≥ 4.16 at
  runtime; the shipped brand lowering already depends on it, so the
  floor does not move.
- Nothing here is display-backend specific: identical results on x11
  and wayland.

## §6 — open items for the coordinator

1. tools/linux/Dockerfile installs no font package by name. The scene's
   expected strings would rest on a transitive dependency. Recommend
   naming `fonts-dejavu-core` explicitly (and, optionally,
   `fonts-cantarell` so the Wayland leg's own default stops being a
   silent substitution).
2. Slice 2's other half already has a Dockerfile prerequisite recorded
   in the plan (`librsvg2-common`, styling-plan.md §D6) — that package
   IS present in the current image (`librsvg2-common`, line 34), so
   that note is stale.

---

## Artifacts (all under this directory; 272K total, nothing outside)

```
probe_typeface.py     6 passes: :root vs *, good/nonsense, settings route   -> out-x11.json
probe_round2.py       fallback keying, settings-family splice, natural width -> round2.json
probe_round3.py       add-once provider pattern, --monospace-font-family     -> round3.json
probe_pixels.py       resolved read + realized-render PNG, x11 and wayland   -> shots/*.png
probe_min.py          read-route isolation
probe_min2.py         read-route isolation
probe_run_font.py     the R4 (shaped-run) route
summarize.py          renders the JSON as the tables above
shots/                6 PNGs, 100K
```

Cleanup: every container ran `--rm`; `docker ps -a` is empty; no host
process left (`ps` shows only the grep itself); the `kaya-linux` image
was never rebuilt and is unchanged at 8.31 GB. No repo file was created,
edited or deleted by this probe. (`git status` does show
docs/deferred.md and docs/styling-plan.md modified — those are somebody
else's edits in this workflow, present before this probe wrote anything
and untouched by it.)
