# Platform layout survey

Reference for the layout-normalization decision. kaya uses **native
widgets**, so the platform's own expression already lives in the leaves
(intrinsic sizes, control chrome, text metrics). The question this survey
answers is: at the *arrangement* layer, what does each of the seven
backends offer to lower onto — and which of those capabilities are
portable enough to normalize, which need a per-backend container swap,
and which are idiomatic-only (escape-hatch territory)?

Status: working reference, uncommitted, drafted 2026-07-19. The "kaya
today" facts are grounded in the source; the native-toolkit inventories
are from the toolkit docs/knowledge and want a second pass from Akhil,
who implemented all seven backends.

## What kaya lowers to today (and the magic numbers to strip)

Every backend already renders `row`/`column` as its native linear-stack
container. None of the layout *props* exist yet — the only vocabulary is
the axis (encoded as the widget kind). But several backends bake in
hand-tuned constants to look presentable, and they disagree:

| Backend | Container today | Baked-in ad-hoc value | True native default |
|---|---|---|---|
| AppKit (`appkit.rs`) | `NSStackView` V/H | none set explicitly (uses NSStackView default) | NSStackView `spacing` ≈ system metric |
| UIKit (`uikit.rs`) | `UIStackView` V/H | none set explicitly (AUDIT) | UIStackView `spacing` 0 |
| GTK (`gtk.rs`) | `gtk4::Box` | **`spacing 8`** | 0 |
| WinUI (`winui/`) | `StackPanel` | none set explicitly (AUDIT) | `Spacing` 0 |
| Android (`android.rs`) | `LinearLayout` | **`Gravity.CENTER` (17)** | `Gravity.TOP\|START` |
| SwiftUI interp (`KayaSwiftUI.swift`) | `VStack`/`HStack` | **`spacing: 8`** | `nil` (context-dependent system default) |
| Compose interp (`KayaCompose.kt`) | `Column`/`Row` | **`spacedBy(8.dp, Center)` + `CenterHorizontally`; a second row at `spacedBy(4.dp)`** | no arrangement spacing; `Top`/`Start` |

**Strip list for the first pass** (audited 2026-07-19 — six of nine
surfaces carry ad-hoc constants; only WinUI is clean). Strip spacing and
cross-axis alignment/gravity; **keep** the axis (orientation/axis is the
semantic content of row vs column, not a magic number):

| Surface | Strip | Keep |
|---|---|---|
| AppKit `appkit.rs:124-133` | `setSpacing(8.0)` ×2, `setAlignment(CenterX/CenterY)` ×2 | `setOrientation` |
| UIKit `uikit.rs:151-189` | `setSpacing(8.0)` ×2, `setAlignment(.Center)` ×2 (Column/Row; the checkbox composite stack keeps its spacing — leaf construction) | `setAxis` |
| GTK `gtk.rs:123-132` | `Box::new(_, 8)` → `Box::new(_, 0)`, **and** `set_valign(Center)` + `set_halign(Center)` ×2 (missed by the grep; caught by reading source) | orientation arg |
| Android `android.rs:352` | `Gravity.CENTER` (17) | `setOrientation` |
| SwiftUI interp `KayaSwiftUI.swift:464,474` | `spacing: 8` ×2 → default | VStack/HStack |
| Compose interp `KayaCompose.kt:478-501` | `spacedBy(8.dp,Center)`, `CenterHorizontally`, `spacedBy(4.dp)` + alignments → defaults | Row/Column |
| WinUI `winui/mod.rs` | — (already clean) | `SetOrientation` |

Two notes on what stripping reveals: (a) NSStackView's default spacing
is already ~8, so stripping AppKit's explicit `8.0` is a visual no-op,
while UIKit/GTK default to 0 and visibly tighten. (b) The `Center`
alignments were *guesses at non-default*; the mac render corrected that
(see Observed baseline) — **AppKit NSStackView already centers cross-axis
by default**, so stripping `CenterX` changed nothing there; UIStackView
and GTK are the ones whose defaults differ (fill / start). The baseline
getting *uglier* in places is the data, not a regression.

## Observed baseline (2026-07-19)

The `layout` scene rendered on all seven backends at native defaults,
post-strip (side-by-side artifact assembled separately). No two backends
agree on a single axis:

| Backend | Window | V-spacing | Cross-axis | Slider |
|---|---|---|---|---|
| AppKit | fits content | ≈8 pt | center | fills |
| SwiftUI | fills, centers content | tight | center | part-fill |
| UIKit | fills, jams to bottom | 0 (fill stretches one child) | left / fill | fills |
| GTK 4 | fits content | 0 | labels center, controls left | fills |
| WinUI 3 | large fixed | 0 | left | **hugs** |
| Android Views | top-jams | 0 | left (baseline-aligned rows) | hugs (stub) |
| Android Compose | centers as a band | 0 | left (top-aligned rows) | fills |

Findings that steer normalization:

1. **Zero spacing is illegible, not just plain.** Five of seven default
   to 0 inter-child spacing; on UIKit/WinUI adjacent labels touch
   ("checkmixed", "longertail"). A nonzero spacing default is the
   cheapest, highest-value normalization.
2. **Free-space / window behavior is the deepest divergence** — six
   distinct answers (stretch-one-child, fit-to-content, fill-and-center,
   large-fixed, top-jam, center-as-a-band). UIKit's `distribution=.fill`
   is the worst: it balloons one label and crushes the rest. This
   matters more than any single alignment knob, and folds the window
   milestone's sizing question into the layout story earlier than
   planned.
3. **Cross-axis splits three ways** (center / leading / labels-center-
   controls-leading). A single default here buys coherence cheaply.
4. **Same-vendor divergence is real:** AppKit vs UIKit — one OS family —
   go from a tidy centered card to a near-broken screen. Native defaults
   alone are not viable.
5. **The leaves rightly stay native:** Material pill buttons (Compose)
   vs bordered rects (AppKit) vs blue tap-text (UIKit) is the per-platform
   expression we want. Normalization is for arrangement, never widgets.

Two minor bugs surfaced: GTK spawns a phantom 1×1 top-level window
alongside the real one; Android Views draws behind the activity action
bar (activity chrome, not the layout backend). Both noted for later.

## The capability axes that matter for normalization

1. **Linear stack** — a main axis + children in order.
2. **Inter-child spacing** — a gap between adjacent children.
3. **Main-axis grow** — how leftover main-axis space is distributed
   (flex weight).
4. **Cross-axis alignment** — leading / center / trailing / stretch.
5. **Baseline alignment** — align children on a text baseline.
6. **2D grid** — rows × columns with fixed / auto / proportional sizing.
7. **Overlay / z-stack** — layered children.
8. **Absolute positioning** — explicit coordinates.
9. **General constraint / custom layout** — the arbitrary-relations
   escape hatch.
10. **Wrap / flow** — reflowing runs.

## Per-platform native inventory

### AppKit (macOS)
- **NSStackView** — linear. `orientation`, `spacing`, `distribution`
  (fill / fillEqually / fillProportionally / equalSpacing /
  equalCentering / gravityAreas), `alignment` (cross-axis via
  NSLayoutAttribute). Grow = per-view hugging / compression-resistance
  priorities under `distribution=.fill`; three gravity areas
  (leading/center/trailing).
- **NSGridView** — 2D grid: per-cell placement + alignment, column
  width (fixed/auto), row/column merging, spacing.
- **Auto Layout (NSLayoutConstraint / anchors)** — general constraints,
  priorities. The escape hatch.
- **Autoresizing masks (springs & struts)** — legacy manual model.
- **NSSplitView** (panes), **NSScrollView** (scroll), `setFrame`
  (absolute).

### UIKit (iOS)
- **UIStackView** — linear. `axis`, `spacing`, `distribution` (fill /
  fillEqually / fillProportionally / equalSpacing / equalCentering),
  `alignment` (fill / leading / center / trailing / firstBaseline /
  lastBaseline), per-child `setCustomSpacing(_:after:)`,
  layout-margins-relative arrangement. Grow = distribution + hugging.
- **Auto Layout** — general constraints (same engine as AppKit).
- **UICollectionView + Compositional Layout** — sections / groups /
  items with fractional / absolute / estimated dimensions; the
  virtualized list-grid-flow engine.
- Manual frames (absolute), **UIScrollView**.

### GTK4
GTK4 delegates layout to **layout managers** (`GtkLayoutManager`); the
widget is the container, the manager is the algorithm.
- **GtkBox / GtkBoxLayout** — linear. `orientation`, `spacing`,
  `homogeneous`; grow via per-child `hexpand`/`vexpand`; cross-axis via
  per-child `halign`/`valign` (fill/start/center/end/baseline); baseline
  position.
- **GtkGrid / GtkGridLayout** — 2D: attach at col/row + span, per-child
  expand/align, row/column homogeneous + spacing.
- **GtkCenterBox** — start/center/end three-slot.
- **GtkConstraintLayout** — constraint system (VFL-like). Escape hatch.
- **GtkFixed** (absolute), **GtkOverlay** (z-layer), **GtkFlowBox**
  (wrap), **GtkPaned** (panes), **GtkScrolledWindow**.
- Every widget carries `margin-*`, `halign`/`valign`, `hexpand`/`vexpand`
  regardless of parent — GTK's per-widget layout properties.

### WinUI 3 (Windows)
- **StackPanel** — linear. `Orientation`, `Spacing`. **No main-axis
  grow** — children get desired size along the stack axis; cross-axis
  stretch via `HorizontalAlignment`/`VerticalAlignment=Stretch`.
- **Grid** — the workhorse. RowDefinitions / ColumnDefinitions with
  **star (`*`), Auto, and fixed** sizing; star-sizing *is* proportional
  grow (flex weight equivalent). `Grid.Row/Column/RowSpan/ColumnSpan`.
  **This is what you swap StackPanel to when you need grow.**
- **RelativePanel** — relative positioning (align / rightOf / below).
- **Canvas** — absolute (Left/Top attached props).
- **VariableSizedWrapGrid** — built-in wrap grid.
- **ItemsRepeater + Layout** (StackLayout / UniformGridLayout / custom
  `VirtualizingLayout`) — virtualized list/grid.
- Per-element: `Margin`, `Padding`, alignment, Width/Height/Min/Max.

### Android Views
- **LinearLayout** — linear. `orientation`; grow via per-child
  **`layout_weight`** (proportional main-axis distribution); cross-axis
  via container `gravity` + per-child `layout_gravity`. **No native
  inter-child spacing** — you use per-child margins or a
  `divider`/`showDividers` drawable. (This is why the current code
  reached for `Gravity.CENTER` — it's papering over the missing model.)
- **ConstraintLayout** — flat constraint system; chains give
  distribution, plus guidelines / barriers. General escape hatch.
- **RelativeLayout** (relative), **FrameLayout** (overlay/z-stack via
  gravity), **GridLayout** (2D), **TableLayout** (rows/cols),
  **CoordinatorLayout** (scroll behaviors).
- **FlexboxLayout** — real flexbox, but a Google *library*, not the
  framework.

### SwiftUI (interpreter backend)
- **HStack / VStack** — linear. `spacing:` (`nil` = context-dependent
  system default), `alignment:` (leading/center/trailing/top/bottom/
  firstTextBaseline/lastTextBaseline). **No weight primitive** — grow is
  `.frame(maxWidth: .infinity)` + `.layoutPriority`, or `Spacer`.
- **ZStack** — overlay/z-layer with alignment.
- **Spacer** — flexible space (the idiom for push/distribute).
- **Grid / GridRow** (iOS 16+) — true 2D grid with per-cell alignment.
- **LazyVGrid / LazyHGrid** (`GridItem`: fixed / flexible / adaptive) —
  virtualized grids.
- **Layout protocol** (iOS 16+) — custom containers; the general escape
  hatch. **`.alignmentGuide`**, **GeometryReader** (measure),
  **.overlay/.background** (layered), **.padding**.

### Jetpack Compose (interpreter backend)
- **Row / Column** — linear. `horizontalArrangement`/
  `verticalArrangement` (`spacedBy(dp, alignment)` / SpaceBetween /
  SpaceAround / SpaceEvenly / Center / Start / End — **spacing lives in
  Arrangement, which also carries a main-axis alignment**); cross-axis
  via `verticalAlignment`/`horizontalAlignment`. Grow via per-child
  **`Modifier.weight(f, fill)`** (flex weight).
- **Box** — overlay/z-stack (`contentAlignment` + per-child
  `Modifier.align`).
- **Spacer** (space via Modifier), **ConstraintLayout** (compose lib;
  constraints/chains), **Lazy{Column,Row,VerticalGrid,HorizontalGrid}**
  (virtualized), **BoxWithConstraints** (measure), **`Layout {}`** /
  custom `MeasurePolicy` (general escape hatch), `Modifier.padding`,
  `fillMax*`.

## Cross-platform normalization matrix

| Capability | AppKit | UIKit | GTK4 | WinUI | Android | SwiftUI | Compose | Portability verdict |
|---|---|---|---|---|---|---|---|---|
| **Linear stack + axis** | NSStackView | UIStackView | GtkBox | StackPanel | LinearLayout | H/VStack | Row/Column | **Universal** — 1:1 everywhere. This is what we have. |
| **Inter-child spacing** | spacing | spacing | spacing | Spacing | ✗ margins/divider | spacing: | Arrangement.spacedBy | **Near-universal, one seam** — Android has no spacing property; synthesize via margins. |
| **Main-axis grow** | hugging + fill | distribution + hugging | hexpand | ✗ → Grid star | layout_weight | maxWidth:∞ + priority | Modifier.weight | **Semantics portable, mechanism divergent** — WinUI swaps StackPanel→Grid; SwiftUI has no weight. |
| **Cross-axis align (4 modes)** | alignment | alignment | halign/valign | H/V-Alignment | gravity | alignment: | h/vAlignment | **Universal** for leading/center/trailing/stretch. |
| **Baseline align** | firstBaseline | firstBaseline | baseline pos | ✗ weak | firstTextBaseline | firstTextBaseline | limited | **Partial** — WinUI weak; defer. |
| **2D grid (star/auto/fixed)** | NSGridView | CollectionView | GtkGrid | Grid ✓✓ | GridLayout | Grid (16+) | ConstraintLayout | **Everywhere but uneven** — own milestone. |
| **Overlay / z-stack** | constraints | manual | GtkOverlay | Grid/Canvas | FrameLayout | ZStack | Box | **Universal-ish** — Portal territory. |
| **Absolute** | setFrame | frames | GtkFixed | Canvas | absolute | offset | offset | Anti-idiom; escape hatch only. |
| **General constraint / custom** | Auto Layout | Auto Layout | GtkConstraintLayout | RelativePanel | ConstraintLayout | Layout protocol | MeasurePolicy | **Universal escape hatch** — every platform has one. |
| **Wrap / flow** | ✗ | CollectionView | GtkFlowBox | VarSizedWrapGrid | FlexboxLayout (lib) | ✗ | FlowRow (lib) | **Partial/uneven** — not a first-pass concern. |

## The spacing unit: pass-through of the platform-logical unit

We do not invent a unit — every platform already exposes a
device-independent logical unit, and native layout code is written in it
(not in physical pixels). kaya's layout unit is defined as *one
platform-logical unit*, and the scalar is passed straight through
unconverted; the OS handles physical-pixel scaling underneath.

| Platform | Logical unit | Physical scaling by |
|---|---|---|
| Android / Compose | **dp** | density bucket (÷ dpi/160) |
| iOS·UIKit / SwiftUI | **pt** | @1x/@2x/@3x |
| macOS·AppKit | **pt** | backingScaleFactor |
| Windows·WinUI | **effective pixel / DIP** | system scale (100–200%) |
| GTK4 | **logical px** | integer scale-factor |

`spacing 8` → `8dp` / `8pt` / `8 DIP` / `8 logical px`. This is what
React Native (unitless = dp on Android, pt on iOS) and Flutter (logical
pixels) do.

Two things to know:

1. **The logical units are not the same physical size across platforms.**
   They cluster into two families split by *viewing distance*: mobile
   (Android dp, iOS pt) anchors near ~160 dpi; desktop-ish (Windows DIP,
   GTK logical px, macOS pt in practice) anchors near ~96 dpi. So kaya-`N`
   renders a bit larger on desktop than on a phone — which is correct:
   each platform already sized its reference unit for its form factor,
   and pass-through inherits that calibration. Physical-inch
   normalization would defeat it (cramped desktop or oversized mobile).
   (Exact inch conversions are device-varying — especially Apple/macOS
   points — so the accurate claim is the two-families-by-viewing-distance
   shape, not a precise ratio.)
2. **Pass-through is idiom-aligned, not just pragmatic.** Both Material
   (8dp grid) and Apple HIG (8pt rhythm) use an 8-unit base grid, so a
   kaya `8` lands *on each platform's native spacing grid*. Physical
   normalization would knock it off-grid on one side.

Honest characterization of what ships: kaya-`N` is **density-independent
within a platform, idiom-aligned across platforms** — not pixel-identical
across platforms. That is the intended line: the number is predictable
and portable; the physical rendering is each platform's own.

Deferred: **text unit ≠ layout unit** — Android splits `dp` (layout)
from `sp` (text, respecting the user font-scale setting); the unit story
forks when a font-size prop lands (none exists today). Fractional-scaling
edge cases (GTK4 is integer-scale-only) are the compositor's problem, not
the protocol's.

## What this means for the first pass and beyond

1. **The linear stack is genuinely universal.** row/column with a main
   axis lowers 1:1 to a native stack container on all seven. The
   native-default baseline is well-defined and honest to observe once
   the magic numbers are stripped — this validates the "lower to native
   default and see" approach directly.
2. **Spacing's one seam is Android.** Every other platform has a
   first-class spacing scalar; LinearLayout has none. So even the first
   prop we might add is mechanism-divergent (Android = per-child
   margins). Worth knowing before we design `spacing`.
3. **Grow is semantically portable, mechanically divergent.** Flex-grow
   is expressible everywhere, but WinUI needs a StackPanel→Grid swap and
   SwiftUI has no weight primitive (maxWidth:∞ + priority). If/when
   `grow` lands, it's a "normalize the semantics, each backend realizes
   its own way, one backend swaps its container" case — the seam hides
   inside the backend.
4. **The escape hatch already exists on all seven** (Auto Layout /
   GtkConstraintLayout / ConstraintLayout / RelativePanel / Layout
   protocol / MeasurePolicy). "Platform-specific escape hatches later if
   desperate" has a real universal substrate — we'd be *exposing* it,
   not inventing it.
5. **Grid is a separate, later milestone.** Present everywhere but very
   uneven; orthogonal to the stack-based first pass.
