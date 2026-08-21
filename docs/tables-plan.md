# Tables: column headers and click-to-sort on the For vocabulary

STATUS: plan drafted 2026-08-20; the mac depth slice LANDED the same
day (wire + walls + Rust surface + SwiftUI Table + the three verbs +
the scene; validate-mac and the full matrix ALL PASS). 2026-08-21:
decision 5 REVISED (headers at every width — the degrade died before
its first commit), the Compose lowering rebuilt content-sized, the
expect_column_edges observable added, and the android phone legs
wired. The GTK and WinUI breadth slices are held open by the ledger's
DEPTH STUB entries. DESIGN.md's 2026-07-24 survey ratified the shape
this plan implements: "Table is not a separate widget admission: it
is column props on the existing list vocabulary, lowered richly where
the size class and the platform have the idiom and degraded to a
plain list where they do not." — the second half of that sentence is
what decision 5's revision struck: the lowering TIER still varies by
platform, but nothing degrades to a plain list anymore.

## What a table is here

kaya already has multi-column rows: a For whose row template's root is
a Row of cells (todos' checkbox+label is the living example). What it
does not have is what DESIGN.md's survey found a native table actually
buys: column HEADERS, drag-to-resize, and click-to-sort. This
milestone adds exactly those, as a declaration on the For, and nothing
else — no new widget kind, no row-window virtualization (still
admission-gated in the ledger), no column width props (drag-to-resize
is platform-managed and nothing about it rides the wire; a width HINT
is a separate admission if a real app ever needs one).

## The decisions

1. **Columns are declared on the For's container.** There is no List
   widget — a For materializes as a Column (scene.rs's CreateFor) and
   backends see only that container. The declaration targets its id:
   the live zone's WidgetId, or the template node id + key path when
   the For is nested (the click-tag addressing, already uniform).

2. **One record carries the whole header state.** Titles may contain
   spaces, so the `accepts` space-separated-Str trick is out; the
   carrier is `highlight_ranges`' shape — a widget-targeted record
   with a count and a `Values` run. The SORT INDICATOR rides the same
   record rather than a second prop: the header bar's state (titles,
   which column is sorted, which direction) is one declaration,
   atomic, and a sort flip re-sending a handful of short strings costs
   nothing. `sorted` is a column index or the `u32::MAX` none-sentinel
   (alert_choice's `cancel` precedent).

3. **Sort is the guest's, entirely.** A header click emits a
   `sort_requested` occurrence naming the column — a REQUEST, nothing
   has changed on screen. The guest reorders its own collection by key
   (`collection_move` — "order is data") and re-declares the header
   state with the new indicator. kaya never sorts data it does not
   own, the platform never sorts the model, and the round trip is the
   same one-way flow as every other control. Direction cycling
   (asc/desc/none) is guest policy, not platform behavior: the
   occurrence carries only the column.

4. **Rows must fit the columns, loudly.** When N columns are declared,
   every stamped row's root must be a Row with exactly N children —
   checked by the CORE at stamp time, so every backend inherits the
   wall and a mismatched template dies naming the row and both counts
   instead of rendering N-1 cells under N headers on some platforms
   and not others. (A bare-label row template is the N=0 undeclared
   case — columns simply not declared — never a 1-column table.)

5. ~~**Presentation degrades; the declaration does not.**~~ REVISED
   2026-08-21 (Akhil): **headers render at every width.** The compact
   degrade was an Apple-idiom analogy — SwiftUI's Table collapses to a
   first-column list on compact — generalized to the synthesized tiers,
   where nothing forces it and it threw away declared columns for no
   platform reason. The ruling: kaya's synthesized tier draws the
   header at any width, and iOS compact will take the synthesized tier
   rather than the native collapse (showing the declared columns beats
   the idiom that hides them). With no degrade there is no size class
   in the observable — `expect_columns` drops the `regular/` prefix and
   becomes byte-identical on every platform at every width, which is
   what let the android phone legs wire (they were waiting on a
   panes-style size-class ruling that no longer applies to tables).

6. **Per-backend lowerings** (depth first on mac, then breadth):
   - macOS/iPadOS regular: SwiftUI `Table` (NSTableView's wrapper —
     the native headers, resize, and sort affordances are the point).
     Dynamic column count needs `TableColumnForEach` (macOS 14.4+,
     iOS 17.4+); below that availability floor the synthesized-header
     tier serves, which only affects iPads on 16.0–17.3.
   - GTK: to be probed live before committing — GtkColumnView is the
     native construct but demands a model/factory architecture the
     stamped-children pipeline does not have; the likely landing is
     the synthesized header (SizeGroups aligning header cells with row
     cells) unless the probe says ColumnView can be fed per-child.
   - WinUI: the details-view lineage hand-rolled — a header Grid above
     the rows, star-sized columns shared between header and cells
     (the Column container is already a Grid there).
   - Compose: synthesized header over FLOORED-AND-DISTRIBUTED columns
     — DESIGN.md already files this as lowering tier 3 (Material
     dropped the component). Landed 2026-08-21 as one custom Layout: a
     loose measure pass finds each column's widest child (header
     included) as that column's FLOOR, leftover track width
     distributes equally across the columns, and header and cells
     share the x-positions by construction. The column rule went
     through three cuts in one day, each caught by looking at pixels:
     equal weights gave Name half a 1280dp tablet; pure content-hug
     protected content but drew the table in a corner of its viewport,
     which no platform's table does and which Akhil caught against the
     mac screenshots; floors-plus-distribution keeps both properties —
     nothing clips, the table spans, and with modest content it lands
     on the native Table's resting look.
   The synthesized geometry rule is ONE rule on every such tier
   (Compose and Swift's KayaTableLayout spell it identically; GTK and
   WinUI inherit it with their slices), and it is OBSERVED, not just
   implemented: `expect_column_edges <target> <n>` asserts BOTH halves
   — the cells form exactly n leading-edge clusters (within two device
   units) AND the table spans its assigned track — read from real
   layout by every backend. The span half exists because the
   content-hug cut kept every cluster exactly right while leaving 90%
   of the viewport empty: alignment alone cannot see it. macOS native
   columns add user resize on top (the affordance the touch tiers
   lack); its header is NSTableView's own and aligns with its cells by
   construction, so that path clusters cells alone. All four negatives
   were WATCHED FAILING 2026-08-21 (cluster + span, native mac +
   Compose), and the watching earned its keep immediately: on the
   native path the cell BOXES are Table-placed and cannot drift, so a
   padding perturbation correctly did not fire — the cluster half's
   live protection there is the COUNT (a column that never renders),
   while the synthesized tiers' negatives moved real placement.

7. **Construction surface.** The declaration and the click handler
   ride the For's own construction — Rust's statement form allocates
   the For id eagerly so the chain reads
   `items.rows(tx).columns(&["Name", "Size"], sort).on_sort(&msgs, f)`,
   with `.id()` handing the handler the handle its re-declaration
   targets. The expression forms and Go's ForEach already expose the
   handle and take the declaration directly. Each binding spells it in
   its own idiom; both construction zones get the surface (the
   template-zone census and check-sugar-surface hold the fan-out
   open).

8. **A table is a viewport, and the scene says it fills.** The scroll
   scene's rule verbatim: kaya's normalized layout gives a child its
   natural size unless the scene declares grow, and a Table's natural
   size is NOTHING — measured by a live-window screenshot after the
   depth slice landed, while every model-side observable passed
   (expect_columns reads the render's record, which is written on
   appear even at zero size; only pixels could disagree). Every table
   guest declares grow(1) on the For, and any future geometry-true
   table observable starts from this incident.

## The wire (append-only ids)

- TX 45 `set_column_headers` (renamed from set_columns mid-slice: the
  grid `columns` PROP's generated per-prop setters share one namespace
  with record-derived names in all eight generators, and go broke on
  the collision): widget:U64, sorted:U32, direction:U32,
  count:U32, reserved:U32, titles:Values (count Str values).
  Domain walls at the root: count >= 1, no empty title, sorted is a
  valid index or the none-sentinel, direction 0|1, target is a For
  container (in either zone).
- APPLY 35 `set_column_headers`: the same fields mirrored to backends.
- Occurrence 19 `sort_requested`: the click-tag body shape —
  { u64 id; u32 path_len; u32 column; path_len values } — id is the
  For (widget id at path_len 0, template node id + key path when
  nested), column the 0-based index. Emitted only by the user's
  gesture (the echo doctrine: a programmatic set_columns is
  configuration and stays silent).
- Handler: `on_sort` registered at the For (handlers scope to their
  creator). Unclaimed sort_requested occurrences drop silently, like
  any unhandled occurrence.

## Observables (all three harness implementations)

- `expect_columns <target> "Name|Size ^0"` — the header titles in
  visual order read from the TOOLKIT (never the model), the sort
  indicator as ^N (asc) or vN (desc) appended when one is shown,
  absent when none. NO size-class prefix (revised with decision 5,
  2026-08-21): headers render at every width, so the spelling is
  byte-identical on every platform and the phone legs run the shared
  scene verbatim.
- `header_click <target> <index>` — an action driving the platform's
  real header path (select_section's shape), so the native handler
  emits sort_requested.
- `expect_rows <target> "a,10|b,20"` — per-row cell label texts,
  rows pipe-joined, cells comma-joined, both levels in the toolkit's
  child order. A NEW verb rather than a change to expect_order, whose
  label-children contract six scenes already depend on; expect_order
  still serves flat Fors, expect_rows serves celled ones, and sort
  results are asserted here (creation-order registries cannot see a
  move — the reason expect_order exists applies verbatim).
- `expect_column_edges <target> <n>` — the cells form exactly n
  leading-edge clusters within two device units AND the table spans
  its assigned track, measured from real layout (the grid_columns
  Stage shape, empty-on-success). The uniform geometry claim of
  decision 6, both halves promised everywhere; the exact column
  widths stay platform metrics. Added 2026-08-21 with the
  geometry-rule ratification, so the same scene measures the same
  claim on every platform.

## The scene (tools/scenes/table.steps)

Rows of (name, size) seeded unsorted; expect_columns with no
indicator; header_click 0 → guest sorts ascending by name, sets the
indicator → expect_rows sorted + expect_columns shows ^0;
header_click 0 again → guest flips to descending → expect_rows
reversed + v0; header_click 1 → sort by the second column →
expect_rows + ^1. Every leg — desktop, tablet, phone — asserts the
same bytes; expect_column_edges rides between the first expect_columns
and expect_rows. The guest's sort handler is the reorder scene's
move-by-key idiom, never an index.

## Sequencing (the panes playbook)

1. Wire slice: spec records + root walls + stamp-time N-cells guard +
   regenerate all eight bindings + both interpreters' constants +
   harness verbs parsed everywhere. check-verbs/check-sugar-surface
   red-by-design until breadth closes.
2. Mac depth slice: SwiftUI Table lowering, the three verbs on the
   mac stage, table.steps, the rust guest; validate-mac green.
3. Breadth: guests x8, Compose, GTK (probe first), WinUI; each slice
   matrix-validated; DESIGN.md's table paragraphs updated at landing.
