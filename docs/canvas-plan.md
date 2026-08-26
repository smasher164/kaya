# Canvas: a drawing surface on the widget vocabulary

**DRAFT — AWAITING RATIFICATION. Nothing in this file is decided.** It is a
proposal plus §7's decision menu, written against base 56315ce. No protocol
byte has moved, no binding surface exists, and the spec hash has not been
touched. Every recommendation below is a recommendation; the maintainer rules
on §7 first and the rest of this file is rewritten to whatever he rules.

Canvas is the last of the three features the portfolio dashboard exists to
force (docs/portfolio-plan.md §0, ratified 2026-08-21): dynamic tables, then
row virtualization, then this. Both predecessors are done, and
docs/portfolio-plan.md §4 records the hole this fills: "**No chart.** The
portfolio total is a label; the canvas slice will replace the space above it
with a value-over-time chart. The 'Day tick' button exists partly to
accumulate the series a chart will want."

## §0 — what is already ratified, and the one place two rulings disagree

Three prior rulings constrain this, and they must be read together because
two of them answer the same question differently.

**A. The widget shape (docs/deferred.md, Akhil, 2026-07-22).** "The viable
shape is a DISPLAY LIST — the guest transmits drawing commands (paths, fills,
strokes, transforms, text runs) as data; core retains it as a prop; backends
replay it into the native surface (SwiftUI Canvas, Compose DrawScope, GTK4
DrawingArea/cairo; WinUI needs Win2D CanvasControl — a new NuGet dependency
and packaging payload). Callback-per-frame immediate mode is REJECTED
(8-language FFI churn, divergent frame timing). The slippery slope is the op
vocabulary (gradients, blend modes, images, text shaping) — start with a
deliberately minimal op set. Pointer-event occurrences on the canvas are a
further deferral inside this one."

**B. The compositor architecture (DESIGN.md, "Custom drawing").** "Decision:
v1 ships pixel surfaces only, passed as platform surface handles (IOSurface,
DXGI shared handles, dmabuf), so shipping pixels means passing a handle rather
than copying. Display lists are v2 and adopt Vello's scene encoding rather
than inventing a format."

**C. The open question (DESIGN.md open question #3).** "The Vello
scene-encoding subset for v2 display lists (arrives with Canvas, after v1)."
docs/deferred.md restates it: the subset arrives "on the surface-handle
transport (pixel surfaces as IOSurface/DXGI/dmabuf; the blob channel is the
byte-copy arm, Canvas is the zero-copy arm)."

A and B are not the same feature. B is about an app that renders its own
frames on its own schedule and hands kaya finished pixels — the compositor
case, whose whole point is that kaya never looks inside the content. A is
about a widget in kaya's own layout whose content kaya must be able to
validate, re-rasterize at any size, and lower to four different native
drawing APIs. They got filed under one open question because both were called
"display lists", and the filing has been quietly deciding the design ever
since.

This proposal separates them, and that separation is §7's first decision.
Everything below builds A. B keeps its open question, unchanged and still
open, under the surface-handle arm where it belongs.

The reason to separate them is not tidiness. Vello's encoding is the input to
Vello's own GPU compute pipeline. Adopting it here would mean eight guest
bindings hand-writing that layout and four backends *decoding* it in order to
replay it into SwiftUI Canvas, DrawScope, cairo and Win2D, which are retained
scene-graph and immediate-mode APIs that want `move_to`, `line_to`, `stroke`.
The zero-copy premise only pays when kaya rasterizes with Vello and hands the
platform pixels, which is the opposite of "wrap each platform's native
widgets".

**And the format is not available to be adopted** (researched 2026-08-26,
§10 carries the URLs). Vello's own README still says "Vello can currently be
considered in an alpha state". The only statement of intent about the encoding
is a 2023 roadmap document that has not been superseded: "Previously we've
considered it an internal detail ... Obviously it's also too early to freeze
the format". `Encoding` is not a packed byte layout at all — it is a struct of
twelve parallel `Vec`s, with no `repr(C)` and no `serde` feature, so there is
nothing to put on a wire without inventing a serialization anyway. It takes
breaking changes at minor versions (0.9.0 added two fields to `GlyphRun`), and
it has no third-party precedent: the one serious FFI binding, VelloSharp, did
not ship the encoding — it exposed scene-*building* calls over a C shim, and
was archived 2026-01-31 "waiting for final Vello api".

See §7 D1 and §8.

## §1 — the guest surface

### §1.1 The shape: a recording scope that declares one record

A canvas is a widget. The drawing is a separate declaration against that
widget, exactly as a table's header bar is a declaration against a For's
container. The guest writes what reads as immediate-mode drawing; what
actually happens is that the calls are recorded and one record is submitted
when the scope closes.

That fiction is already the house move, ratified in DESIGN.md's binding
conventions for the For template trace: "The body runs ONCE to trace the
template in every spelling; the loop is the fiction that reads as the intent."
Canvas reuses it wholesale, with a drawing scope instead of a loop.

The declaration is atomic and total: it replaces the whole drawing, never
patches it. This is set_column_headers' rule and its reasoning transfers
verbatim — one record for the whole thing "because the header's state is one
declaration ... and buys atomicity — no window where new titles show a stale
indicator." A half-updated chart is the same defect.

**There is no handler.** Pointer events on the canvas are deferred (ruling A),
so v1 has no occurrence, no callback, and none of the registry-versus-
declaration split that every other interactive surface needs. The
eight-language cost is a constructor and a drawing scope, and nothing else.

### §1.2 The spellings

Each is the language's own idiom for a scope, taken from the guest that
already exists beside it. `viewbox` is §2.2's coordinate declaration.

**Python** (ambient transaction; `with` scopes, keyword arguments) —
guests/python/portfolio.py is the app this lands in:

```python
chart = kaya.canvas(viewbox=(300, 120), grow=1, a11y_label="Portfolio value")

def redraw():
    with chart.draw() as d:
        for i in range(1, 4):
            d.move_to(0, i * 30).line_to(300, i * 30)
        d.stroke("separator", width=1)
        d.move_to(*points[0])
        for x, y in points[1:]:
            d.line_to(x, y)
        d.stroke("accent", width=2)
```

**Rust** (handle binding; closures, `Messages` registry) —
`tx.canvas(...)` returns a `Widget` whose `.id()` is the handle, and the
drawing scope takes `&mut Draw` the way `tx.row` takes `&mut Tx`:

```rust
let chart = tx.canvas(Viewbox(300.0, 120.0)).id();
tx.grow(chart, 1.0);
tx.draw(chart, |d| {
    d.move_to(0.0, 30.0).line_to(300.0, 30.0);
    d.stroke(Paint::Separator, 1.0);
    d.polyline(&points);
    d.stroke(Paint::Accent, 2.0);
});
```

**Go** (closure at the declaration, as `tx.Button("quarter", func(tx *kaya.Tx))`
already is):

```go
chart := tx.Canvas(kaya.Viewbox{W: 300, H: 120})
tx.Draw(chart, func(d *kaya.Draw) {
    d.MoveTo(0, 30).LineTo(300, 30)
    d.Stroke(kaya.PaintSeparator, 1)
})
```

**C#** (lambda, named arguments, as `tx.Button("quarter", onClick: ...)`):
`tx.Draw(chart, d => { d.MoveTo(0, 30).LineTo(300, 30); d.Stroke(Paint.Separator, width: 1); });`

**Java** (lambda over a one-shot scope, as `tx.column(() -> ...)`):
`tx.draw(chart, d -> { d.moveTo(0, 30).lineTo(300, 30); d.stroke(Paint.SEPARATOR, 1); });`

**Swift** (trailing closure, beside `tx.row { ... }`):
`tx.draw(chart) { d in d.moveTo(0, 30).lineTo(300, 30); d.stroke(.separator, width: 1) }`

**OCaml** (labelled arguments and combinators, as
`image ~source:test_png` and `button ~text:"quarter" ~on_click:...`):
`canvas ~viewbox:(300., 120.) ~draw:(fun d -> move_to d 0. 30.; line_to d 300. 30.; stroke d ~paint:Separator ~width:1.)`

**Haskell** (combinator over a list, as `row [imageBytes testPng, ...]`):
`canvas (Viewbox 300 120) [moveTo 0 30, lineTo 300 30, stroke Separator 1]` —
Haskell is the one binding where the op list is literally a list, which is
what the wire carries anyway.

**The C floor** stays fully explicit, as its documentation role requires
(invariant 5). No scope, no builder: guest-allocated ids, one generated
setter, and the op stream written out as the array it is, the same way
guests/c/gallery.c writes `kaya_tx_set_source` against a registered handle:

```c
#define W_CHART 7
KayaVal ops[] = {
    kaya_i64(KAYA_DRAW_MOVE_TO), kaya_f64(0),   kaya_f64(30),
    kaya_i64(KAYA_DRAW_LINE_TO), kaya_f64(300), kaya_f64(30),
    kaya_i64(KAYA_DRAW_STROKE),  kaya_i64(KAYA_PAINT_SEPARATOR), kaya_f64(1),
};
kaya_tx_create_widget(&tx, W_CHART, KAYA_KIND_CANVAS);
kaya_tx_set_drawing(&tx, W_CHART, 300.0, 120.0,
                    sizeof ops / sizeof *ops, 0, ops,
                    sizeof ops / sizeof *ops);
```

### §1.3 The sweep (invariant 2)

| language | verdict | note |
| --- | --- | --- |
| Rust | DO | closure scope, `Paint` enum |
| Python | DO | `with` scope, paint names as strings validated at record time |
| Go | DO | closure scope, `PaintX` constants |
| C# | DO | lambda, `Paint` enum, named `width:` |
| Java | DO | lambda, `Paint` enum |
| Swift | DO | trailing closure, `.separator` shorthand |
| OCaml | DO | labelled `~draw`, `Separator` constructor |
| Haskell | DO | op list, `Separator` constructor |
| C floor | DO | explicit array, generated setter, no scope |

No language cannot express this, so there is no carve-out to state. The
drawing scope is a value-recorder in every one of them, and every one already
has the scope construct it needs.

## §2 — the wire

### §2.1 The record

One new transaction record, on `set_column_headers`' pattern, which spec.rs
already blesses for exactly this problem: "A dedicated record and not a prop
because a prop carries ONE Value and titles are many ... the carrier is
highlight_ranges' count-plus-Values shape."

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

The `path_len`-keys-first convention is copied from set_column_headers
verbatim, and it is not decoration: it is what lets a canvas live inside a For
row template. `path_len 0` with a live widget id is the flat case;
`path_len 0` with a template node id declares the drawing for every stamped
copy; `path_len > 0` re-declares one copy's. A sparkline per row is that third
form, and check-sugar-surface will demand a canvas constructor in the template
zone whether or not this milestone ships a scene that uses it.

The op stream is a flat run of tagged values: an `i64` opcode followed by its
operands. Nothing here is a new field type, which is spec.rs's own standing
instruction: "New vocabulary should be new RECORDS over the existing types,
not new types — that is what keeps eight bindings mechanical."

### §2.2 Coordinates: the viewbox, and why it is the whole design

**This is the decision that makes a byte-shared canvas scene possible at all,
and it is worth stating before the op table.**

A canvas that draws in the device pixels of its assigned track produces a
different op stream on every platform, because every platform gives it a
different track. Invariant 6 would then have nothing to freeze: the scene
could not name a single coordinate.

So the guest declares a **viewbox** and draws in it. The backend maps viewbox
space onto whatever track layout assigns. The op stream is therefore identical
on every platform and in every language by construction, and the scene can
freeze it.

Three rules make that mapping well defined:

1. **The viewbox is also the natural size**, in device-independent points.
   `viewbox=(300, 120)` means a canvas that asks for 300x120 and scales when
   layout gives it more. This is SVG's rule, and it is the answer to a real
   gap: there is no width or height property on any widget in kaya today (the
   PROPS table's seventeen entries have no size among them; `width`/`height`
   are window properties). A canvas is the first widget whose content size is
   app-decided, and the viewbox supplies it without inventing a size property
   that thirteen other kinds would then have to answer for.
2. **Stretch to fill, not fit with letterboxing.** Evenly spaced things stay
   evenly spaced, which is what lets §5's axis labels sit outside the canvas
   as real widgets and still line up with the gridlines inside it.
3. **Positions scale; stroke widths do not.** A width is in
   device-independent points and is applied after the transform, so a 1pt
   gridline is 1pt at every size and a non-uniform stretch never produces an
   elliptical pen. All four rasterizers can do this: transform the geometry,
   stroke in device space.

A pleasant consequence: the canvas never needs to know its own size, so it
needs no resize occurrence, which is why ruling A's deferral of pointer and
geometry events costs nothing here.

### §2.3 The op vocabulary (v1)

Deliberately minimal, per ruling A. Five opcodes:

| op | operands | meaning |
| --- | --- | --- |
| `move_to` | `f64 x, f64 y` | start a subpath |
| `line_to` | `f64 x, f64 y` | extend it |
| `close` | none | close the current subpath |
| `stroke` | `i64 paint, f64 width` | stroke the built path, then clear it |
| `fill` | `i64 paint, i64 rule` | fill it (nonzero or even-odd), then clear it |

Path-then-paint is the shape all four targets natively have. §5 argues that
this is exactly a price chart's vocabulary and no more. §7 D4 is where the
maintainer decides whether it is too little.

**These five are not a guess at a minimum. They are the operations on which
the four rasterizers do not disagree**, and the exclusions below are each a
measured divergence rather than a scope preference (researched 2026-08-26,
§10 for URLs). Everything a richer vocabulary would add lands on one of these:

| excluded | why it is excluded, concretely |
| --- | --- |
| dashes | dash phase is measured in four different units: user space in SwiftUI, pixels in Compose, user space in cairo, and **units of stroke width** in Win2D |
| join and cap control | miter limit is the SVG ratio in three of them and **half the stroke thickness** in Win2D, a factor of two |
| blend modes | Win2D offers only four per-primitive blends; anything richer needs a command-list and effect round trip. Compose silently falls back to `SrcOver` below API 29 for non-Porter-Duff modes |
| gradients | interpolation colour space differs per backend and is per-shading opt-in on SwiftUI only. If gradients ever arrive they must be pre-sampled into many stops in one nominated space, not shipped as two stops |
| antialiasing control | Compose's `DrawScope` has **no** antialiasing switch at all; reaching one means leaving the portable API for `nativeCanvas` |
| curves | if they ever arrive they must be **cubic**: cairo has no quadratic Bézier, only `curve_to`. Quadratics elevate to cubics exactly, so the wire should carry cubics and nothing else |
| text | four shaping engines, and two different origins (Compose positions by top-left, cairo by baseline). See §5 |

Fill rule is the one thing that varies in *spelling* without varying in
*meaning*: nonzero and even-odd exist everywhere, sited on the draw call in
SwiftUI, on the `Path` in Compose, on the context in cairo, and on the
geometry in Win2D. Four spellings of one semantics is exactly the case
invariant 1 permits.

### §2.4 Paint is a closed vocabulary, not a colour word

Ops name a **paint role**, not RGB. The roles resolve per platform and per
appearance in the backend.

The tree already made this argument, for icons, in DESIGN.md: "Icons want
names, not bytes. The current `icon` prop is a Blob, and a blob is the wrong
primitive for a STANDARD icon ... The admission is a small closed set of
semantic names mapped per backend — the `role` trick again."

Three reasons it is the right answer here too, each already paid for in this
tree:

- **Dark mode.** A literal RGB series line is invisible in one appearance.
  This milestone's own base commit records the class: the dark-mode capture
  "caught an apron resolving its color outside the window it lived in". A
  drawing would be the largest such surface kaya has.
- **check-table-card already forbids literals** for the table card, demanding
  "its colours are the platform's own tokens rather than literals". A canvas
  drawing raw RGB would be that rule's biggest exception, admitted the same
  week it was written.
- **The core already derives the palette.** crates/kaya/src/brand.rs turns one
  seed into per-appearance fill / on_fill / standalone / hover / pressed as
  packed sRGB words, "computed here once so no backend re-derives". A canvas
  role is a lookup into work that is already done.

v1 roles: `accent` (the series), `separator` (gridlines and axes), and
`surface` (the plot ground). Literal RGB is the named escalation, admission
gated on an artifact, exactly as the blob follow-ups in docs/deferred.md are
("needs an artifact showing the register copy matters").

### §2.5 The core validates, and refuses before lowering

highlight_ranges' discipline transfers directly: the root refuses a malformed
declaration rather than letting four backends each answer differently. The
refusals: an unknown opcode, an opcode whose operands run off the end of the
stream, a non-finite coordinate, a paint role outside the vocabulary, a
non-positive or non-finite stroke width, a paint op with no path built, a
viewbox dimension that is not finite and positive, and a keyed target naming
no stamped copy.

This is also the argument against the packed-blob encoding in §7 D2: a blob is
opaque to the core by design, so every one of those refusals would move into
four backends and be answered four ways.

### §2.6 What it costs

| surface | cost |
| --- | --- |
| spec hash | moves once: kind 15 `canvas`, the `set_drawing` record, the `draw_op` and `paint` enums |
| generators | `set_drawing` reaches all 8 bindings mechanically; the drawing SCOPE is hand-written sugar over it, 8 times |
| interpreters | both private constant copies grow: the opcode numbers, the paint numbers, kind 15. This is check-symbol-parity's exact trap shape, one surface over |
| check-verbs | red until both interpreters carry every new verb |
| check-sugar-surface | red until `canvas` exists in all 8 bindings in BOTH zones (16 constructors); tools/tpl-surfaces.py reads its kind list from the generated wire file, so this goes red the moment the spec moves |
| check-universal-props | red until all four backends apply a11y_id/a11y_label to kind 15 |
| check-symbol-parity | wants a sibling clause: the opcode and paint numbers are copied by hand into Swift, Compose and the C floor, which is precisely the population that gate already exists to hold |

That last row is the honest cost of the Values encoding, and it is smaller
than the blob alternative's, where the whole *layout* rather than a dozen
constants would be hand-copied into eleven places.

## §3 — the backends

Four native surfaces, one replay routine each. The replay is a fold over the
op stream, so the four implementations are close to transcriptions of each
other, which is the property the Values encoding buys.

- **SwiftUI (macOS and iOS, one file).** SwiftUI `Canvas` with a
  `GraphicsContext`: build a `Path`, `context.stroke(path, with:, lineWidth:)`,
  `context.fill(path, with:, style:)`. Available since **macOS 12 / iOS 15**,
  identical API on both, which is comfortably below kaya's floor. One tier for
  both platforms: there is no size class in this widget's routing and no
  native-versus-synthesized split, so unlike the table it needs no tier gate.
  The `KayaRender` wrapper that check-universal-props holds unbypassed applies
  the a11y props above the Canvas, not inside it. Apple's own guidance points
  the same way as §5: "Use a canvas to improve performance for a drawing that
  doesn't primarily involve text".
- **Compose.** The `Canvas` composable and `DrawScope`: `Path`, `drawPath`
  with `Stroke(width)` or `Fill`, fill rule via `Path.fillType`. Ordinary
  `when (node.kind)` arm, threading the modifier that check-universal-props
  demands per arm.
- **GTK4.** `GtkDrawingArea` with a cairo draw function
  (`gtk_drawing_area_set_draw_func`): `cairo_move_to` / `cairo_line_to` /
  `cairo_close_path` / `cairo_set_line_width` / `cairo_stroke` /
  `cairo_fill` with `cairo_set_fill_rule` per op. Still first-class in GTK4 —
  the GTK blog's own words are "GtkDrawingArea is still a valid option if all
  you need is some self-contained cairo drawing", the only GTK3 change being
  the draw-func call instead of the `::draw` signal. The op vocabulary was
  chosen so that this arm is close to a one-to-one transcription. Two notes:
  the cost model is CPU rasterization plus a texture upload on every
  invalidation, mitigated by GSK's render-node caching, so a chart that
  redraws per tick is fine and a per-frame animation would want measuring;
  and GTK's hole in check-targets stands (gtk-sys needs the distro's
  pkg-config world), so tools/check-gtk.sh is the compile check after any
  gtk.rs change.
- **WinUI.** This is the one with a real dependency cost, and §3.1 is about it.

### §3.1 Windows: the Win2D question is bigger than "a new NuGet"

Ruling A says "WinUI needs Win2D CanvasControl — a new NuGet dependency and
packaging payload". The tree makes that concrete in a way worth stating before
anyone estimates this slice.

**The WinUI backend is not a C# project.** It is Rust: crates/kaya/Cargo.toml's
windows target block pulls `windows` and `windows-core` 0.62, and
crates/kaya/src/winui/bindings.rs is generated by `windows-bindgen` over WinRT
metadata. tools/fetch-winappsdk.sh is how that metadata arrives — it curls
`.nupkg` files from the NuGet flat container, extracts the `.winmd`, and
tools/winui-bindgen turns them into the committed bindings.

So "add Win2D" means, concretely: one more `fetch` line for
`Microsoft.Graphics.Win2D`, its `.winmd` fed through the bindgen into more
committed bindings, and the native `Microsoft.Graphics.Canvas.dll` staged
next to the process exe on the windows lane. That last part is the
pri-adjacency trap one file over (docs/traps.md), and it is
tools/check-staging.sh's business.

~~**And there is a gate hole in the way.** tools/check-pins.sh has four clauses:
gradle coordinates, NuGet via `<PackageReference>` in `.csproj`, opam in
tools/linux/Dockerfile, and SwiftPM's `Package.resolved`. It never reads
tools/fetch-winappsdk.sh. The Windows App SDK component versions in that
script are exact literals today, pinned by hand and guarded by nobody, and
Win2D would arrive through that same unguarded door. The three `.csproj` files
in the tree are guest-side and tooling, not the backend, so the existing NuGet
clause cannot reach this.~~

~~This proposal therefore owes check-pins a fifth clause before Win2D lands:
every NuGet flat-container fetch names a literal version.~~

**CLOSED 2026-08-26, and it grew a second half.** check-pins has the fifth
clause: every `fetch` in tools/fetch-winappsdk.sh names an exact version, and
a NEW tools/ script resolving from the same flat container is refused by name,
so the door cannot be re-opened next to the guard. The second half is what
reading the fetch script found — it verified NOTHING it downloaded. Each
package now records the sha256 of the `.nupkg` nuget.org serves beside its
version (each of the five cross-checked against nuget.org's published
packageHash), the script checks that hash on every run INCLUDING the cached
path, and the gate cuts `verify_sha256` out of the script and runs it against
wrong bytes on every sweep. Adding Win2D is now one `fetch` line with a
version and a hash; leaving the hash off fails the gate naming the package.
This was invariant 3's rule about where a guard sits — the wall belongs on the
path someone walks by adding a dependency, not in a runbook.

What is still unheld: `third_party/winappsdk/WindowsAppRuntimeInstall-arm64.exe`,
the 108 MB installer tools/deploy-win.sh's `--provision` arm copies to the VM.
No script fetches it and no package contains it — it was placed by hand, and
its provenance is recorded nowhere. Pinning it means deciding what it is first.

**And there is a version-skew risk specific to this tree, which should be
tested before anything is pinned.** Win2D's current stable is
`Microsoft.Graphics.Win2D` **1.4.0** (2026-03-16), and its NuGet dependency is
`Microsoft.WindowsAppSDK.WinUI >= 1.8.260204000` — the 1.8-era package. This
repo is on the 2.x components (`Microsoft.WindowsAppSDK.WinUI 2.2.1` and
friends, per tools/fetch-winappsdk.sh), and the Windows App SDK 2.0 release
notes do not mention Win2D at all. Whether Win2D 1.4.0 is supported against
WinAppSDK 2.x could not be established from documentation, and the project's
GitHub releases page is empty, so its changelog file is the only release
record. That is a compatibility question to answer with a build, in phase 3,
before a version goes in a fetch line. It is also a live argument for D5's
alternative.

Two smaller facts worth carrying: Win2D is implemented in C++, so a consuming
project must target a specific CPU architecture rather than "Any CPU" (moot
for a Rust backend, but it is why the package is not pure managed); and
Microsoft's `microsoft.github.io/Win2D` WinUI3 pages are **stale** — they still
describe `CanvasAnimatedControl` as unsupported, which the changelog
contradicts. Trust the changelog and Microsoft Learn over those pages.

**The alternative worth pricing** is not using Win2D at all. WinUI 3 can also
reach 2D drawing through the composition APIs the backend already links, which
would avoid the new package, the new bindgen output, and the staged native
DLL, at the cost of a less direct path from a path-and-stroke op list. §7 D5
puts this to the maintainer rather than assuming it, because it is the one
backend decision with a packaging consequence for every app kaya ever ships on
Windows.

### §3.2 Accessibility: a drawing is an image

The universal-props gate will demand an answer the day kind 15 exists, and
kaya already has the right one.

`a11y_id` and `a11y_label` are universal — every kind carries both — and
`expect_ax <target> "<role>/<name>"` reads them back off the platform's own
accessibility peer. The role set is closed and **already contains `image`**. A
drawing is an image to every platform's accessibility tree, so a canvas
normalizes to `image` and the app authors the spoken name. No new role, no new
verb, no vocabulary motion.

`a11y_hint` is correctly refused. It is admitted on activation kinds only
(button, checkbox, select, radio) because "a hint therefore needs an activation
to describe". A canvas has no activation while pointer events are deferred, so
the root refuses a hint on one. That is the right answer rather than a gap, and
it is one more thing that falls out of keeping pointer events deferred.

What kaya does NOT do is build a semantics tree out of the drawing. DESIGN.md
states the position already: "Custom-drawn frameworks pay a permanent tax
building semantics trees by hand; wrapping native widgets gets this for free."
A canvas is the one place an app opts out of that dividend, and the honest
contract is that it gets an image with a name.

The platform agrees, in Apple's own documentation for the exact API this
lowers to: "A canvas doesn't offer interactivity or accessibility for
individual elements, including for views that you pass in as symbols." So a
per-element semantics tree is not merely expensive here, it is not on offer.

§5's chart keeps its numbers in real labels for exactly this reason, so the
accessible version of the chart is the axis labels and the total beside it,
not a drawing nobody can read. That is not a consolation prize: it is a better
answer than the drawing would have been.

## §4 — the harness: what a scene may assert about a drawing

This is the hard problem the milestone turns on. Four rasterizers will not
agree on a pixel, so invariant 6 has to be satisfied by asserting something
that is genuinely the same everywhere while still being a real observation.
kaya has solved a structurally identical problem twice, and both answers apply.

### §4.1 The precedent that decides it

`expect_app_icon` compares **sampled pixels**, byte-for-byte, across all five
lanes. Its own words in crates/kaya/src/harness.rs: "FOUR SAMPLES, NOT A HASH:
one PNG goes in and each platform converts it (an HICON, an NSImage, a
GdkTexture), so a hash cannot be one frozen string across platforms while four
unmistakable colours can." And the discipline beside it: it is "read off the
artifact the shell will draw rather than echoed back from the declaration ...
the only read that fails when the conversion failed."

That is the canvas problem exactly: one declaration, five conversions, no
byte-identical artifact, but unmistakable colours survive. The move transfers.

The second precedent is `expect_shares`, which proves a numeric geometry
observation can be byte-compared if the arithmetic AND the rounding are
centralized: "Shared because the ROUNDING has to be identical everywhere, not
just the arithmetic: expect_shares compares byte-for-byte."

### §4.2 Two verbs

**`expect_drawing <target> "<ops>/<l>,<t>,<r>,<b>"`** — how many ops the
backend actually replayed, and the **ink bounding box** it produced,
normalized to hundredths of the canvas's own box and rounded by one shared
function the way `shares()` is. Normalized, so it is one frozen string though
every platform's pixel size differs.

What it catches: nothing arrived; the transform is wrong; the y axis is
inverted; the drawing sits in a corner of its track. That last one is not
hypothetical — it is the defect `expect_column_edges`' span half was invented
for, recorded in docs/tables-plan.md: "the content-hug cut kept every cluster
exactly right while leaving 90% of the viewport empty: alignment alone cannot
see it."

**`expect_ink <target> "<RRGGBB>/<RRGGBB>/..."`** — the colour at declared
normalized probe points, sampled from the backend's own rendered raster.
This is expect_app_icon's move and it is the verb that proves pixels were
actually drawn rather than an op list merely delivered.

**It inherits a measured discipline, and the discipline is the hard part.**
expect_app_icon works only because its source was engineered to survive four
rasterizers, and every one of those choices transfers:

- **Sample centres, never boundaries.** The existing comment's reason is that
  "whatever rescale a platform applies blurs a quadrant BOUNDARY". A canvas
  probe point must sit deep inside a flat-filled region.
- **Flat, unmistakable colours**, which is why
  guests/assets/icons/kaya-mark.png is four solid quadrants rather than a
  gradient. The canvas scene draws a coarse, high-contrast test figure for the
  same reason. The realistic chart is the portfolio's, and its looks are the
  captures' business.
- **Sample through a 16-bit context with `interpolationQuality = .none`, and
  round to 8 bits exactly once.** This is a measured finding, not a
  precaution: an 8-bit context quantizes twice and reported `1D71D8` for a
  declared `1C71D8` (2026-08-18, recorded at swift/KayaSwiftUI.swift:10221).
  A canvas ink read that skips this will be off by one somewhere and will look
  like a rasterizer bug.
- And because Compose's `DrawScope` has no antialiasing switch at all (§2.3),
  turning AA off to make edges exact is not available on every backend.
  Probe placement is the only lever, which makes the first rule
  non-negotiable rather than merely advisable.

Every backend has a route to the raster: `NSView.cacheDisplay` or SwiftUI's
`ImageRenderer` on Apple, `RenderTargetBitmap` on WinUI, a `GdkTexture` from
the widget paintable on GTK, and a bitmap draw or `PixelCopy` on Compose. Each
has caveats (WinUI's cannot render content outside the visual tree; a re-render
into a bitmap is not literally a read of the screen), and §7 D3 asks whether
that cost is wanted in v1 or deferred to captures.

### §4.3 What this does not prove, said plainly

The two verbs above prove the drawing arrived, that the transform put it where
it belongs, and that the intended colours reached the intended places. They
prove **nothing** about: line joins and caps, dash phase, antialiasing quality,
gradient interpolation, stroke-versus-fill of a path with the same bounds,
subpixel geometry, or whether the chart looks right to a person.

Nobody should be told otherwise, and a scene that implied otherwise would be
worse than none. The rest is held two ways, and both are established practice
here:

- **Per-platform captures, reviewed by a human.** The recording pipeline
  exists (`KAYA_RECORD=1`, per-step stills via tools/harness-extract.sh), it
  compares nothing automatically, and no lane capture is checked in. The
  styling milestone's answer is the model: run the probes per platform, write
  the report, land the report so code comments can cite it — see
  docs/styling/README.md, "frozen measurement reports". tools/scenes/styling.steps
  says the rule out loud: their look "has no AX-visible marker on SwiftUI, so
  the chrome is held by lowering-side gates and screenshots, not by a step
  pretending to read it", and "Its pixels are the captures' business."

  **This is not a fallback, it is currently kaya's best detector of look
  bugs**, and this app has the receipts. docs/portfolio-plan.md §5: "The first
  refreshed screenshots found what the model assertions did not (2026-08-23).
  GTK's flex measure summed unequal grower naturals before allocating equal
  tracks, so the first table overlapped its account total. macOS stretched the
  detail but not the new accounts For". Every scene assertion was green
  through both. A canvas milestone that does not budget a capture round on all
  five platforms is planning to ship the same class of defect.
- **A static gate over the four backends**, on tools/check-table-card.sh's
  model, which exists verbatim because "NO SCENE CAN FAIL THIS: the card is
  pixels, and every table observable ... answers identically with it gone".
  The canvas equivalent holds: every opcode has an arm in all four backends
  (no silent drop); paint resolves through the platform's tokens rather than
  literals; the stroke width is applied in device space after the transform
  (§2.2's rule 3, which no observable can see); and no backend panics on any
  op stream. Watched negatives with substitution counts printed, per
  invariant 3.

### §4.4 The negative tests

- The op stream perturbed so the y axis inverts, with `expect_drawing`
  watched going red on every lane.
- One opcode's arm deleted from one backend, watched red.
- The stroke width applied before the transform instead of after, which
  `expect_drawing` cannot see and the static gate must.
- A canvas whose drawing was never declared: present and empty, never absent.
  This is check-empty-child's rule, and it applies here for the same reason it
  applied to an undecodable image: "ONE NODE IS ONE WIDGET, even when its
  content will not decode", because a declarative backend that renders nothing
  takes the node out of the tree and every positional layout above it reads
  the wrong child.
- A malformed op stream refused by the core, so no backend ever sees one.

## §5 — the portfolio chart and the v1 vocabulary

The forcing artifact is a value-over-time chart above the portfolio total in
guests/python/portfolio.py. `tick()` already applies fixed per-ticker deltas
and recomputes the total, so a series appended there is deterministic and a
scene can freeze what it draws. That determinism is the app's own standing
discipline (docs/portfolio-plan.md §0: "every number in the scene is computed
from fixed inputs, so the byte-frozen scene stays honest").

**What a price-history line chart actually needs**, drawn out honestly:

| element | op | in v1? |
| --- | --- | --- |
| the price series | `move_to` + `line_to` run | yes |
| gridlines and axes | `move_to`/`line_to` pairs | yes |
| area fill under the series | `close` + `fill` | yes |
| tick labels (dates, dollars) | text | **no — see below** |
| smoothed curves | bezier | no |
| gradient fills | gradient | no |

**Text is deliberately out of v1, and the axis labels are real labels.**

This is the single largest scope call in the proposal and the argument for it
is strong. Putting text in the canvas means four shaping engines — Core Text,
HarfBuzz through Skia, HarfBuzz through Pango, and DirectWrite — producing four
different advance widths for the same string, at which point the ink-bounds
observable stops being byte-comparable and the whole §4 strategy weakens. It
is worse than a metrics difference: the four APIs do not even agree on where a
string is anchored, since Compose's `drawText` positions by top-left while
cairo's origin is the baseline. And on GTK the portable answer is not cairo at
all — cairo's own documentation calls its text API "a toy text API, for
testing and demonstration purposes. Any serious application should avoid
them", so shipping text there means PangoCairo, a fifth thing to keep level
with the other four.

Keeping the labels as ordinary kaya labels in the surrounding layout gets four
things at once: the numbers stay in the accessibility tree where a screen
reader can read them, kaya's existing typeface machinery already handles them,
the drawing vocabulary shrinks to pure geometry, and §4.2's assertions stay
clean.

It works because of §2.2's stretch rule: evenly spaced gridlines inside the
canvas stay aligned with an evenly spaced column of labels beside it at any
size. The chart is a small grid — a column of y labels, the canvas, a row of x
labels underneath.

Text in a canvas is the named escalation. It waits for an app that needs a
label at a position no widget can occupy, which a line chart is not.

The churn-is-free rule points the same way (no users, so migration cost is
zero and a wrong cut is cheap to widen): ship the vocabulary the artifact
forces, and let the next artifact force the next op. Five opcodes is not a
guess about what drawings need. It is exactly what this chart draws.

## §6 — sequencing

Depth then breadth, per CLAUDE.md, with the between-phase gates that are
supposed to stay red while half the work is outstanding.

1. **Protocol root.** kind 15, the `set_drawing` record, the opcode and paint
   enums, the core's validation and its refusals, and unit tests for every
   refusal watched failing first. The spec hash moves once, here, and
   everything regenerates in lockstep (invariant 7). At the end of this phase
   check-sugar-surface and check-universal-props are RED BY DESIGN, holding
   the sixteen constructors and the four lowering arms open.
2. **Mac depth.** The SwiftUI arm, the Rust binding's canvas plus drawing
   scope, the two harness verbs on the mac stage, and the canvas scene.
   validate-mac green. The other three backends carry `depth_stub("canvas")`
   so check-stubs and check-steps agree that those legs are not wired yet —
   between them those two gates state one rule, that a scene's legs are wired
   on a runner if and only if that runner's backend has the feature.
   check-verbs is RED here until both interpreters carry both verbs; the
   Compose half lands in phase 3.
3. **Breadth, in parallel worktrees.** GTK, WinUI (with §3.1's fetch line —
   version AND sha256, the clause is already there — bindgen output and
   staging), Compose, and the
   remaining seven bindings plus the C floor. Each lane green on the
   byte-shared scene. check-sugar-surface goes green when the sixteenth
   constructor lands, not before.
4. **The chart.** The portfolio app grows its canvas, the scene grows the
   assertions, and the captures are taken on all five platforms and reviewed.
   This is where the looks get ruled on, and where any second round of visual
   fixes belongs.
5. **The matrix.** tools/validate-all.sh, all five lanes, before this is
   called done.

Phases 1 and 2 are one worktree. Phase 3 is the fan-out the tables and
virtualization milestones both used.

### §6.1 One mechanical trap in the sequencing, worth knowing before phase 2

**There is no conditional syntax in a `.steps` file.** A scene cannot say "run
this leg only where the backend has canvas". Platform divergence is absorbed
four ways only: a verb's bare invariant form, check-steps' width-band lints,
designing the observable so the tiers agree (tables decision 5 took the size
class out of every table observable on purpose), and the whole-scene
`depth_stub` mechanism.

That last one is keyed on a scene's **verbs**, through
tools/lib/scene-features.py's `VERB_FEATURE` table, with a fallback to the
scene's **name**. A scene called `canvas.steps` would derive the feature
`canvas` from its name alone, so phase 2's own scene needs nothing. **The
portfolio chart is the case that does.** Once `expect_drawing` appears in
`tools/scenes/portfolio.steps`, the feature can no longer be derived from that
scene's name, and without `VERB_FEATURE` entries mapping the canvas verbs to
`canvas`, a backend still declaring `depth_stub("canvas")` cannot hold the
portfolio legs off. The table's own comment says exactly why it is keyed this
way: "the day another scene demands the same lowering without being called
after it, a backend still declaring the depth stub must hold those legs off
too."

So both new verbs get `VERB_FEATURE` entries in phase 1, before any scene
uses them. It is two lines, and finding this out in phase 4 instead would mean
a deadlock between check-steps and check-stubs with the chart already written.

## §7 — THE DECISION MENU

Five genuinely open calls. Each states the question in plain words, gives a
recommendation and the reasoning, and prices the alternative.

### D1. What does a canvas send: drawing commands, or Vello's format?

**The question.** Two prior rulings answer this differently (§0). DESIGN.md
says display lists adopt Vello's scene encoding; the 2026-07-22 canvas ruling
says the widget sends a minimal op set. Which one governs the widget?

**Recommendation: the minimal op set, and split the Vello question off.** The
canvas widget sends drawing commands kaya defines. DESIGN.md's open question #3
stays open and is re-filed against the pixel-surface arm, which is the feature
it was actually written about.

**Why.** Three reasons, and the third is decisive on its own.

1. Sending Vello's encoding means eight bindings hand-writing that layout and
   four backends decoding it to replay into APIs that want `move_to` and
   `stroke`. The zero-copy benefit only exists if kaya rasterizes with Vello
   and hands the platform finished pixels, which contradicts wrapping native
   widgets.
2. It imports a fast-moving 0.x format into a wire that eight languages must
   agree on forever.
3. **The format is not on offer.** Vello calls itself alpha; the encoding's
   only stability statement is a 2023 roadmap saying "it's also too early to
   freeze the format"; `Encoding` is twelve parallel `Vec`s with no `repr(C)`
   and no `serde`, so there is no byte layout to adopt in the first place; it
   breaks at minor versions; and nobody has ever shipped it as an interchange
   format. The one serious FFI binding wrapped scene-*building* calls instead
   and is archived awaiting a final API.

**The alternative** is to honour DESIGN.md literally and build the canvas on
Vello. It buys a real path to a GPU-accelerated future and one format for both
arms. It costs the four native lowerings this milestone is otherwise made of,
it makes the drawing opaque to the core (forfeiting §2.5's refusals), and per
(3) it means tracking an unfrozen format by hand in eight languages.

**A middle option, if the maintainer wants Linebender vocabulary without the
encoding:** kurbo and peniko — the shape, transform, stroke and brush types
Vello is built on — do have first-class `serde`, are far more settled in
practice, and are what a stable interchange would be built from. That is a
different proposal from "adopt the scene encoding" and would still need
kaya's own op stream on the wire; it would change what the op stream is
*named after*, not what it is.

**If the answer is D1-alternative, most of this document is wrong** and should
be rewritten before anything is built.

### D2. How is the op stream carried: tagged values, or packed bytes?

**The question.** The op stream can ride a `Values` run (the shape
highlight_ranges and set_column_headers already use) or a packed byte buffer
through the blob channel (the shape the Image widget's `source` uses).

**Recommendation: the Values run.** Packed bytes are the named escalation,
admission gated on a measured artifact.

**Why.** The generator does the eight-language work for a Values run and none
of it for a blob. The core can validate op by op and refuse loudly, which a
blob forfeits by design. And a hand-written binary layout in eight bindings
plus a decoder in the core plus two interpreter copies is precisely the trap
check-file-modes and check-symbol-parity exist to police — kaya has been bitten
by hand-copied numbers twice.

**The cost of the recommendation, stated:** each value occupies 16 bytes, so a
60-point series is about 3 KB. That is nothing for a chart and would matter for
a 100,000-point scientific plot. The escalation trigger is exactly that: an
artifact where the encoding cost is measured, not assumed.

### D3. What may a scene assert about a drawing?

**The question.** Pixel equality across four rasterizers is impossible. So what
does the byte-shared scene say, and how much of "does it look right" is bought
by gates versus by a person looking?

**Recommendation: both verbs in §4.2 (structure and sampled ink), plus
captures and a static gate — and say plainly what is not proved.**

**Why.** `expect_drawing` alone proves delivery and placement but would pass
with every colour wrong and nothing rasterized. `expect_ink` is what makes the
scene fail when the drawing did not actually happen, and expect_app_icon
already proves the technique works on five lanes. The residue is genuinely
unassertable and gets §4.3's two honest instruments.

**The alternative** is `expect_drawing` only in v1, with all colour work
deferred to captures. It saves four raster-sampling implementations. It costs
the one assertion that fails when rasterization silently does nothing, which is
the failure a canvas is most likely to have.

**A sub-question the maintainer may want to rule separately:** whether
`expect_ink` samples a re-render into a bitmap (portable, four routes exist) or
the real presented surface (stronger, and much harder on at least two
platforms).

### D4. How small is the v1 drawing vocabulary — and is text in or out?

**The question.** Five opcodes and no text, with axis labels as real widgets
beside the canvas. Or a wider vocabulary now.

**Recommendation: five opcodes, no text, labels as widgets** (§5).

**Why.** It is exactly what a price-history chart draws; the labels stay
accessible and typographically correct; and the byte-shared assertion stays
strong because no text shaping enters the observable. Churn is free, so the
narrow cut is cheap to widen and the wide cut is not cheap to narrow.

**The alternative** is text in v1. It makes a chart self-contained and is what
every other drawing API offers. It costs four shaping engines in the
observable, a weaker §4 story, and a genuine risk that the first canvas scene
is unfreezable on some lane.

**A second sub-question:** whether Bézier curves join v1. Recommendation no —
the chart is a polyline, and a curve is the clearest example of the slippery
slope ruling A warned about. If they are ruled in, they must be **cubic only**:
cairo has no quadratic Bézier at all, and quadratics elevate to cubics exactly,
so the wire should never carry a quadratic.

**Note what D4 is NOT choosing between.** The five ops are the operations all
four rasterizers agree on. §2.3's table shows that the next ones out —
dashes, joins, blends, gradients, antialiasing control — each diverge in a
measured way, so widening the vocabulary is not "more of the same". Each
addition buys a per-backend reconciliation and a weaker byte-shared
assertion, and should be admitted one artifact at a time.

### D5. On Windows: Win2D, or the composition APIs already linked?

**The question.** Ruling A names Win2D. It means a new NuGet fetch, more
generated bindings and a native DLL staged beside every Windows app. WinUI 3
can also reach 2D drawing through composition APIs the backend already links.

**Recommendation: prototype both in phase 3 and decide on the measurement.**
The check-pins half of this is already done (§3.1, landed 2026-08-26 ahead of
any ruling, since the gate could not see tools/fetch-winappsdk.sh whether or
not Win2D ever lands): a Win2D fetch line now costs a version and a sha256,
and the gate refuses it without both.

**Why not just pick one now:** this is the only backend decision with a
permanent consequence for every app kaya ships on Windows — a native
dependency in the payload — and it should be bought with a measurement rather
than with a preference. Win2D is the direct path from a path-and-stroke op
list. Composition avoids the payload entirely and keeps the packaging story as
it is today.

**And there is now a specific thing to measure first** (§3.1): Win2D 1.4.0
depends on the 1.8-era `Microsoft.WindowsAppSDK.WinUI`, this tree is on the
2.x components, and no documentation states whether that combination is
supported. If it is not, D5 is decided for us until Win2D ships a 2.x build,
and phase 3's Windows slice takes the composition route or waits. That is a
one-afternoon build test and it should happen before phase 3 is scheduled, not
during it.

**A third option worth naming:** Win2D can be used *without* its built-in
controls, drawing into a composition surface directly. That keeps the direct
Direct2D path while changing what has to be staged, and it is the shape to
try if the control is the part that fights the packaging.

### D6 (smaller, but it is a ruling). Is the drawing undoable?

**Recommendation: no**, on set_column_headers' reasoning — "the header bar is
not state, and the order underneath it already rides collection_move's undo
run". A drawing is a rendering of app state, not state. The state it renders
is undoable already, and the redraw follows it.

## §8 — what was considered and rejected, so nobody re-litigates

- **Callback-per-frame immediate mode.** Rejected by ruling A already
  ("8-language FFI churn, divergent frame timing"), and this proposal does not
  reopen it. The recording scope gives guests the immediate-mode *spelling*
  without the callback.
- **Vello's scene encoding as the widget's wire format.** See D1 and §0.
- **An SVG path string as the payload.** Compact and familiar, but it is a
  second grammar nobody asked for, it is stringly typed, and the core's
  refusals would become a parser. The op stream is the same information with
  the validation already structural.
- **A width/height property on widgets, so a canvas can declare its size.**
  Rejected in favour of the viewbox, which supplies the natural size as a side
  effect and does not oblige thirteen other kinds to answer for a property
  they do not want.
- **A resize occurrence so the guest can redraw at the true size.** Unnecessary
  under §2.2, and it would make the op stream platform-dependent, which is the
  one thing invariant 6 cannot survive.
- **Text in the canvas for axis labels.** See D4 and §5.
- **Building a semantics tree from the drawing.** kaya's whole accessibility
  dividend comes from native widgets being the tree. A canvas is where an app
  opts out, and the honest contract is an image with an authored name (§3.2).
- **Reading the drawing back out of the core's model as the observable.**
  Forbidden by the doctrine that governs every other read: "Reading kaya's
  model would make the scene agree with itself and prove nothing."

## §9 — sources

Researched 2026-08-26. Every claim in §2.3, §3 and §7 D1/D5 that is about a
platform rather than about this tree traces to one of these.

**Vello and the Linebender stack**
- https://github.com/linebender/vello — the "alpha state" statement
- https://github.com/linebender/vello/blob/main/doc/roadmap_2023.md — "too early to freeze the format"; still the project's position
- https://docs.rs/vello_encoding/latest/vello_encoding/struct.Encoding.html — the twelve parallel `Vec` fields
- https://docs.rs/crate/vello_encoding/latest/features — one feature flag, no serde
- https://github.com/linebender/vello/blob/main/CHANGELOG.md — the 0.9.0 `GlyphRun` breaking changes
- https://crates.io/crates/vello_encoding/reverse_dependencies — no third-party consumers
- https://github.com/wieslawsoltes/VelloSharp — archived, wrapped scene-building calls, not the encoding
- https://crates.io/crates/kurbo and https://crates.io/crates/peniko — the serde-capable alternative in D1

**Win2D and the Windows App SDK**
- https://www.nuget.org/packages/Microsoft.Graphics.Win2D — 1.4.0, 2026-03-16
- https://github.com/microsoft/Win2D/blob/winappsdk/main/CHANGELOG.md — the WinAppSDK 1.8 dependency; also the only release record, since https://github.com/microsoft/Win2D/releases is empty
- https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/release-notes/windows-app-sdk-2-0 — silent on Win2D
- https://learn.microsoft.com/en-us/windows/apps/develop/win2d/quick-start — the architecture requirement
- https://learn.microsoft.com/en-us/windows/apps/develop/win2d/using-win2d-without-built-in-controls — D5's third option
- https://microsoft.github.io/Win2D/WinUI3/html/T_Microsoft_Graphics_Canvas_CanvasBlend.htm — the four per-primitive blends

**SwiftUI Canvas**
- https://developer.apple.com/documentation/swiftui/canvas — availability, and the accessibility and text guidance quoted in §3.2 and §3
- https://developer.apple.com/documentation/swiftui/graphicscontext — the operation set
- https://developer.apple.com/documentation/swiftui/strokestyle and https://developer.apple.com/documentation/swiftui/fillstyle — dash phase, miter limit, even-odd

**Compose DrawScope**
- https://developer.android.com/reference/kotlin/androidx/compose/ui/graphics/drawscope/DrawScope — the operation set, and the absence of an antialiasing parameter
- https://developer.android.com/develop/ui/compose/graphics/draw/overview — transforms and clipping
- https://android-developers.googleblog.com/2023/08/whats-new-in-jetpack-compose-august-23-release.html — `drawText` stabilized in 1.5

**GTK4 and cairo**
- https://blog.gtk.org/2020/04/24/custom-widgets-in-gtk-4-drawing/ — "GtkDrawingArea is still a valid option"
- https://docs.gtk.org/gtk4/class.DrawingArea.html and https://docs.gtk.org/gtk4/drawing-model.html — the draw func, and render-node caching
- https://www.cairographics.org/manual/cairo-cairo-t.html — dash units in user space, fill rule on the context, no quadratic curve
- https://www.cairographics.org/manual/cairo-text.html — "a toy text API ... Any serious application should avoid them"

## §10 — the ledger, when this is ratified

Nothing in docs/deferred.md is struck by a draft. On ratification, the Canvas
widget entry gets its resolution note and a `KEY:` line naming the nouns a
closing sweep will have to find (canvas, draw list, display list, Win2D,
viewbox, paint role). Open question #3 in DESIGN.md does **not** close — under
D1 it is re-filed against the surface-handle arm, and the Canvas entry's
sentence about it is what needs rewriting, not striking.
