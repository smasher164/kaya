# Layout knobs: `fill`, `wrap`, and the grid that fits

The third of the overnight slices (2026-09-06; docs/tasks-plan.md R10 and
docs/forms-plan.md are the first two). The maintainer's brief: "is there a
way to make this all more flexible and scalable? ... good layout behavior
for applications out of the box, sometimes with user-defined stuff, and
sometimes via the defaults." The first two slices are the defaults; these
three are the user-defined side. Rulings marked PROPOSED-overnight.

## §1 — `fill`: one child's cross-axis stretch

- A prop on ANY widget, `fill` (bool). True: the child spans its
  container's cross axis (a column's width, a row's height); false: it
  hugs, whatever the container's `align`. Unset: the kind's own default —
  the two rules already stated in DESIGN.md Layout (a scroll spans, a text
  field spans its column) become this prop's defaults and are the two
  cases `fill = false` exists to opt out of.
- Lowering: the cross placement every backend already computes per child
  (GTK's apply_cross_align, WinUI's reindex, Compose's boxFill, SwiftUI's
  KayaCell frame) reads the prop before the container's mode.
- Observable: `expect_breadth <target>` and `expect_fills`, both exist.
- Sugar: `.fill(true|false)` chained on every binding's widget handle,
  both zones; the template zone censused by tpl-surfaces' PROP_MEMBERS.

BUILT 2026-09-06 (overnight). Prop 27, Bool, kind-agnostic at the root;
the model holds it as a tri-state (`Option<bool>` / `Bool?` / `Boolean?`)
and every backend reads it at its one cross-placement site AFTER its
kind defaults, so the child's word outranks them: SwiftUI's stack and flex
frames, the entry's and textarea's column-wide frames, the scroll's span
and a container's own `boxFills`; Compose's `boxFill` (and `kayaHugCross`'s
pin); GTK's `apply_cross_align` off a widget-data key with a re-stamp on
write; WinUI's `reindex` crossing off `core.fills`. The observation pair is
`expect_breadth` (opt-in) and the new `expect_hugs` (opt-out) — the same
read wanted short, with a reader that has nothing recorded failing on
that side too. align.steps' `column@knobs` holds both in nine guests. The
mac align leg read `textarea@optout hugs, button@fills spans its breadth`
on the first run. A BUTTON is the opt-in probe rather than a label,
because a stretched WinUI TextBlock arranges text-sized (docs/traps.md).

## §2 — `wrap`: a row that flows onto new lines

- A prop on Row, `wrap` (bool): children keep their natural size and flow
  onto the next line when the row runs out of width, leading-aligned, the
  row's `spacing` on both axes. No `grow` inside a wrapping row (refused
  at the root: a weight has no track to take).
- Lowering: Compose `FlowRow`; SwiftUI a `Layout` beside KayaFlex
  (there is no built-in flow layout); GTK `GtkFlowBox` with
  `selection-mode none` and homogeneous off, or a custom layout manager
  beside flex; WinUI a custom panel (the Community Toolkit's WrapPanel is
  not in the tree).
- Observable: `expect_lines row@<id> N` — the distinct clusters of the
  children's cross-axis edges, the grid-columns reader's shape rotated.

BUILT 2026-09-06 (overnight). Prop 29, Bool, Row-only at the root, which
also refuses a growing child of a wrapping row at the end of the
transaction in either order. `expect_lines` is a Stage read
(`row_lines`) every backend answers from the children's cross boxes — a
run of overlapping boxes is one line, so a centred row's tall image and
short label read as one and a flowed row's second line starts where
nothing above it reaches (the first draft clustered TOP edges and read
the centred control row as two; the mac leg caught it on the first run)
— GTK from allocations, WinUI through TransformToVisual, SwiftUI and
Compose from the cross rects their cell readers already record. SwiftUI: KayaFlow,
a Layout beside KayaFlex, natural sizes and leading-aligned lines;
Compose: FlowRow with the row's own readers on each child; GTK: a second
layout manager, FlowLayout, swapped onto the same GtkBox (children stay
direct children, so every walker is unchanged; measure answers the widest
child as the minimum and one line as the natural, and the height for a
width from the lines that width allows); WinUI: reindex hands a wrapping
row to reflow_wrap, which re-stamps the Grid from its own ActualWidth into
Auto tracks, and the row's LayoutUpdated re-runs it only when the breaks
moved. align.steps' `row@wrapped` flows six 100x20 images: exact pixel
widths, so every lane breaks them onto two lines (desktops four and two,
phones three and three; a third line needs under 316 points), and
`row@plain` is the one-line control. Nine spellings, `wrap(bool)` on a
row handle in both zones.
Matrix #14 failed every Windows align leg at the BASELINE read, 37s
each, and the auto grid's adaptive leg beside them: the previous fix's
`InvalidateArrange()` on a busy borrow, raised from a LayoutUpdated that
the reader's own UpdateLayout had fired, is a layout cycle inside the
read (docs/traps.md). Both handlers hop the dispatcher now.
And the width a wrapping row fits on WinUI is its PARENT's: a Grid of
Auto tracks is granted its whole one-line desired width, so its own
ActualWidth is the overflow and reads one line (docs/traps.md,
`wrap_width`).

## §3 — the grid that fits: `columns: auto` with a minimum column width

- `columns` gains `auto`, with a new prop `min_column_width` (points):
  the grid takes as many columns as fit the width at that minimum, each
  column sharing the extra; an explicit `columns` count or `columns_when`
  still wins. The Details form was the case: three columns on a desktop,
  one on a phone, decided by the width and not by a size class.
- Lowering: SwiftUI `LazyVGrid(columns: [GridItem(.adaptive(minimum:))])`
  for the auto case beside the fixed one; Compose `LazyVerticalGrid(
  GridCells.Adaptive(minSize))` or the existing Layout with a computed
  count; GTK `GtkFlowBox` with min/max children per line derived from the
  width, or the existing GtkGrid reflowed on size-allocate; WinUI the
  existing reflow_grid re-run on SizeChanged with a computed count.
- Observable: `expect_grid_columns grid@<id> N` after `resize_window`,
  the adaptive scene's pattern, so the desktops assert both counts and
  the phones their narrow truth.

BUILT 2026-09-06 (overnight). `columns = 0` is auto and `min_column_width`
(prop 28, F64, grid-only, finite > 0) is its floor; the root holds the
pair at the end of the transaction, in either order, and dies by name on
an auto grid with no floor. The sugar is ONE call, `columns_auto(min)`,
which sets both — no constructor variant, since the count is the width's.
The arithmetic is one line on every backend: `floor((width + gap) /
(min + gap))`, at least one, each column an equal share of the width. An
auto grid SPANS its parent's cross axis by default (the scroll's rule:
it is width-driven), which is what gives every backend a width to read.
SwiftUI: `KayaAutoGrid`, a Layout over the proposed width (the fixed
count keeps SwiftUI's own Grid), cells recording their leading edge
exactly as the fixed grid's do; Compose: the existing grid Layout with
the count and share taken from the incoming constraints; GTK: the count
re-derived on the grid's frame tick from its own allocation (it spans, so
that IS the available width), homogeneous columns, a reflow only when the
count moved; WinUI: LayoutUpdated on the grid, gated the same way, Star
columns. adaptive.steps' `grid@fit` (three buttons, floor 240) reads 1 at
480 wide and 3 at 900 on the desktops, and 1 on both phones through the
lanes' extras; the mac read both on the first run. The nine spellings
are one call each, `columns_auto(min)` in the binding's casing (OCaml also
`?columns_auto` on `grid`, Haskell `ColumnsAuto`/`setColumnsAuto`), both
zones, with Go's two sealed surfaces forwarding. Matrix #13 found the
WinUI handler dropping a width when a harness read held the core borrow
(docs/traps.md); it asks for another layout pass now.

## §4 — sequencing

`fill` first: smallest, and it retires the two hard-coded defaults into a
prop with an opt-out. Then `columns: auto`, since the task manager's own
screens had the case. `wrap` last: no screen in the tree needs it yet, and
it wants a scene of its own. Each: spec prop, four backends, nine bindings
in both zones (tpl-surfaces' PROP_MEMBERS for the template half), a
scene assertion on every lane, one matrix.
