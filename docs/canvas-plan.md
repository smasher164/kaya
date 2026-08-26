# Canvas: a core-rasterized drawing surface on the widget vocabulary

RATIFIED 2026-08-26 (the maintainer, after two research rounds: the
decision menu this file used to end with, and the prior-art sweep that
answered it — plus a same-day dependency check that corrected §4.1).
Base c98e4c6. Nothing is built yet — no protocol byte has moved and the
spec hash has not been touched — but nothing below is a proposal
either. Every row of §0's table is his ruling or a recommendation he
adopted, and the rest of this file is written against them rather than
around them.

ONE ROW IS FLAGGED AS AN ADOPTED RECOMMENDATION RATHER THAN A RULING:
row 11, §6's two-mode chart palette. He ruled the architecture (rows
1-4) and every menu answer (rows 5-10); the palette sub-choice is the
researched recommendation he took, and it is written where he can veto
it without disturbing anything else.

Canvas is the last of the three features the portfolio dashboard exists
to force (docs/portfolio-plan.md §0, ratified 2026-08-21, order ruled
2026-08-22: TABLES -> VIRTUALIZATION -> CANVAS). Both predecessors are
done, and docs/portfolio-plan.md §4 records the hole this fills: "**No
chart.** The portfolio total is a label; the canvas slice will replace
the space above it with a value-over-time chart. The 'Day tick' button
exists partly to accumulate the series a chart will want."

## §0 — The ruling record

The draft this replaces ended in a six-question decision menu. The menu
is gone; these are its answers, plus the four architecture rulings that
came out of the second research round and reshaped everything above it.

| # | ruling | status |
| --- | --- | --- |
| 1 | **The core rasterizes; backends blit.** kaya draws its own command list into a pixel buffer and hands the buffer to the backend, which puts it on screen through the image machinery it already has. Lowering the op list into four native drawing APIs is DEAD. | RULED 2026-08-26 |
| 2 | **The rasterizer is a pinned implementation detail behind the wire.** tiny-skia today; `vello_cpu` is explicitly revisitable when it stabilizes, as a one-crate swap with zero binding churn. GPU rendering for this buffer is refused ON PRINCIPLE. | RULED 2026-08-26 |
| 3 | **Text is in v1.** No v1/v2 split (the no-staged-work rule): charts need tick labels from the first one, and labels-as-widgets-at-tick-positions is awkward. ONE shaping engine in the core — harfrust shapes, skrifa/read-fonts outline, tiny-skia fills the paths (§4.1). | RULED 2026-08-26; stack named and then corrected against the archived-crate wave the same day |
| 4 | **Fonts are assets, through the one resolver.** A text op names a font asset; unspecified means the reserved name `kaya/default-font`, which the resolver answers from bytes EMBEDDED in libkaya (the vendored Sora). The `kaya/` prefix is refused in app packages. | RULED 2026-08-26 |
| 5 | **The ops travel as ordinary tagged values** — the `set_column_headers` record shape — so the generator does the eight-language work. Packed bytes stay a measured-need escalation. | RULED 2026-08-26 (menu Q2) |
| 6 | **The scene's primary observable is a byte-hash of the raster** at the canonical scale with the canonical palette, identical on every platform. Ink bounds as fractions and sampled solid fills stay as the human-legible secondary checks; looks stay the captures' business. | RULED 2026-08-26 (menu Q3, rebuilt) |
| 7 | **Backends report the window's scale; the core re-rasters.** That is the platforms' own rescale-then-re-render mechanism, not an invention. | RULED 2026-08-26 |
| 8 | **The op vocabulary is five geometry ops plus text** (menu Q4, amended by ruling 3). Curves, dashes, joins, blends, gradients and antialiasing control stay out, one artifact at a time. | RULED 2026-08-26 |
| 9 | **No Win2D, and no new Windows dependency at all** (menu Q5 DELETED — under the buffer there is nothing for it to do). The pinning-gate work that question uncovered stays landed (c98e4c6). | RULED 2026-08-26 |
| 10 | **A drawing is not undoable** (menu Q6), on `set_column_headers`' reasoning: a drawing renders app state, it is not state. | RULED 2026-08-26 |
| 11 | kaya owns a two-mode (light/dark) chart palette resolved in the core: semantic paint roles, uniform across platforms per mode, only the mode bit crosses. | ADOPTED RECOMMENDATION 2026-08-26 — §6 |

**What the 2026-07-22 ruling keeps and what it loses.** docs/deferred.md's
Canvas entry (Akhil, 2026-07-22) said: display list rather than
callback-per-frame; core retains it as a prop; deliberately minimal op
set; pointer events deferred inside the deferral. All four survive
verbatim. The half that is superseded is the clause after the semicolon
— "backends replay it into the native surface (SwiftUI Canvas, Compose
DrawScope, GTK4 DrawingArea/cairo; WinUI needs Win2D CanvasControl)" —
because the research round that priced Win2D also priced the whole
lowering idea, and it did not survive the pricing.

**And the Vello thread is re-filed, not closed.** DESIGN.md's "Custom
drawing" decision ("Display lists are v2 and adopt Vello's scene
encoding rather than inventing a format") and open question #3 were
written about the COMPOSITOR case: an app that renders its own frames on
its own schedule and hands kaya finished pixels through a platform
surface handle. That is a different feature from this widget, and it
keeps its open question, unchanged, against the pixel-handoff arm where
it belongs. What is settled is that the canvas widget does not use
Vello's encoding as a wire format, and §12 records why it could not have.

## §1 — The architecture: kaya rasterizes, backends blit

### §1.1 The one rule

A canvas widget's content is a PIXEL BUFFER the core produced. The guest
declares an op list; the core validates it, rasterizes it at the
window's scale in the window's appearance mode, and the backend puts
those pixels on screen. No backend interprets an op. No backend owns a
drawing API. The four backend arms are four spellings of "show me these
bytes at this size", which each of them already has for the Image
widget.

Three consequences fall straight out, and they are the reason for the
ruling:

- **One rasterizer means one bug.** A defect in a stroke is one fix in
  one crate, not four reconciliations. This is exactly what React Native
  Skia's team reported buying, and their proof obligation was a
  cross-platform screenshot suite comparing all three targets — a test
  architecture the lowering design cannot write at all.
- **The core can be believed about what it drew.** Validation, ink
  bounds, and the byte-hash of §7 are all reads of an artifact kaya
  produced, on the machine the lane is running. Under lowering, every
  one of those is a question four platforms answer differently.
- **Text becomes possible** (§4). It is not possible under lowering at
  the fidelity a byte-shared scene needs, and text is what a chart needs
  first.

### §1.2 Why the lowering design is dead

Two pieces of evidence decided it, and one framework's history is worth
more than any argument in this file.

**Qt migrated in this direction, and says what it bought.** Qt 4
defaulted to a different native paint engine per platform — "Windows -
Software Rasterizer, X11 - X11, Mac OS X - CoreGraphics". Qt 6's default
on every desktop is its OWN raster engine: "The primary paint engine
provided is the raster paint engine, which contains a software
rasterizer which supports the full feature set on all supported
platforms". `CoreGraphics`, `Direct2D` and `X11` still exist in
`QPaintEngine::Type` and are the default nowhere. The stated payoff is
the sentence this milestone is built on: "One advantage of using QImage
as a paint device is that it is possible to guarantee the pixel
exactness of any drawing operation in a platform-independent way."

Qt also separates the two things this ruling could be confused with:
**it core-owns the RASTERIZER while delegating APPEARANCE to QStyle**,
whose widgets "look exactly like the equivalent native widgets". A
core-owned rasterizer for one widget's content does not make kaya a
custom-drawn toolkit, and invariant 1's "wrap native widgets" bet is
untouched — this is one kind out of fifteen, and it is the kind whose
whole point is that the app draws it.

**.NET MAUI is the lowering design, shipped, and its issue record is the
cautionary tale.** `Microsoft.Maui.Graphics` is one `ICanvas` lowered to
CoreGraphics on Apple, `Android.Graphics` on Android and Win2D on
Windows — the exact shape the draft proposed. What that bought:

- The docs concede non-uniformity in their own text: on
  `SaveState`/`RestoreState`/`ResetState`, "**Note** The state that's
  persisted by these methods is platform dependent."
- One `IImage.Resize`/`Downsize` call with three behaviours — Android
  returns a disposed image, iOS keeps aspect ratio "with a rounding
  issue", Windows "Throws NotImplementedException" (#21886, open since
  2024).
- `StrokeDashArray` "5,2" renders dashed on Android and Windows, solid
  on iOS and macOS (#29661).
- Text is the worst class, refiled for four years: `DrawString`
  invisible on Mac Catalyst plus mismatched alignment on Android and
  Windows (#4993 -> #8486 -> #30673); `GetStringSize` returning a box
  too small to contain its string on iOS (#18679).
- A registered custom font is honoured by native controls and ignored by
  the canvas (#9252).
- The repository was archived on 2023-12-21.

Every one of those is a divergence kaya would have to discover on five
lanes and then reconcile per backend, and each reconciliation weakens
the byte-shared scene that invariant 6 requires.

**Two smaller facts that make the ruling cheaper than it sounds.** GTK4
already turns cairo drawing into a bitmap: `GtkDrawingArea`'s snapshot
calls `gtk_snapshot_append_cairo`, which "Creates a new GskCairoNode and
appends it to the current render node", and render nodes are immutable.
So one of the four backends was going to be a bitmap in a retained tree
whichever design won. And on Wayland the core-owned buffer IS the
operating system's model: "The client links to a rendering library ...
and renders directly into the buffer. The client only needs to tell the
compositor which buffer to use and when and where it has rendered new
content into it."

### §1.3 What the buffer costs, on the record

The research ranked the evidence against this architecture, and none of
it is dismissed here. Each item below is either mitigated by a design
rule or carried into §11's measure-at-implementation list.

| cost | the finding | what this plan does |
| --- | --- | --- |
| the blit is bandwidth | Chromium: "Texture uploads of bitmaps are a non-trivial bottleneck on memory-bandwidth-constrained platforms. This has handicapped the performance of software-rasterized layers" — and Chromium moved away from software raster | a chart re-rasters on data change, scale change and appearance change, not per frame. Measured in phase 4 at the portfolio's real canvas size |
| memory | Microsoft's own retained-versus-immediate comparison: retained "can have higher memory requirements" | one buffer per canvas widget, at one scale, freed with the widget |
| the monitor-move transition | endemic to every core-buffer framework: Avalonia #17834/#13917, Compose Multiplatform #1223/#3685/#4019, Flutter #77605 — "the new scale did not propagate before the next frame" | §5. A core buffer makes this MORE visible (a stale-size blit) and easier to fix (one place re-rasters) |
| text is the byte-identity leak | Flutter owns its engine end to end and still keeps per-platform golden masters, because "Custom fonts may render differently across different platforms"; its own tests dodge it with the Ahem box font. RN Skia learned "how each platform displays fonts slightly differently". Playwright: "Screenshots differ between browsers and platforms due to different rendering, fonts and more" | §4: kaya's bytes through kaya's one engine. Byte-identity is reachable only if the rasterizer is CPU-only AND the font stack ships with kaya, so both are ruled |
| a CPU rasterizer's feature bill | tiny-skia lists text rendering as "the main missing feature", "Out of scope". Slint's software renderer publishes "No support for rotations or scaling", "No text stroking/outlining", "Text rendering currently limited to western scripts" | tiny-skia rasterizes PATHS; §4's shaper turns text into paths before it gets there, which is the division resvg has shipped for years |
| binary size and native fidelity | Flutter's engine floor is ~4 MB compressed on Android, ~10.9 MB per iOS IPA; its non-native text rendering is a live complaint | kaya ships a path rasterizer and one 108 KB font, not an engine and a widget set. Every other kind stays native |

### §1.4 The rasterizer is an implementation detail, and it is pinned

**tiny-skia today.** It is "an absolute minimal, CPU only, 2D rendering
library for the Rust ecosystem" whose own claim is the one this design
needs: "Unless there is a bug, tiny-skia must produce exactly the same
results as Skia." It is a port of Skia's raster pipeline rather than a
new rasterizer, it is proven at scale as resvg's backend, and it is CPU
only, which is the property that makes byte-identity possible at all.
AND IT IS MAINTAINED, which is not a given for a crate of its lineage:
it transferred to the Linebender org (linebender/tiny-skia) and is
active, while its original author's other crates went the other way
(§4.1's near-miss). Do not read the two histories as one.

**`vello_cpu` is named here so nobody has to rediscover it.** It is the
Linebender stack's own CPU rasterizer and the natural successor; it is
not stable enough to pin today. Because the wire carries kaya's op
vocabulary and nothing about the rasterizer reaches a binding, swapping
it is a one-crate change in the core with zero binding churn and one
observable consequence: the §7 hashes move, which is a scene edit and a
capture round, not a protocol change. Revisit when it stabilizes.

**GPU rendering for this buffer is refused ON PRINCIPLE, not deferred.**
Two independent reasons, either sufficient:

1. Driver-dependent antialiasing destroys the cross-platform
   byte-identity the whole harness story rests on. Skia's own developers
   describe GPU antialiasing as MSAA-or-analytic chosen per surface and
   per primitive, with path renderers gated on GPU features ("ES 3.0 is
   the minimum", "half-float alpha as a color-renderable format"). A
   buffer whose pixels depend on the GPU is a buffer no scene can freeze.
2. The linux lane has no GPU. It is a docker container
   (tools/linux/Dockerfile), and a rendering path that cannot run there
   cannot be one of five lanes' rendering path.

This refusal is about THIS buffer. The compositor case — an app handing
kaya finished GPU frames through a surface handle — is the separate
feature DESIGN.md already decided, and nothing here constrains it.

**Vello's scene encoding as a wire format stays dead**, on the research
from the first round (2026-08-26, §13 carries the URLs): Vello's own
README says "Vello can currently be considered in an alpha state"; the
only statement about freezing the encoding is a 2023 roadmap saying
"it's also too early to freeze the format"; `Encoding` is not a byte
layout at all but a struct of twelve parallel `Vec`s with no `repr(C)`
and no `serde` feature; it takes breaking changes at minor versions
(0.9.0 added two fields to `GlyphRun`); and the one serious FFI binding,
VelloSharp, wrapped scene-BUILDING calls instead and was archived
2026-01-31 "waiting for final Vello api". There was never a format
available to adopt.

## §2 — The guest surface

### §2.1 The shape: a recording scope that declares one record

A canvas is a widget. The drawing is a separate declaration against that
widget, exactly as a table's header bar is a declaration against a For's
container. The guest writes what reads as immediate-mode drawing; what
actually happens is that the calls are recorded and one record is
submitted when the scope closes.

That fiction is already the house move, ratified in DESIGN.md's binding
conventions for the For template trace: "The body runs ONCE to trace the
template in every spelling; the loop is the fiction that reads as the
intent." Canvas reuses it wholesale, with a drawing scope instead of a
loop.

The declaration is atomic and total: it replaces the whole drawing,
never patches it. This is `set_column_headers`' rule and its reasoning
transfers verbatim — one record for the whole thing "because the
header's state is one declaration ... and buys atomicity — no window
where new titles show a stale indicator." A half-updated chart is the
same defect.

**There is no handler.** Pointer events on the canvas stay deferred
inside the 2026-07-22 deferral, so v1 has no occurrence, no callback,
and none of the registry-versus-declaration split every other
interactive surface needs. The eight-language cost is a constructor and
a drawing scope, and nothing else.

### §2.2 The spellings

Each is the language's own idiom for a scope, taken from the guest that
already exists beside it. `viewbox` is §3.2's coordinate declaration.

**Python** (ambient transaction; `with` scopes, keyword arguments) —
guests/python/portfolio.py is the app this lands in:

```python
chart = kaya.canvas(viewbox=(300, 120), grow=1, a11y_label="Portfolio value")

def redraw():
    with chart.draw() as d:
        for i in range(1, 4):
            d.move_to(0, i * 30).line_to(300, i * 30)
        d.stroke("grid", width=1)
        d.move_to(*points[0])
        for x, y in points[1:]:
            d.line_to(x, y)
        d.stroke("series", width=2)
        d.font(size=11)
        for y, text in ticks:
            d.text(-6, y, text, paint="axis", align="end", baseline="middle")
```

**Rust** (handle binding; closures, `Messages` registry) —
`tx.canvas(...)` returns a `Widget` whose `.id()` is the handle, and the
drawing scope takes `&mut Draw` the way `tx.row` takes `&mut Tx`:

```rust
let chart = tx.canvas(Viewbox(300.0, 120.0)).id();
tx.grow(chart, 1.0);
tx.draw(chart, |d| {
    d.move_to(0.0, 30.0).line_to(300.0, 30.0);
    d.stroke(Paint::Grid, 1.0);
    d.polyline(&points);
    d.stroke(Paint::Series, 2.0);
    d.font(11.0);
    d.text(-6.0, 30.0, "$40k", Paint::Axis, Align::End, Baseline::Middle);
});
```

**Go** (closure at the declaration, as `tx.Button("quarter", func(tx *kaya.Tx))`
already is):

```go
chart := tx.Canvas(kaya.Viewbox{W: 300, H: 120})
tx.Draw(chart, func(d *kaya.Draw) {
    d.MoveTo(0, 30).LineTo(300, 30)
    d.Stroke(kaya.PaintGrid, 1)
    d.Font(11)
    d.Text(-6, 30, "$40k", kaya.PaintAxis, kaya.AlignEnd, kaya.BaselineMiddle)
})
```

**C#** (lambda, named arguments, as `tx.Button("quarter", onClick: ...)`):
`tx.Draw(chart, d => { d.MoveTo(0, 30).LineTo(300, 30); d.Stroke(Paint.Grid, width: 1); });`

**Java** (lambda over a one-shot scope, as `tx.column(() -> ...)`):
`tx.draw(chart, d -> { d.moveTo(0, 30).lineTo(300, 30); d.stroke(Paint.GRID, 1); });`

**Swift** (trailing closure, beside `tx.row { ... }`):
`tx.draw(chart) { d in d.moveTo(0, 30).lineTo(300, 30); d.stroke(.grid, width: 1) }`

**OCaml** (labelled arguments and combinators, as
`image ~source:test_png` and `button ~text:"quarter" ~on_click:...`):
`canvas ~viewbox:(300., 120.) ~draw:(fun d -> move_to d 0. 30.; line_to d 300. 30.; stroke d ~paint:Grid ~width:1.)`

**Haskell** (combinator over a list, as `row [imageBytes testPng, ...]`):
`canvas (Viewbox 300 120) [moveTo 0 30, lineTo 300 30, stroke Grid 1]` —
Haskell is the one binding where the op list is literally a list, which
is what the wire carries anyway.

**The C floor** stays fully explicit, as its documentation role requires
(invariant 5). No scope, no builder: guest-allocated ids, one generated
setter, and the op stream written out as the array it is, the same way
guests/c/gallery.c writes `kaya_tx_set_source` against a registered
handle:

```c
#define W_CHART 7
KayaVal ops[] = {
    kaya_i64(KAYA_DRAW_MOVE_TO), kaya_f64(0),   kaya_f64(30),
    kaya_i64(KAYA_DRAW_LINE_TO), kaya_f64(300), kaya_f64(30),
    kaya_i64(KAYA_DRAW_STROKE),  kaya_i64(KAYA_PAINT_GRID), kaya_f64(1),
};
kaya_tx_create_widget(&tx, W_CHART, KAYA_KIND_CANVAS);
kaya_tx_set_drawing(&tx, W_CHART, 300.0, 120.0,
                    sizeof ops / sizeof *ops, 0, ops,
                    sizeof ops / sizeof *ops);
```

### §2.3 The sweep (invariant 2)

| language | verdict | note |
| --- | --- | --- |
| Rust | DO | closure scope, `Paint`/`Align`/`Baseline` enums |
| Python | DO | `with` scope, role and alignment names as strings validated at record time |
| Go | DO | closure scope, `PaintX` constants |
| C# | DO | lambda, enums, named `width:` |
| Java | DO | lambda, enums |
| Swift | DO | trailing closure, `.grid` shorthand |
| OCaml | DO | labelled `~draw`, constructors |
| Haskell | DO | op list, constructors |
| C floor | DO | explicit array, generated setter, no scope |

No language cannot express this, so there is no carve-out to state. The
drawing scope is a value-recorder in every one of them, and every one
already has the scope construct it needs. Both construction zones are
owed a constructor: check-sugar-surface counts the LIVE zone and the
TEMPLATE zone separately, so a canvas per row (a sparkline in a table
cell) is 16 constructors, not 8.

## §3 — The wire

### §3.1 The record

One new transaction record, on `set_column_headers`' pattern, which
spec.rs already blesses for exactly this problem: "A dedicated record
and not a prop because a prop carries ONE Value and titles are many ...
the carrier is highlight_ranges' count-plus-Values shape."

```
set_drawing:
    widget_id  U64      the canvas (live id, template node id, or either
                        with a key path — see below)
    vb_w       Value    f64, finite, > 0
    vb_h       Value    f64, finite, > 0
    len        U32      how many values the op stream occupies
    path_len   U32      how many key values precede it
    ops        Values   path_len keys FIRST, then len op values
```

The `path_len`-keys-first convention is copied from `set_column_headers`
verbatim, and it is not decoration: it is what lets a canvas live inside
a For row template. `path_len 0` with a live widget id is the flat case;
`path_len 0` with a template node id declares the drawing for every
stamped copy; `path_len > 0` re-declares one copy's. A sparkline per row
is that third form.

The op stream is a flat run of tagged values: an `i64` opcode followed
by its operands. Nothing here is a new field type, which is spec.rs's
own standing instruction: "New vocabulary should be new RECORDS over the
existing types, not new types — that is what keeps eight bindings
mechanical." (Menu Q2, ruled: the alternative was a packed byte buffer
through the blob channel. It is smaller on the wire — each value costs
16 bytes, so a 60-point series is about 3 KB — and it costs a
hand-written binary layout in eight bindings plus a decoder in the core
plus two interpreter copies, which is precisely the hand-copied-numbers
trap check-file-modes and check-symbol-parity exist to police. Packed
bytes are the named escalation, admitted on an artifact where the
encoding cost is MEASURED: a hundred-thousand-point scientific plot,
not a chart.)

### §3.2 Coordinates: the viewbox

**This is the decision that makes a byte-shared canvas scene possible at
all, and it survives the architecture change unchanged.**

A canvas that draws in the device pixels of its assigned track produces
a different op stream on every platform, because every platform gives it
a different track. Invariant 6 would then have nothing to freeze: the
scene could not name a single coordinate.

So the guest declares a **viewbox** and draws in it. The core rasterizes
at box-times-scale onto whatever track layout assigns. The op stream is
therefore identical on every platform and in every language by
construction, and the scene can freeze it.

Three rules make the mapping well defined:

1. **The viewbox is also the natural size**, in device-independent
   points. `viewbox=(300, 120)` means a canvas that asks for 300x120 and
   scales when layout gives it more. This is SVG's rule, and it answers
   a real gap: there is no width or height property on any widget in
   kaya today (the PROPS table's entries have no size among them;
   `width`/`height` are window properties). A canvas is the first widget
   whose content size is app-decided, and the viewbox supplies it
   without inventing a size property that fourteen other kinds would
   then have to answer for.
2. **Stretch to fill, not fit with letterboxing.** Evenly spaced things
   stay evenly spaced.
3. **Positions scale; stroke widths and text sizes do not.** A width and
   a font size are in device-independent points and are applied after
   the transform, so a 1pt gridline is 1pt at every size, an 11pt label
   is 11pt at every size, and a non-uniform stretch never produces an
   elliptical pen or a squashed glyph.

A pleasant consequence: the canvas never needs to know its own size, so
it needs no resize occurrence, which is why deferring pointer and
geometry events costs nothing here.

### §3.3 The op vocabulary (v1)

Five geometry ops and two text ops.

| op | operands | meaning |
| --- | --- | --- |
| `move_to` | `f64 x, f64 y` | start a subpath |
| `line_to` | `f64 x, f64 y` | extend it |
| `close` | none | close the current subpath |
| `stroke` | `i64 paint, f64 width` | stroke the built path, then clear it |
| `fill` | `i64 paint, i64 rule` | fill it (nonzero or even-odd), then clear it |
| `font` | `str asset, f64 size, i64 weight` | select the face for subsequent text ops; `""` means `kaya/default-font` |
| `text` | `f64 x, f64 y, i64 paint, i64 align, i64 baseline, str s` | draw ONE LINE with its anchor at (x, y) |

Path-then-paint is the shape a path rasterizer natively has. The
anchoring vocabulary is SVG's (`align` = start/middle/end is
`text-anchor`; `baseline` = alphabetic/middle/top/bottom is
`dominant-baseline`), because it is the established one and because
under the buffer kaya DEFINES it rather than reconciling four engines
that disagree — the divergence the draft cited as text's blocker
(Compose positions a string by top-left, cairo by baseline) is a
divergence between platform APIs kaya no longer calls.

**What text does NOT carry in v1, and each is a refusal rather than an
omission:** no wrapping and no multi-line (a newline in a text string is
refused by the core — a chart label is one line, and line breaking is a
layout engine); no per-glyph positioning; no letter-spacing; no text on
a path; no stroked or outlined text (tiny-skia's sibling limitation in
Slint's bill, and nothing needs it). Bidi and complex-script shaping are
the shaper's job, not the op's — see §4.1.

**The geometry exclusions are each a measured divergence** rather than a
scope preference, and they still hold under the buffer for a different
reason: the core would now have to CHOOSE a behaviour, and the choice
should be bought with an artifact.

| excluded | why it stays out |
| --- | --- |
| curves | the chart is a polyline. If they arrive they must be **cubic** — quadratics elevate to cubics exactly, so the wire should never carry both |
| dashes | dash phase is measured in four different units across the platform APIs, so there is no obvious semantics to inherit; kaya would be inventing one |
| join and cap control | same shape: the miter limit is the SVG ratio in three platform APIs and half the stroke thickness in a fourth |
| blend modes | a per-primitive blend vocabulary is a large surface with no artifact asking for it |
| gradients | interpolation colour space is a real decision. If gradients arrive they must be pre-sampled into many stops in ONE nominated space |
| antialiasing control | the buffer is antialiased, always, by one rasterizer. A switch would be a second raster path to keep byte-identical |
| images inside a drawing | the Image widget exists; a canvas that composites blobs is a second asset story |

### §3.4 Paint is a closed vocabulary, not a colour word

Ops name a **paint role**, not RGB. The roles resolve in the core, per
appearance mode (§6).

The tree already made this argument, for icons, in DESIGN.md: "Icons
want names, not bytes. The current `icon` prop is a Blob, and a blob is
the wrong primitive for a STANDARD icon ... The admission is a small
closed set of semantic names mapped per backend — the `role` trick
again."

Three reasons it is the right answer here too, each already paid for in
this tree:

- **Dark mode.** A literal RGB series line is invisible in one
  appearance. This milestone's own base commit records the class: the
  dark-mode capture "caught an apron resolving its color outside the
  window it lived in". A drawing would be the largest such surface kaya
  has.
- **check-table-card already forbids literals** for the table card,
  demanding "its colours are the platform's own tokens rather than
  literals". A canvas drawing raw RGB would be that rule's biggest
  exception, admitted the same week it was written.
- **The core already derives palettes.** crates/kaya/src/brand.rs turns
  one seed into per-appearance fill / on_fill / standalone / hover /
  pressed as packed sRGB words, "computed here once so no backend
  re-derives". A canvas role is a lookup into work that is already done,
  in the place that already does it.

v1 roles, and they are chart roles because the artifact is a chart:
`series` (the line), `series_fill` (the area under it), `grid`
(gridlines), `axis` (axis lines and tick labels), and `ground` (the plot
background). Literal RGB is the named escalation, admission gated on an
artifact, exactly as the blob follow-ups in docs/deferred.md are.

### §3.5 The core validates, and refuses before rasterizing

`highlight_ranges`' discipline transfers directly, and under the buffer
it is stronger: the refusal happens in the only place that draws, so
there is no way for a backend to answer differently.

The refusals: an unknown opcode; an opcode whose operands run off the
end of the stream; a non-finite coordinate; a paint role outside the
vocabulary; a non-positive or non-finite stroke width; a paint op with
no path built; a viewbox dimension that is not finite and positive; a
keyed target naming no stamped copy; a non-finite or non-positive font
size; an align or baseline outside the enum; a newline inside a text
string; and a font asset the resolver cannot answer for, which raises
the resolver's OWN sentence (§4.2) rather than a second vocabulary for
the same failure.

### §3.6 What it costs

| surface | cost |
| --- | --- |
| spec hash | moves once: the `canvas` kind (the fifteenth), the `set_drawing` record, the `draw_op`, `paint`, `fill_rule`, `align` and `baseline` enums |
| generators | `set_drawing` reaches all 8 bindings mechanically; the drawing SCOPE is hand-written sugar over it, 8 times, in both construction zones |
| core | a new raster module: op fold, path building, the shaper call, the palette resolve, the buffer cache, the invalidation rule |
| interpreters | both private constant copies grow: the opcode numbers, the paint numbers, the alignment numbers, the kind. This is check-symbol-parity's exact trap shape, one surface over — and it is SMALLER than under lowering, because neither interpreter implements a drawing API |
| backends | one blit arm each, plus one read-back for the harness (§7) |
| check-verbs | red until both interpreters carry every new verb |
| check-sugar-surface | red until `canvas` exists in all 8 bindings in BOTH zones; tools/tpl-surfaces.py reads its kind list from the generated wire file, so this goes red the moment the spec moves |
| check-universal-props | red until all four backends apply a11y_id/a11y_label to the new kind |
| check-symbol-parity | wants a sibling clause: the opcode, paint and alignment numbers are copied by hand into Swift, Compose and the C floor, which is precisely the population that gate exists to hold |
| check-assets | one note only: the reserved `kaya/` namespace (§4.2). No new resolver, no new root, no new staging |

## §4 — Text, fonts, and why text requires the buffer

### §4.1 One shaping engine, in the core

**The determinism argument, stated once.** Fonts diverge across
platforms twice over: by NAME RESOLUTION (the same family string
resolves to different files, or to a fallback, on five platforms) and by
TEXT ENGINE (Core Text, HarfBuzz through Skia, HarfBuzz through Pango
and DirectWrite produce different advance widths, hinting and
antialiasing for the same string and the same file). Flutter owns its
whole engine and STILL keeps per-platform golden masters because of
this; RN Skia's cross-platform suite discovered it; Playwright states it
as a fact of life.

So byte-identity requires kaya's bytes through kaya's one engine. Text
is not merely enabled by the core-owned buffer — **text is the feature
that requires it.** That is also why ruling 3 could be made at all: the
draft argued text out of v1 on divergence grounds that the architecture
ruling had already dissolved.

**The stack, named precisely** (refined 2026-08-26, the maintainer's
follow-up: name it rather than gesture at a class; then corrected the
same day against the crate landscape — see the near-miss below). The
DIVISION is the one resvg proved and has shipped for years — shape,
outline, fill as paths — and these are the maintained crates that
implement it in 2026:

1. **harfrust** shapes the run. It is the HarfBuzz project's own Rust
   port (harfbuzz/harfrust), tracking HarfBuzz 13 and actively released
   as of 2026-08-24, so the shaping is the industry's rather than a
   home-grown approximation.
2. **read-fonts + skrifa** (googlefonts/fontations) parse the font and
   produce each glyph's OUTLINE. This is Chrome-production code —
   FreeType is out of Blink as of Chrome 145 — which is about as much
   exposure as a font parser can have.
3. **tiny-skia** fills those outlines as ordinary paths.

**One coherence point worth the sentence**: harfrust deliberately runs
on read-fonts, by its own README's rationale, so the shaper and skrifa
share ONE font-parsing implementation. A canvas therefore has exactly
one thing reading a font file, which is the same property §4.2 buys for
the BYTES and §7.1 needs for the hash. The other half of the same
coherence: tiny-skia now lives under the Linebender org
(linebender/tiny-skia) and is active, and so does `vello_cpu`, so both
the rasterizer and its named successor come from one project.

There is no separate glyph rasterizer and no glyph cache to keep
byte-identical: **text reduces to the path ops the canvas already
rasterizes.** tiny-skia's own "text is out of scope" is not a gap here,
it is the correct division. The versions pin in phase 1, in Cargo.lock,
with the usual `--locked` discipline.

**THE NEAR-MISS, recorded because the guard is the record.** The first
version of this section, written the same afternoon, named rustybuzz
and ttf-parser — the crates resvg actually uses. Both are abandoned:
rustybuzz was ARCHIVED on 2026-08-06 with an unmaintained advisory
(RUSTSEC-2026-0206), and ttf-parser is the same author's family, gone
with it. The plan almost shipped naming an archived shaper as a v1
dependency, and it was caught by asking rather than by remembering. So:
THE CRATE LANDSCAPE WAS VERIFIED ON 2026-08-26 AGAINST THE ARCHIVED-
CRATE WAVE, and the rule this leaves behind is that a dependency is
never cited from memory — the archive dates and the advisory are facts
about this year, not about the ecosystem's shape, and phase 1 re-checks
them at pin time.

**cosmic-text is explicitly NOT in v1**, and is recorded here as the
designated candidate for the day wrapped, paragraph or bidi-LAYOUT text
arrives — the same revisit-boundary shape as the `vello_cpu` note in
§1.4. It is a LAYOUT engine (line breaking, paragraph direction,
fallback across faces), and a chart label is a single-line run, so
taking it now would buy a large surface for a feature v1 refuses (§3.3).
The boundary that would move the decision is a text op that needs a
BOX rather than an anchor point.

**The hinting caveat, recorded honestly because it is visible.**
Glyphs-as-paths means UNHINTED outlines antialiased by tiny-skia. That
is macOS-style rendering: correct at 2x and at chart label sizes, and
deliberately NOT matching Windows ClearType, which hints and
subpixel-positions to a pixel grid. This is a chosen trade, not an
oversight — hinting is per-platform flavour, and byte-identity is the
whole point of §7.1. A canvas label on Windows will therefore look
slightly softer than the WinUI label beside it, and that is the expected
appearance rather than a defect to chase. It is on the phase-4 capture
list (§11) so a human sees it once, at real sizes, on the lane where it
shows most.

One mechanical finding worth carrying from egui, because it decides an
invalidation rule: geometry survives a scale change but "Shape::Text
depends on the current pixels_per_point (dpi scale) and so must be
recreated every time pixels_per_point changes". Under this design the
whole buffer re-rasters on a scale change anyway (§5), so the rule is
already satisfied — but a future optimization that caches part of the
raster must not cache shaped text across scales.

### §4.2 Fonts are assets, through the one resolver

A text op names a FONT ASSET. The name is an ordinary asset name — a
relative path under the asset root spelled with `/`, walled by
crates/kaya/src/assets.rs's existing rules — so an app's own typeface is
`fonts/whatever.ttf` and reaches every lane through machinery that
already stages the root as a unit and verifies it by hash
(docs/assets-plan.md, tools/check-assets.sh).

**Unspecified means `kaya/default-font`.** That reserved name is
answered by the resolver from bytes EMBEDDED in libkaya —
`include_bytes!` of the vendored guests/assets/fonts/sora-wght.ttf,
"embed and load it" (the maintainer's words). Four consequences, each of
which removes a failure mode rather than adding one:

- **A canvas can always draw text**, on a lane whose asset root is
  missing, on a platform whose staging failed, in an app that ships no
  assets at all. The default font is not a file to find.
- **The bytes are identical on five platforms by construction**, which
  is half of what §7's byte-hash needs. The other half is the shaper,
  which is also kaya's.
- **Staleness is already guarded.** Embedded bytes are compiled into
  libkaya, so they ride tools/build-id.sh's artifact id and
  tools/check-build-id.sh's verification. A font swap that did not
  rebuild is a build-id refusal, which is the wall on the path nobody
  can avoid (invariant 3).
- **check-assets' ONE RESOLVER clause is untouched.** Its C3 clause
  refuses any file OUTSIDE the core that spells a `guests/assets/...`
  path, and crates/kaya/src/assets.rs is already its exemption as the
  one resolver. The `include_bytes!` lives there, on the allowed side by
  construction, not by a new exemption.

**The `kaya/` prefix is REFUSED in app packages.** An app asset whose
name starts with `kaya/` is refused by the same wall that refuses `..`
and absolute paths, with a sentence naming the reserved namespace. This
is a guard on the path someone walks by accident: without it, an app
could ship a `kaya/default-font` file of its own under the asset root
and silently shadow the built-in, and the failure would be a font that
changed on one platform.
check-assets gains a note for the namespace, and nothing else.

Apps override per-canvas by naming their own asset. There is no global
font setting for canvases: the drawing declares what it draws with.

**One pointer, so nobody conflates two layers.** Android packages assets
under a `kaya/` prefix INSIDE the APK, stripped by the Kotlin reader
before names are resolved (docs/assets-plan.md A4). That packaging
prefix is a different thing from the reserved guest-visible `kaya/` name
space, and an app asset literally named `kaya/x` would package as
`kaya/kaya/x`. The refusal above means that case cannot arise; the note
exists because the two spellings look identical in a grep.

**The typeface scene's Sora asset copy is untouched, deliberately.**
tools/scenes/typeface.steps registers the same font's BYTES over the
blob channel and reads back the resolved family (`expect_typeface
"Sora"`). That is a different channel proving a different thing — that a
guest-registered font reaches the platform's text system — and it stays
exactly as it is. The canvas reads the same file for a different
purpose. One file, two consumers, no shared machinery, and the OFL
requirements (guests/assets/fonts/OFL.txt in tree, unmodified font,
Reserved Font Name respected, no subsetting) are satisfied identically
for both: the OFL permits embedding, and embedding is not modification.

## §5 — Scale

**Backends report the window's scale; the core rasterizes at it and
re-rasters when it changes.** This is not an invention. It is the
mechanism every platform documents for bitmap-backed content:

- macOS names both the property and the invalidation hook:
  `backingScaleFactor` "returns the scale factor for a specific window",
  and `windowDidChangeBackingProperties:` "Is invoked when the window's
  backing properties change... Your app can provide an implementation if
  it needs to swap assets". Apple's own model for a bitmap-backed view
  is hold a bitmap at a scale, get told, re-render.
- Windows delivers it per top-level window: "Whenever a top level window
  switches monitors it is sent WM_DPICHANGED message with a recommended
  new window size", and documents what not re-rendering looks like
  (the OS stretches the stale bitmap).
- Wayland's fractional-scale protocol exists precisely to move
  rasterization to the client: `preferred_scale` is "notification of a
  new preferred scale for this surface that the compositor suggests that
  the client should use", with the scale as a fraction over 120.
- Qt, a shipping core-buffer framework, has the exact event:
  `QEvent::DevicePixelRatioChange`, with `QWindow::devicePixelRatio()`
  "tracking the device pixel ratio of the window when moved between
  displays". Avalonia has `TopLevel.ScalingChanged`.

kaya already has the geometry channels these reports would ride: the
backends report layout facts to the core today (the row-window reports
of docs/virtualization-plan.md §3 are the shape). The canvas's scale
report is one more fact on that path, backend plumbing with no binding
surface and no guest visibility, exactly as `kaya_window_moved` is.

**Two rules that fall out of the research:**

1. **Rasterize at the true scale, never the rounded one.** GTK is the
   one backend that can hand back a genuinely fractional scale:
   `gtk_widget_get_scale_factor` is an integer and "on systems with
   fractional scaling... returns the next higher integer value", while
   `gdk_surface_get_scale` is a `double` since GTK 4.12. Use the double.
   GTK says what fractional costs — at 125/150/175/225% "most
   application pixel boundaries do not align with device pixel
   boundaries" — and the mitigation under a core buffer is forced and
   simple: raster at the real number.
2. **The buffer can carry its own scale.** Qt's mechanical finding: "A
   QImage of size 400x400, with a device pixel ratio of 2.0, fits a
   200x200 QWindow on a high-density (2x) display, or is automatically
   down-scaled to 200x200 during drawing if targeting a standard density
   (1x) display." Each backend's image type has the same knob
   (`contentsScale` on a CALayer, the density fields on an Android
   bitmap), so a scale change that has not re-rastered yet degrades to a
   scaled blit rather than a wrong-size one.

**The failure mode to design against is the transition, not the steady
state.** Monitor-move bugs are endemic to core-buffer frameworks
(Avalonia #17834/#13917, Compose Multiplatform #1223/#3685/#4019/#531,
Flutter #77605), and none of them is a rasterizer bug: all are "the new
scale did not propagate before the next frame". A core-owned buffer
makes this more visible and easier to fix, since one place re-rasters.
Mixed-DPI straddling is unsolved by every framework in the survey; kaya
picks one scale per window like everyone else.

**Two claims are INFERRED and get measured rather than assumed** — both
carried from the prior-art sweep's own GAP markers, because a plan that
launders an inference into a fact is how a wrong "impossible" calcifies:

- Apple nowhere states that `\.displayScale` updates when a window
  crosses to a differently-scaled display. It follows from the
  environment contract; it is not written down. MEASURE at
  implementation, on a real two-display mac.
- No single GTK4 sentence says "GDK sets the cairo device scale so you
  draw in logical units". It follows from `get_scale_factor`'s
  documentation plus cairo device-scale semantics. MEASURE, and in any
  case §5's rule 1 makes kaya read the double itself.

## §6 — Appearance (ADOPTED RECOMMENDATION — open to veto)

**kaya owns a two-mode chart palette, resolved in the core.** The paint
roles of §3.4 resolve to kaya's own colours for light mode and dark
mode; only the MODE BIT crosses from the platform. The core re-rasters
on an appearance change, the same way it re-rasters on a scale change.

This is flagged rather than ruled because it is a sub-choice inside
ruling 1 that the maintainer has not personally decided. The alternative
is sub-option (i): the backend resolves platform role colours and hands
them to the core, which rasterizes with them. Here is the evidence that
picked (ii), and the one fact that decides it for this tree.

**The decisive fact: only (ii) keeps a buffer byte-identical.** Under
(i) the INPUTS differ per platform, so the pixels differ, so §7's
primary observable cannot exist and the canvas falls back to structural
assertions on five lanes. Under (ii) the buffer is byte-identical per
mode, which is one frozen string per mode instead of five.

**And the practice is close to universal:**

- Every mainstream charting library owns its palette. D3's
  `schemeCategory10`, Vega-Lite's `tableau10` default, matplotlib's
  literal cycle, ECharts changing its default by fiat in v6. The
  strongest datum is Chart.js DECLINING to read the OS bit in core
  (#8658 closed "implement externally"; the maintainer: "The detection
  is easy, but too slow to do in chart update"). The strongest positive
  is Highcharts v13, which reads `prefers-color-scheme` only to choose
  between two Highcharts-authored palettes — one bit, two owned
  palettes, which is exactly this recommendation.
- Every core-buffer GUI framework in the survey does the same at
  whole-app scale: Compose's `isSystemInDarkTheme()`, Avalonia's
  `ActualThemeVariant` falling back to the OS variant, egui's
  `ThemePreference` of System/Dark/Light. None pulls OS role colours
  into its palette.
- **Both platform vendors decline to own a chart palette.** Apple's
  semantic colour list (Label, Secondary label, ..., Separator, Link)
  has NO data-series role, and Material 3's role vocabulary has none
  either. If platform-sourced series colours were right, Apple and
  Google are the two parties who would have shipped the role. The
  structural reason: a categorical palette must give N mutually
  distinguishable, colourblind-safe, stable-identity hues, and an OS
  accent colour is one user-chosen emphasis hue that promises none of
  that.
- No instance was found of a cross-platform app's charts using platform
  colours. The closest anything gets is the light/dark bit.

**One more reason specific to kaya, and it is an invariant-1 reason.**
SwiftUI is the one framework in the survey that auto-themes a drawing:
`GraphicsContext` resolves `Color` against the live environment and
re-runs the closure when Appearance changes. Under the dead lowering
design, kaya's mac backend would have got free theming that no other
backend gives — a uniform-semantics divergence dressed as a win. Under
the buffer, the core resolves for everyone and the question does not
arise.

**What crosses the wire from the platform:** one bit, on the channel the
existing appearance handling already uses (the same signal the styling
milestone's dark-mode work reads). What does not cross: any platform
colour, for a canvas.

## §7 — The harness: what a scene may assert about a drawing

This section is the one the architecture ruling rebuilt. Under lowering
it was the weakest part of the plan — four rasterizers, no byte-shared
pixel fact, an ink-bounds approximation doing all the work. Under the
core-owned buffer it is the strongest, because the artifact under test
is bytes kaya produced and the same bytes are producible on every lane.

### §7.1 The primary observable: a byte-hash of the raster

**`expect_drawing_hash <target> "<hex>"`** — the canvas is rasterized at
the CANONICAL SCALE (1.0) with the CANONICAL PALETTE (light mode),
independent of the lane's display and the machine's appearance setting,
and the hash of those pixels is compared byte-for-byte against a string
frozen in tools/scenes.

It is one string on five platforms because every input is one thing:

| input | why it is identical on every lane |
| --- | --- |
| the op stream | invariant 6 — the scene is shared verbatim and §3.2's viewbox keeps guest coordinates platform-independent |
| the font bytes | §4.2 — embedded in libkaya, or staged under the asset root and verified by hash by every lane |
| the shaper and the rasterizer | one crate set, CPU only, pinned in Cargo.lock, compiled into every lane's libkaya |
| the palette | §6 — kaya's own, and the verb pins the mode |
| the scale | the verb pins it |

**What it proves that nothing else can:** that five platforms' libkaya
produced the same drawing, down to antialiasing. That is the assertion
React Native Skia built a whole screenshot suite to get, expressed as
one frozen string, and it is what makes the rest of the checks a
backstop rather than the whole story.

**What it does NOT prove, said plainly: that anything reached the
screen.** The hash reads the raster, not the window. §7.2 is what fails
when the blit dropped.

**Two disciplines it inherits.**

- *It is a read of an artifact, not of the model.* The doctrine that
  governs every other read — "Reading kaya's model would make the scene
  agree with itself and prove nothing" — is satisfied because the raster
  is the OUTPUT of the code under test (validation, fold, shaping, font
  resolution, palette, rasterizer), not an echo of the declaration. A
  verb that read back the op list would be the forbidden shape; this one
  is `expect_shares`' shape, where "the ROUNDING has to be identical
  everywhere, not just the arithmetic".
- *A hash is a terrible diagnostic, so it may not be the only thing
  printed.* check-diagnostics' rule (invariant 3) applies to a failing
  expectation as much as to a why-not: on mismatch the verb prints what
  it MEASURED — buffer dimensions, op count, ink bounds, and the
  per-region colour summary of §7.2 — and under `KAYA_RECORD=1` writes
  the actual raster beside the expectation as a PNG for a human. It may
  not print a guess about which op moved.

**THE ONE THING THAT COULD FALSIFY THIS OBSERVABLE, and it is measured
before the first hash is frozen.** ALL FIVE LANES ARE aarch64 TODAY:
mac and iOS on Apple silicon, windows on `aarch64-pc-windows-msvc`
(tools/deploy-win.sh), android on `arm64-v8a`
(tools/android/run-emulator.sh), linux in a container on the same mac
host. So cross-ISA byte-identity of a SIMD raster pipeline was UNTESTED,
and tiny-skia's "same results as Skia" claim is about a reference
implementation, not about x86_64 versus aarch64. Phase 1 owed one
measurement — the same op stream rasterized on both ISAs, hashes
compared — BEFORE any hash went in a .steps file. IT WAS MADE
2026-08-26 and the two agree
(docs/measurements/canvas-cross-isa-2026-08-26.txt); the x86_64 side was
emulated, which tests the codegen path and not a real x86_64 CPU, so the
day a native x86_64 lane arrives the probe is re-run. If they diverge, the
primary observable degrades to a per-architecture hash (still one string
per lane family, still stronger than anything lowering could offer) and
§7.2 carries more weight. This is written down because the first x86_64
lane kaya ever adds is where an unmeasured claim would fail, months from
the change, on the lane furthest from it.

### §7.2 The secondary checks, which are the legible ones

A hash tells a human nothing. These two do, and one of them is the only
check that fails when the pixels never reached the window.

**`expect_drawing <target> "<ops>/<l>,<t>,<r>,<b>"`** — how many ops the
core replayed, and the **ink bounding box**, normalized to hundredths of
the canvas's own box and rounded by one shared function the way
`shares()` is. Normalized, so it is one frozen string though every
platform's pixel size differs.

What it catches, legibly: nothing arrived; the transform is wrong; the y
axis is inverted; the drawing sits in a corner of its track. That last
one is not hypothetical — it is the defect `expect_column_edges`' span
half was invented for, recorded in docs/tables-plan.md: "the content-hug
cut kept every cluster exactly right while leaving 90% of the viewport
empty: alignment alone cannot see it."

**`expect_ink <target> "<RRGGBB>/<RRGGBB>/..."`** — the colour at
declared normalized probe points, sampled from THE BACKEND'S OWN
RENDERED SURFACE. This is `expect_app_icon`'s move, and under the buffer
its job is sharper than it was in the draft: the hash already covers
"did the core draw the right thing", so this verb exists to prove the
blit — that the buffer reached the platform's image object, in the right
pixel format, the right way up, at the right size, unswizzled.

It inherits `expect_app_icon`'s measured discipline verbatim, and every
item is a rule about the scene's test figure, not about the app:

- **Sample centres, never boundaries.** The existing comment's reason:
  "whatever rescale a platform applies blurs a quadrant BOUNDARY". A
  probe point must sit deep inside a flat-filled region.
- **Flat, unmistakable colours** — which is why
  guests/assets/icons/kaya-mark.png is four solid quadrants. The canvas
  scene draws a coarse, high-contrast test figure for the same reason.
  The realistic chart is the portfolio's, and its looks are the
  captures' business.
- **Sample through a 16-bit context with `interpolationQuality = .none`,
  and round to 8 bits exactly once.** A measured finding, not a
  precaution: an 8-bit context quantizes twice and reported `1D71D8` for
  a declared `1C71D8` (2026-08-18, recorded at
  swift/KayaSwiftUI.swift, kayaIconQuadrants' own comment — the line
  number this file used to carry was already 90 lines stale when the
  depth slice looked it up, so it names the FUNCTION now, and
  kayaSampleRGB is the canvas's sibling of it). A canvas ink read that
  skips this will
  be off by one somewhere and look like a rasterizer bug.

Every backend has a route to its own pixels: `NSView.cacheDisplay` or
SwiftUI's `ImageRenderer` on Apple, `RenderTargetBitmap` on WinUI, a
`GdkTexture` download on GTK, `PixelCopy` or a bitmap draw on Compose.
Each has caveats (WinUI's cannot render content outside the visual tree;
a re-render into a bitmap is not literally a read of the screen), which
is why this verb samples a handful of points rather than hashing — the
hash's job is done one layer up.

### §7.3 What none of it proves

The three verbs prove the drawing was computed identically everywhere,
that it arrived where it belongs, and that the intended colours reached
the intended places on the real surface. They prove **nothing** about
whether the chart looks right to a person: whether the labels collide at
narrow widths, whether the series is legible against the ground in dark
mode, whether the axis reads as an axis.

That residue is held two ways, both established practice here:

- **Per-platform captures, reviewed by a human.** The recording pipeline
  exists (`KAYA_RECORD=1`, per-step stills via tools/harness-extract.sh),
  it compares nothing automatically, and no lane capture is checked in.
  The styling milestone's answer is the model: run the probes per
  platform, write the report, land the report so code comments can cite
  it (docs/styling/README.md, "frozen measurement reports").

  **This is not a fallback, it is currently kaya's best detector of look
  bugs**, and this app has the receipts. docs/portfolio-plan.md §5: "The
  first refreshed screenshots found what the model assertions did not
  (2026-08-23). GTK's flex measure summed unequal grower naturals before
  allocating equal tracks, so the first table overlapped its account
  total. macOS stretched the detail but not the new accounts For." Every
  scene assertion was green through both. A canvas milestone that does
  not budget a capture round on all five platforms is planning to ship
  the same class of defect.
- **A static gate over the four blits**, on tools/check-table-card.sh's
  model. Under the buffer it is much smaller than the draft's version,
  because there are no per-backend op arms to hold level. What it holds:
  every backend's canvas arm is present, blits the core's buffer at the
  scale it reported, is panic-free on a zero-sized or absent buffer, and
  keeps the node present-and-empty when there is no drawing yet
  (check-empty-child's rule, §8). Watched negatives with substitution
  counts printed, per invariant 3.

### §7.4 The negative tests

- The op stream perturbed so the y axis inverts, with the hash AND
  `expect_drawing` watched going red on every lane.
- A one-pixel perturbation — one op moved by a tenth of a box unit —
  watched reddening the hash and NOT `expect_drawing`, which is the
  proof that the hash is doing work the bounds cannot.
- The palette's dark-mode entry swapped into the light-mode slot,
  watched red on the hash.
- The blit deleted from one backend, watched red on `expect_ink` and
  GREEN on the hash — the pair that proves the two verbs cover different
  failures, and the reason both exist.
- A canvas whose drawing was never declared: present and empty, never
  absent (check-empty-child's rule, for the reason it applied to an
  undecodable image — a declarative backend that renders nothing takes
  the node out of the tree and every positional layout above it reads
  the wrong child).
- A malformed op stream refused by the core, so nothing downstream ever
  sees one — one refusal per §3.5 clause, each watched failing first.
- The font asset renamed so it cannot resolve, watched producing the
  resolver's own sentence rather than a blank drawing.

## §8 — The four blits, and Windows

The backend work is small, which is the point of the architecture.

Each backend already has an arm that puts bytes on screen for the Image
widget, and each of those arms decodes ENCODED bytes today: GTK's
`gdk::Texture::from_bytes` "reads encoded PNG/JPEG" by its own comment
(crates/kaya/src/gtk.rs), WinUI builds a `BitmapImage` over an
`InMemoryRandomAccessStream` (crates/kaya/src/winui/mod.rs). The canvas
arm is the RAW-PIXEL SIBLING beside each, not the same call:

- **SwiftUI (macOS and iOS, one file).** A `CGImage` over the buffer,
  shown through `Image`, with the layer's `contentsScale` set to the
  reported scale. The `KayaRender` wrapper that check-universal-props
  holds unbypassed applies the a11y props above it. One tier for both
  platforms: no size class, no native-versus-synthesized split, so
  unlike the table this needs no tier gate.
- **Compose.** An `ImageBitmap` filled from the buffer, drawn in an
  ordinary `when (node.kind)` arm, threading the modifier
  check-universal-props demands per arm.
- **GTK4.** A `GdkMemoryTexture` over the buffer in a `GtkPicture` — the
  raw-pixel constructor beside the encoded one already used, and
  GTK4's retained render-node tree caches it for free.
- **WinUI.** A `WriteableBitmap` whose pixel buffer receives the bytes.

**Pixel format is the one per-backend conversion.** The core's buffer is
premultiplied RGBA8 (tiny-skia's `Pixmap` layout). WinUI's
`WriteableBitmap` is understood to want premultiplied BGRA8, so that arm
swizzles. It is on §11's measure-at-implementation list rather than
asserted, because a channel order believed and not checked is exactly
the kind of thing that renders a blue chart red on one lane.

**Windows needs no new dependency, and menu Q5 is deleted rather than
answered.** The draft priced Win2D honestly and the price was real: the
WinUI backend is Rust, not C#, so Win2D would have meant a new fetch in
tools/fetch-winappsdk.sh, its `.winmd` through tools/winui-bindgen into
more committed bindings (crates/kaya/src/winui/bindings.rs), and the
native `Microsoft.Graphics.Canvas.dll` staged beside every Windows app
kaya ever ships. It also had an unresolved version-skew problem: Win2D
1.4.0's NuGet dependency is the 1.8-era `Microsoft.WindowsAppSDK.WinUI`
while this tree is on the 2.x components, and the Windows App SDK 2.0
release notes do not mention Win2D at all. Under the buffer none of that
is needed: a `WriteableBitmap` is in the bindings the backend already
has. The permanent consequence for every Windows app kaya ships is
therefore no consequence at all, which is the strongest single argument
this architecture produced on the packaging side.

**The gate work that question uncovered stays landed** (c98e4c6, and it
landed ahead of any ruling because the hole existed whether or not Win2D
ever arrived). tools/check-pins.sh has its fifth clause: every `fetch`
in tools/fetch-winappsdk.sh names an exact version AND the sha256 of the
`.nupkg` nuget.org serves, the script verifies on every run including
the CACHED path, a second tools/ script curling the same flat container
is refused by name, and the gate cuts `verify_sha256` out of the script
and runs it against wrong bytes on every sweep. What is still unheld:
`third_party/winappsdk/WindowsAppRuntimeInstall-arm64.exe`, the 108 MB
installer tools/deploy-win.sh's `--provision` arm copies to the VM — no
script fetches it, no package contains it, it was placed by hand, and
pinning it means deciding what it is first.

**And the GTK compile hole stands.** gtk-sys needs the distro's
pkg-config world, so check-targets structurally cannot compile that
backend; tools/check-gtk.sh is the compile check after any
crates/kaya/src/gtk.rs change.

## §9 — Accessibility: a drawing is an image

check-universal-props will demand an answer the day the kind exists, and
kaya already has the right one.

`a11y_id` and `a11y_label` are universal — every kind carries both — and
`expect_ax <target> "<role>/<name>"` reads them back off the platform's
own accessibility peer. The role set is closed and **already contains
`image`**. A drawing is an image to every platform's accessibility tree,
so a canvas normalizes to `image` and the app authors the spoken name.
No new role, no new verb, no vocabulary motion.

`a11y_hint` is correctly refused. It is admitted on activation kinds
only (button, checkbox, select, radio) because "a hint therefore needs
an activation to describe". A canvas has no activation while pointer
events are deferred, so the root refuses a hint on one.

What kaya does NOT do is build a semantics tree out of the drawing.
DESIGN.md states the position already: "Custom-drawn frameworks pay a
permanent tax building semantics trees by hand; wrapping native widgets
gets this for free." A canvas is the one place an app opts out of that
dividend, and the honest contract is that it gets an image with a name.
The industry agrees from both sides: MDN's canvas page ("Canvas content
is not exposed to accessibility tools like semantic HTML is ... you
should use canvases like images and avoid using them to render
significant content without accessible backing markup") and Apple's own
Canvas documentation ("A canvas doesn't offer interactivity or
accessibility for individual elements").

This is also why §10's chart keeps its NUMBERS in the accessible layer
even though it draws its own tick labels: the total beside the chart is
a real label, and the chart's `a11y_label` says what the series is and
what it ends at.

Worth recording for a later slice, since the retained display list makes
it possible and the pixels never would: a per-element description could
one day ride the op stream (an op that names what the next path means),
which is a thing this architecture can do and a bitmap-only design
cannot. Not v1, not designed, filed here so the option is not
forgotten.

## §10 — The portfolio chart

The forcing artifact is a value-over-time chart above the portfolio
total in guests/python/portfolio.py. `tick()` already applies fixed
per-ticker deltas and recomputes the total, so a series appended there
is deterministic and a scene can freeze what it draws. That determinism
is the app's own standing discipline (docs/portfolio-plan.md §0: "every
number in the scene is computed from fixed inputs, so the byte-frozen
scene stays honest").

What the chart needs, and what v1 gives it:

| element | op | in v1? |
| --- | --- | --- |
| the price series | `move_to` + `line_to` run | yes |
| gridlines and axes | `move_to`/`line_to` pairs | yes |
| area fill under the series | `close` + `fill` | yes |
| tick labels (dates, dollars) | `font` + `text` | **yes** — ruling 3 |
| smoothed curves | cubic | no |
| gradient fills | gradient | no |

**Why the labels are drawn rather than placed beside the canvas.** The
draft's answer was a small grid — a column of y labels, the canvas, a
row of x labels underneath — relying on §3.2's stretch rule to keep them
aligned. The maintainer's ruling names the problem with it: a chart
needs tick labels from the first chart, and widget-labels-at-tick-
positions is awkward — every tick is a widget, the spacing is a layout
problem the app solves by arithmetic that duplicates the chart's own,
and any tick that is not on a round row boundary has nowhere to live. It
also would not survive the second artifact (a label at a data point, an
annotation, a rotated axis).

The accessibility answer does not change (§9): drawn labels are pixels,
so the numbers a screen reader reads are the total and the summary label
beside the chart. That was already true of the draft's design for
everything except the tick values, and a tick value is the least useful
thing in the accessibility tree anyway.

## §11 — Sequencing

Depth then breadth, per CLAUDE.md, with the between-phase gates that are
supposed to stay red while half the work is outstanding.

1. **Protocol root and the rasterizer.** The `canvas` kind, the
   `set_drawing` record, the opcode/paint/rule/align/baseline enums, the
   core's validation and every refusal in §3.5 with unit tests watched
   failing first; the raster module (op fold, path build, shaper, glyph
   outlines, palette resolve, buffer cache and invalidation); the
   embedded default font and the resolver's reserved-name entry plus the
   `kaya/` refusal; `VERB_FEATURE` entries for all three verbs (§11.1);
   and THE CROSS-ISA MEASUREMENT of §7.1 before any hash is frozen. The
   spec hash moves once, here, and everything regenerates in lockstep
   (invariant 7).
   RED BY DESIGN at the end of this phase: check-sugar-surface (16
   constructors outstanding), check-universal-props (four arms), and
   check-verbs (both interpreters).
2. **Mac depth.** The SwiftUI blit and its read-back, the Rust binding's
   canvas plus drawing scope, the three harness verbs on the mac stage,
   and the canvas scene. validate-mac green. The other three backends
   carry `depth_stub("canvas")` so check-stubs and check-steps agree
   those legs are not wired — between them those two gates state one
   rule, that a scene's legs are wired on a runner if and only if that
   runner's backend has the feature. check-verbs stays RED here: the
   Compose half of the interpreter work lands in phase 3.
3. **Breadth, in parallel worktrees.** GTK, WinUI and Compose blits
   (small — one raw-pixel image arm and one read-back each), plus the
   remaining seven bindings and the C floor in both construction zones.
   Each lane green on the byte-shared scene. check-sugar-surface goes
   green when the sixteenth constructor lands, not before.
4. **The chart.** The portfolio app grows its canvas, the scene grows
   its assertions, and the captures are taken on all five platforms and
   reviewed. This is where the looks get ruled on and where any second
   round of visual fixes belongs. The palette of §6 is the thing to look
   at hardest, in both modes.
5. **The matrix.** tools/validate-all.sh, all five lanes, before this is
   called done.

Phases 1 and 2 are one worktree. Phase 3 is the fan-out the tables and
virtualization milestones both used.

**The measure-at-implementation list**, collected so no phase inherits
an assumption:

| # | what | when |
| --- | --- | --- |
| 1 | ~~cross-ISA byte-identity of the raster (§7.1) — all five lanes are aarch64 today~~ MEASURED 2026-08-26, identical: docs/measurements/canvas-cross-isa-2026-08-26.txt | phase 1, BEFORE the first frozen hash |
| 2 | WinUI `WriteableBitmap` pixel format and whether the swizzle is needed (§8) | phase 3 |
| 3 | does `\.displayScale` update on a cross-display move? (§5, inferred) | phase 2, on a two-display mac |
| 4 | does GDK set the cairo device scale, and what does `gdk_surface_get_scale` return at fractional scales? (§5, inferred) | phase 3 |
| 5 | re-raster + blit cost at the portfolio's real canvas size, per tick (§1.3) | phase 4 |
| 6 | shaping cost for a chart's label set, and whether shaped runs need caching | phase 4 |

### §11.1 One mechanical trap, worth knowing before phase 2

**There is no conditional syntax in a `.steps` file.** A scene cannot say
"run this leg only where the backend has canvas". Platform divergence is
absorbed four ways only: a verb's bare invariant form, check-steps'
width-band lints, designing the observable so the tiers agree, and the
whole-scene `depth_stub` mechanism.

That last one is keyed on a scene's **verbs**, through
tools/lib/scene-features.py's `VERB_FEATURE` table, with a fallback to
the scene's **name**. A scene called `canvas.steps` derives the feature
`canvas` from its name alone, so phase 2's own scene needs nothing.
**The portfolio chart is the case that does.** Once a canvas verb
appears in tools/scenes/portfolio.steps, the feature can no longer be
derived from that scene's name, and without `VERB_FEATURE` entries
mapping the canvas verbs to `canvas`, a backend still declaring
`depth_stub("canvas")` cannot hold the portfolio legs off. The table's
own comment says exactly why it is keyed this way: "the day another
scene demands the same lowering without being called after it, a backend
still declaring the depth stub must hold those legs off too."

So all three verbs get `VERB_FEATURE` entries in phase 1, before any
scene uses them. It is three lines, and finding this out in phase 4
instead would mean a deadlock between check-steps and check-stubs with
the chart already written.

## §12 — What was considered and rejected, so nobody re-litigates

- **Lowering the op list into four native drawing APIs.** The draft's
  whole design. Rejected 2026-08-26 on §1.2's evidence: Qt's migration
  away from it, and MAUI's issue record as the shipped version of it.
- **Vello's scene encoding as the widget's wire format.** Rejected
  twice over — it is not a byte format (twelve parallel `Vec`s, no
  `repr(C)`, no `serde`), it is explicitly unfrozen and alpha, it breaks
  at minor versions, no third party has ever shipped it as interchange,
  and under the core-owned buffer the question does not even arise
  because nothing about the rasterizer crosses the wire. DESIGN.md's
  open question #3 is re-filed against the pixel-handoff feature it was
  written about and stays open there.
- **GPU rasterization for this buffer.** Refused on principle (§1.4):
  driver-dependent antialiasing kills byte-identity, and the linux lane
  has no GPU.
- **Callback-per-frame immediate mode.** Rejected by the 2026-07-22
  ruling ("8-language FFI churn, divergent frame timing") and not
  reopened. The recording scope gives guests the immediate-mode
  SPELLING without the callback — which is also the direction the
  industry has moved: GTK4 replaced immediate `draw()` with a retained
  snapshot model, React Native Skia REMOVED its immediate
  `useDrawCallback` in favour of a declarative tree, and even egui, the
  flagship immediate-mode library, emits a retained display list to its
  backend.
- **A packed byte buffer for the op stream.** The named escalation, not
  the design (§3.1). Admission needs a measured artifact.
- **An SVG path string as the payload.** Compact and familiar, but a
  second grammar nobody asked for, stringly typed, and the core's
  refusals would become a parser.
- **Text deferred to v2, with axis labels as widgets beside the
  canvas.** The draft's position, overruled 2026-08-26: charts need tick
  labels from the first chart, the widget arrangement is awkward, and
  the divergence argument that justified deferring text was an argument
  about platform text engines kaya no longer calls (§10).
- **Platform role colours resolved per backend and rasterized by the
  core** (§6's sub-option (i)). Rejected as the recommendation because
  it makes the buffer non-identical across platforms by construction,
  which forfeits §7.1 — and because no charting library and no
  core-buffer framework in the survey does it, and neither platform
  vendor even defines a data-series role.
- **A width/height property on widgets, so a canvas can declare its
  size.** Rejected in favour of the viewbox, which supplies the natural
  size as a side effect and does not oblige fourteen other kinds to
  answer for a property they do not want.
- **A resize occurrence so the guest can redraw at the true size.**
  Unnecessary under §3.2, and it would make the op stream
  platform-dependent, which is the one thing invariant 6 cannot survive.
- **Building a semantics tree from the drawing.** kaya's whole
  accessibility dividend comes from native widgets being the tree. A
  canvas is where an app opts out, and the honest contract is an image
  with an authored name (§9).
- **Reading the drawing back out of the core's model as the
  observable.** Forbidden by the doctrine that governs every other read:
  "Reading kaya's model would make the scene agree with itself and prove
  nothing." §7.1 reads the raster, which is an output, not the
  declaration.
- **A per-canvas or per-app font setting.** The drawing declares what it
  draws with; a global would be a second place to look when a label
  changes shape.

## §13 — Sources

Researched 2026-08-26 in three rounds: the wire-format round (Vello,
Win2D, the four platform drawing APIs), the architecture round
(lowering versus a core-owned buffer, scale, palette, exposure), and
the dependency round that corrected §4.1's text stack against the
archived-crate wave — same day, and the reason no crate here is cited
from memory. Every claim above about a platform or another framework,
rather than about this tree, traces to one of these. The crates named
are the STACK, verified maintained on 2026-08-26; the versions pin in
phase 1.

**Architecture: core-owned buffer, and its costs**
- https://doc.qt.io/qt-6/qpaintengine.html — the raster engine is Qt 6's desktop default
- https://doc.qt.io/archives/qt-4.8/paintsystem-devices.html — Qt 4's per-platform native engines, and "pixel exactness ... in a platform-independent way"
- https://wiki.qt.io/Qt5GraphicsOverview — why raster beat the OpenGL engine
- https://doc.qt.io/qt-6/qstyle.html — core-owned rasterizer, platform-owned appearance
- https://github.com/dotnet/Microsoft.Maui.Graphics — the per-platform engine table; archived 2023-12-21
- https://learn.microsoft.com/en-us/dotnet/maui/user-interface/graphics/ — "The state that's persisted by these methods is platform dependent"
- https://github.com/dotnet/maui/issues/21886, /29661, /4993, /30673, /18679, /9252 — the divergence record
- https://docs.gtk.org/gtk4/migrating-3to4.html and https://docs.gtk.org/gsk4/class.CairoNode.html — GTK4 draws cairo into a bitmap node inside a retained tree
- https://wayland.freedesktop.org/architecture.html — the client renders into the buffer; the compositor is told which buffer
- https://shopify.engineering/react-native-skia-2022 — one rasterizer everywhere, with a cross-platform screenshot suite as the proof obligation
- https://www.chromium.org/developers/design-documents/gpu-accelerated-compositing-in-chrome/ — texture upload as a measured bottleneck
- https://learn.microsoft.com/en-us/windows/win32/learnwin32/retained-mode-versus-immediate-mode — the taxonomy, and retained's memory cost
- https://docs.flutter.dev/resources/faq — the engine's binary floor

**Rasterizer and text**
- https://github.com/linebender/tiny-skia — "CPU only", "must produce exactly the same results as Skia", text "Out of scope"
- https://crates.io/crates/vello_cpu — the named successor to revisit
- https://groups.google.com/g/skia-discuss/c/OUzwQqxsCmo — GPU antialiasing chosen per surface and primitive, gated on device features
- https://docs.slint.dev/latest/docs/slint/guide/backends-and-renderers/backends_and_renderers/ — a software renderer's feature bill
- https://api.flutter.dev/flutter/flutter_test/matchesGoldenFile.html — "Custom fonts may render differently across different platforms"; the Ahem dodge
- https://playwright.dev/docs/test-snapshots — "Screenshots differ between browsers and platforms due to different rendering, fonts and more"
- https://github.com/harfbuzz/harfrust — the HarfBuzz project's own Rust port; shapes the run, and runs on read-fonts by design
- https://github.com/googlefonts/fontations — read-fonts and skrifa: font parsing and glyph outlines, Chrome-production
- https://rustsec.org/advisories/RUSTSEC-2026-0206 — rustybuzz unmaintained (archived 2026-08-06), the advisory behind §4.1's near-miss; ttf-parser is the same abandoned family
- https://crates.io/crates/cosmic-text — NOT v1; the designated candidate if wrapped/paragraph/bidi layout ever arrives
- https://docs.rs/egui/latest/egui/enum.Shape.html — geometry survives a scale change, shaped text does not

**Scale**
- https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/APIs/APIs.html — `backingScaleFactor`, `windowDidChangeBackingProperties:`, `contentsScale`
- https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged — per-window DPI change
- https://wayland.app/protocols/fractional-scale-v1 — `preferred_scale`, the client rasterizes
- https://doc.qt.io/qt-6/qwindow.html#devicePixelRatio and https://doc.qt.io/qt-6/highdpi.html — the change event, and a bitmap carrying its own device pixel ratio
- https://docs.gtk.org/gtk4/method.Widget.get_scale_factor.html and https://docs.gtk.org/gdk4/method.Surface.get_scale.html — the integer and the double
- https://blog.gtk.org/2024/03/07/on-fractional-scales-fonts-and-hinting/ — what fractional scaling costs
- https://docs.avaloniaui.net/docs/concepts/toplevel — `ScalingChanged`
- Monitor-move bug record: https://github.com/AvaloniaUI/Avalonia/issues/17834, https://github.com/JetBrains/compose-multiplatform/issues/1223, https://github.com/flutter/flutter/issues/77605

**Palette**
- https://github.com/chartjs/Chart.js/issues/8658 and https://github.com/chartjs/Chart.js/discussions/9214 — declining the OS bit in core
- https://www.highcharts.com/docs/chart-design-and-style/branding — one bit choosing between two authored palettes
- https://d3js.org/d3-scale-chromatic/categorical, https://vega.github.io/vega-lite/docs/scale.html, https://matplotlib.org/stable/users/explain/colors/colors.html — owned palettes everywhere
- https://developer.apple.com/design/human-interface-guidelines/color and https://m3.material.io/styles/color/roles — no data-series role in either vendor's vocabulary
- https://developer.apple.com/documentation/swiftui/graphicscontext — the one framework that auto-themes a drawing, and why that would have been a divergence

**Accessibility**
- https://developer.mozilla.org/en-US/docs/Web/API/Canvas_API — "Canvas content is not exposed to accessibility tools"
- https://developer.apple.com/documentation/swiftui/canvas — "A canvas doesn't offer interactivity or accessibility for individual elements"

**Vello (the re-filed thread) and Win2D (the dependency that is no longer needed)**
- https://github.com/linebender/vello — "alpha state"
- https://github.com/linebender/vello/blob/main/doc/roadmap_2023.md — "too early to freeze the format"
- https://docs.rs/vello_encoding/latest/vello_encoding/struct.Encoding.html — twelve parallel `Vec` fields
- https://github.com/linebender/vello/blob/main/CHANGELOG.md — the 0.9.0 `GlyphRun` breaking change
- https://github.com/wieslawsoltes/VelloSharp — archived; wrapped scene-building calls, not the encoding
- https://www.nuget.org/packages/Microsoft.Graphics.Win2D — 1.4.0, 2026-03-16
- https://github.com/microsoft/Win2D/blob/winappsdk/main/CHANGELOG.md — the WinAppSDK 1.8 dependency, and the only release record
- https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/release-notes/windows-app-sdk-2-0 — silent on Win2D

## §14 — The ledger

Struck on ratification day, in docs/deferred.md:

- The **Canvas widget** entry keeps its headline (nothing is built) and
  gains the 2026-08-26 ratification note pointing here, with the
  superseded half of the 2026-07-22 ruling named as superseded rather
  than left to be read as current. Its `KEY:` line names the nouns a
  closing sweep will have to find: canvas, drawing, display list,
  viewbox, paint role, raster, tiny-skia, Win2D.
- The **Vello scene-encoding subset** entry records the re-filing: it
  arrives with the PIXEL-HANDOFF feature, not with Canvas, and the
  canvas widget's wire format is settled without it. DESIGN.md's open
  question #3 stays open under that reading.
- The **Video widget** entry's parenthetical stops calling the
  surface-handle transport "the Canvas zero-copy arm", since the canvas
  no longer uses it.

Nothing else closes here. Pointer events on a canvas, gradients, curves,
dashes, joins, blends, images-inside-a-drawing, packed op encoding, text
beyond one line, and per-element accessibility descriptions all remain
deferred, each admission-gated on an artifact.
