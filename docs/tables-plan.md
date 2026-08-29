# Tables: column headers and click-to-sort on the For vocabulary

Continuation after the post-capture fixes: docs/handoff-dynamic-tables.md.

STATUS: plan drafted 2026-08-20; the mac depth slice LANDED the same
day (wire + walls + Rust surface + SwiftUI Table + the three verbs +
the scene; validate-mac and the full matrix ALL PASS). 2026-08-21:
decision 5 REVISED (headers at every width — the degrade died before
its first commit), the Compose lowering rebuilt content-sized, the
expect_column_edges observable added, and the android phone legs
wired. 2026-08-21, later the same day: the GTK, WinUI and iOS
slices all landed (three agents in parallel worktrees, each lane
green) — every backend now lowers tables and every lane runs the
byte-shared scene; no DEPTH STUB entries remain open. DESIGN.md's 2026-07-24 survey ratified the shape
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
   - macOS: SwiftUI `Table` always (NSTableView's wrapper — the native
     headers, resize, and sort affordances are the point; no compact
     mode exists there). iOS/iPadOS (landed 2026-08-21): the native
     `Table` at REGULAR width and above `TableColumnForEach`'s 17.4
     floor; kaya's synthesized tier at every compact width and below
     the floor — size class first, availability second, so an iPad in
     a compact split-screen window takes the synthesized tier at any
     OS version. Compact is not a degrade: the declared columns are
     all drawn; it is the tier that can draw them, since the native
     Table collapses to a first-column list there.
   - GTK: PROBED 2026-08-21 and the answer was NO — GtkColumnView's
     list items own their children, so a stamped widget cannot be fed
     to one at all (docs/traps.md). Landed as the synthesized header
     over a per-column GtkSizeGroup with hexpand cells, which the
     toolkit turns into floor-plus-equal-leftover by itself (measured
     at two widths, delta constant); GtkGrid does the same arithmetic
     but cannot host the stamped Row boxes.
   - WinUI: the details-view lineage hand-rolled — a header Grid and a
     rule as two more children of the For's own Grid, with MEASURED
     pixel tracks shared between header and cells (landed 2026-08-21).
     Not star sizing and not SharedSizeGroup: WinUI's Grid has no
     SharedSizeGroup (WPF only), so the two surfaces cannot share
     tracks declaratively, and star-with-MinWidth resolves to equal
     columns clamped up at content rather than to this decision's
     floor-plus-distribute.
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
   layout by every backend. Since 2026-08-25 the span half is
   two-directional: the cells must also START flush, not merely stay
   inside (docs/deferred.md, the ContentUnderfill entry, which carries
   what each backend can and cannot see here). The span half exists because the
   content-hug cut kept every cluster exactly right while leaving 90%
   of the viewport empty: alignment alone cannot see it. macOS native
   columns add user resize on top (the affordance the touch tiers
   lack); its header is NSTableView's own and aligns with its cells by
   construction, so that path clusters cells alone. THE FLOOR HALF
   REACHED THAT PATH 2026-08-26 (ruling A, docs/deferred.md's
   native-ellipsize entry): the measured content widths are the native
   columns' MINIMUMS and their total is handed upward, so a hugging
   container widens the way it does on every synthesized tier instead
   of letting AppKit compress the columns and ellipsize inside them.
   Every backend's
   negatives were WATCHED FAILING 2026-08-21 (cluster + span on native
   mac, Compose, GTK, WinUI, and both iOS tiers — one tier perturbed
   at a time with the other device's leg watched staying green), and
   the watching earned its keep immediately: on the native path the
   cell BOXES are Table-placed and cannot drift, so a padding
   perturbation correctly did not fire — the cluster half's live
   protection there is the COUNT (a column that never renders), while
   the synthesized tiers' negatives moved real placement.

7. **Construction surface.** The declaration and the click handler
   ride the For's own construction — Rust's statement form allocates
   the For id eagerly so the chain reads
   `items.rows(tx).columns(&["Name", "Size"], sort).on_sort(&msgs, f)`,
   with `.id()` handing the handler the handle its re-declaration
   targets. Go is that same shape one language over since the idiom
   sweep (2026-08-24): `tx.Rows(c)` mints the For, the chain declares
   the bar and the handler, `for row := range rows.All()` traces the
   template once, and `Widget()`/`Node()` hand out the handle. The
   expression forms already expose the
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
   table observable starts from this incident. `expect_fills` therefore
   has a table arm: unlike an ordinary flex container it permits unused
   row space, but it rejects raw table content beyond the allocated
   vertical viewport. The shared `table.steps` runs that assertion on
   every backend; it was watched red on Compose (no table measurement)
   and WinUI (113dip of content in a legitimate 307dip viewport) before
   those backends recorded/recognized the table shape. Its
   `expect_column_edges` assertions repeat after every sort
   re-declaration, as does the portfolio's per-copy geometry, so a
   first-frame-only measurement cannot answer for later header bars.
   AMENDED 2026-08-24, the empty-row ruling: grow is the opt-in half.
   A GROWN table keeps everything above — a fill-and-scroll viewport
   whose native empty area may stripe. An UNGROWN native table hugs
   header + rows at the platform's measured metrics (macOS, probe-
   measured: header 28, 5pt top inset, 24pt rows) plus a 5pt bottom
   APRON the safeAreaInset paints in the table's base color. The apron
   matters at both row parities and only a camera can hold it:
   NSTableView paints its next phantom stripe from the last row's
   edge, so bare height past the rows shows a grey sliver at odd
   parity, and height cut to the rows leaves a grey LAST stripe flush
   against the table edge at even parity — the maintainer caught the
   second on the first capture set (BND with a top margin, VXUS
   without a bottom one). Both states viewed on 2026-08-24 captures;
   the apron capture shows every stripe floating with equal margins. The expect_fills table arm splits on the same
   bit: a grown table skips vertical containment (NSTableView
   legitimately realizes an overscan row past the clip), an ungrown
   one keeps containment plus the hug clause — viewport within 30pt of
   its last row — watched red in both directions (content-height frame
   removed: collapse; height inflated 100pt: "leaves 109pt below its
   last row"). The portfolio dashboard is the ungrown consumer and
   asserts the hug on column@positions[brokerage]; table.steps' grown
   table is the other half. Compose's synthesized tier is content-height
   by construction; GTK's was NOT, measured 2026-08-25 — its scroll
   viewport carried the vertical scrollbar's OWN 58px minimum, so a
   one-row table drew 42px of empty card under its row (docs/traps.md,
   "A GTK table's viewport floor is the scrollbar's own minimum"). It
   hugs now: the vertical policy is written from the core's extent and
   the container's grow weight, so a table that cannot need a bar stops
   claiming one. iOS ungrown native metrics stay unpinned until a scene
   exercises one.

## Overflow: what a table does when its columns do not fit (ruled 2026-08-29)

THE DECLARATION THAT MAKES A TABLE IS THE ONE THAT ANSWERS THIS. Columns
are declared on the For's container (decision 1), which is a Column — so
"has a header bar" is already the state that separates a table from a
plain container, and it carries the overflow rule with it. No property, no
wire record, no enum value is added, which is the point: an app cannot
forget the keyword, and there is no new knob for `axis` to collide with.

THE RULE: a table whose columns need more width than its track gets
SCROLLS HORIZONTALLY, header locked to the body. It does not compress
(content is the floor, ruled 2026-08-26) and it does not clip.

KEYED ON THE FACT, NOT THE PLATFORM. The trigger is "the columns do not
fit", not "this is a phone" — a narrow pane on a desktop reaches it too
(measured on macOS at a 240pt window, where the four portfolio columns
hold their positions and simply overflow), one shared scene must not get
two answers, and a fact-keyed rule can be driven from the DESKTOP lanes
with resize_window, where a platform-keyed one would be observable only
on the two phones.

WHY NOT THE ALTERNATIVES. Compressing contradicts the content-is-the-floor
ruling. Clipping is what iOS does today, silently, and it lies about what
the user is seeing. Dropping columns is SwiftUI's own answer on iPhone
("the table automatically hides headers and all columns after the first")
and it is the one answer kaya cannot take: the same shared scene would
observe a different column count per width, which is the panes-band
problem again. Every column stays present here, so `expect_columns` reads
the same titles at 320dp and at 900dp. The survey behind all of this is
docs/probes/table-overflow-2026.md, and WCAG 1.4.10 excepts data tables
by name from the no-two-dimensional-scrolling rule.

LANDED 2026-08-29 ON THREE BACKENDS, each verified on its own lane:
GTK (the body's horizontal policy Never->Automatic with overlay bars, the
header in its own scrolled window SHARING the body's hadjustment — which
is GtkColumnView's own mechanism — and the value parked at `lower` when
the extents move), COMPOSE (the measure keeps its leftover distribution
and records a reach; `clipToBounds` + `scrollable(Horizontal)` rather
than `horizontalScroll`, which would have cost the measure the track it
distributes; the card segments stay with the viewport because they are
what bounds the table for the reader), and WINUI (the host's
HorizontalScrollMode enabled with an Auto — overlay — bar, and the header
in a SECOND ScrollViewer driven to the host's offset, because this
backend's bindings project neither RenderTransform nor Clip).

ONE DIAGNOSTIC, THREE SPELLINGS OF IT: each backend's table-overflow
clause now takes a REACH — the surface's own granted scroll, measured
rather than derived as `content - track`, which would have made the
clause agree with itself — and convicts only when the columns exceed the
track AND cannot be reached. `ColumnsOverflow`/`ContentOverflow` became
`ColumnsUnreachable`/`ContentUnreachable` so the three spell one rule.

THE VERBS: `expect_overflow`, `scroll_end` and `expect_at_end` take a
TABLE target and read its COLUMNS' axis, because a table's ROWS already
answer to `expect_window` and `scroll_to_row` — the target's kind decides
the axis and no verb needs an axis word. harness.rs admits
`Scroll | Column` for all three.

AND THE iOS SYNTHESIZED TIER, 2026-08-29: its layout answers
`min(total, proposal)` so it takes the track it is given, places every
column at an offset the VIEW owns (a Layout is a pure function, and
observable state written during layout invalidates the pass that wrote
it — that mistake cost the varied scene two rows of its band before it
was understood), clips, and takes a drag. Two things it needed that the
other tiers did not: the columns' axis has its OWN registry, because an
ungrown table has no scroll proxy and registering it as a row window made
`expect_window` answer "0 0" for a table that has none; and the track it
records is the CARD'S INTERIOR rather than the layout's own box, since
the edge instrument measures cells against that interior — the outer
width reported "content 290 in viewport 290" for a table whose cells
stood 11pt outside a 279pt viewport, one overflow with two numbers.

AND THE macOS NATIVE TIER, 2026-08-29, which completes the roster. The
representable answers PER PROPOSAL — a concrete width is the parent
saying what there is and is taken; an unspecified one is the parent
asking what the table wants, and the answer is its content CAPPED BY THE
WINDOW, because a hug wider than the window puts columns where no scroll
view can reach them. Apple's contract leaves no other lever: nil means
"the default sizing algorithm", which Apple never defines, while "one of
the values returned from this function will always be used as the actual
size" (docs/probes/swiftui-sizing-2026.md). Before the table is measured
there is no content to hug and the honest answer is nil — answering the
fitting size pins it at ~10pt, which leaves its columns no room to be
measured in and the floor never arrives.

TWO THINGS THIS TIER TAUGHT, both measured and both now rules:
NO FORCED LAYOUT INSIDE A HARNESS READ — pumping one is gtk.rs's 1630
rule a platform over, since the read runs on the main thread while the
harness holds the core, and the run produced no verdict at all. And a
DELIBERATE SCROLL SURVIVES A RELAYOUT: the leading-edge park is keyed on
the CLIP moving, because AppKit keeps the visible RIGHT edge across a
resize and parked a freshly resized table at its trailing edge, which
made `expect_at_end` true before anything had scrolled.

RULING A'S GUARD WAS REWRITTEN, not worked around (the maintainer's call,
2026-08-29): it asked the hug inside a 200pt window against 335pt of
columns, where the only way to pass was for the table's own VIEWPORT to
be wider than the window containing it — 135pt of table hanging off the
side with no way to reach it, which is the behaviour this ruling
replaces. A test may not demand what its project has ruled against. It
now asks the hug in kaya's own vocabulary, an UNGROWN column beside a
GROWN sibling in a window with room, which is the shape a real hugging
panel has; the two clauses carrying ruling A's substance — no column
narrower than its content, none declaring a minimum below it — are
untouched, and the gate's own self-test still reddens the rewritten
clause.

STILL OPEN: only the shared conformance scene's wiring. A fix that works is measured
(answer per proposal in the representable's sizeThatFits, capping the hug
at the window), and it COLLIDES with ruling A's own guard, which asks the
hug inside a 200pt window and requires the table to overflow it — at that
width the two rulings say opposite things. Amending that probe to ask the
hug where there is room keeps its teeth and lets both hold, but it amends
a RULED guard, so it waits for the maintainer. docs/deferred.md carries
all four attempts and their measurements;
docs/probes/swiftui-sizing-2026.md carries Apple's own contract, which
says the composite size is whatever `sizeThatFits` returns and never
defines the default the nil case falls back to.

The shared conformance scene waits on that one tier: a scene forces a leg
on every runner, and a leg that cannot pass is not a leg.

`axis` IS REFUSED ON A TABLE, both orderings (set the axis then declare
columns, or the reverse). A flip would render the rows as a plain row and
drop the header, silently, on every backend — legal until this ruling
because a For's container is a Column and `axis` is legal on Columns.
`stack_below` lowers to a breakpoint whose only setter is `axis`, so one
refusal covers both spellings; the sentence says what a table does
instead. Three watched negatives in scene.rs, plus one that holds a plain
container still flipping.

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
  claim on every platform. The span half convicts UNDERFILL as well as
  overflow since 2026-08-25, and what each backend can see of it is
  docs/deferred.md's ContentUnderfill entry.

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

## Dynamic tables (the 2026-08-22 design; ledger: "Dynamically created tables — HIGH PRIORITY")

Before b819423, the fenced shape — a table created once per data item,
"for every account, a positions table" — was refused at declaration:
set_column_headers addressed a live For container by bare widget id
while a nested For's rows() carried a template node. The dashboard
worked around that with one collection repopulated on selection
(guests/python/portfolio.py's former repopulate()). The Rust/Python
depth slice deleted that workaround; the six remaining bindings'
nested spellings closed 2026-08-24 (the breadth record below). Build
order onward is RULED: tables -> virtualization -> canvas.

WHAT THE STAMPING MACHINERY ALREADY GIVES US, which shrinks the
milestone: run_body births a nested For's SITE per copy, keyed
(collection, path), with a PER-COPY internal container widget — and
click_tag(node, keys) already carries copy identity, which is exactly
how sort_requested reports "a template node id plus the copy's key
path". So per-copy headers are per-copy APPLIES against per-copy
container ids, and the backends' apply arms need NOTHING: a stamped
container with a SetColumnHeaders apply is just a table container,
keyed by the id it already receives. The weight is in the core and
the binding spellings, not the four backends.

THE WIRE: TX 45 grows `path_len: U32` (before `count`); its Values
carry path_len KEY values first, then count title strings — keys
first, sort_requested's "path_len key values follow" convention.
Addressing, three cases:
- path_len 0, id = a live For's container: today's case, unchanged.
- path_len 0, id = a nested For's TEMPLATE NODE: the template-scoped
  declaration — headers for every copy, stored on the site; each
  stamp emits that copy's apply; a re-declaration updates all copies
  without a declared per-copy override.
- path_len > 0, id = the template node, keys outermost first: ONE
  copy's re-declaration — the per-copy sort indicator, which is the
  whole point ("each copy needs its own working sort arrows").
Walls, same order as the live arm's: the template-node target must
name a nested For; arity checks run against that For's bodies; a
keyed target must resolve to a stamped copy; count/titles/sorted/
direction walls verbatim. The apply keeps its shape — id becomes the
copy's container, tag becomes click_tag(template_node, keys).

CORE STATE: the site stores the template declaration; per-copy
overrides in a map keyed by the copy (cleared when the copy is
removed). stamp_entry emits the copy's header apply after run_body,
override-or-template. A late template declaration (after copies
exist) re-stamps every live copy's bar.

BINDINGS: Rust's nested rows().columns() emits with the template node
id; the fence was the core lookup. Its on_sort registration now uses
the nodes table (stamped handlers already lead with the copy's keys),
and Rust and Python both have keyed per-copy re-declaration spellings.
The same spelling in the other six languages is the fan-out's real
work; each language extends tpl-surfaces.py's census as it lands.

HARNESS: the ruled spelling is `kind@id[key]`, dot-joined keys for
depth (`column@positions[brokerage]`), resolved from authored id ->
template node -> the stamp keyed by the copy path. Untyped segments
match string keys only; an I64 key is never stringified, so `3` cannot
collide with the string key `"3"`. A typed extension is a separate
grammar decision. The forcing assertion is per-copy divergence: click
ONE copy's header, assert ITS indicator moved and a SIBLING's did not.

SEQUENCING: spec.rs first (the hash moves, everything regenerates),
core walls + state with unit tests, Rust + SwiftUI + the dashboard
reworked to the real nested shape on mac, THEN the fan-out (six
bindings' spellings, their census clauses, and the five-lane matrix;
the Python dashboard stays desktop-only until packaging).

## The second slice, serialized (2026-08-23 — depth green, breadth open)

b819423 is the protocol root, pushed and green up the whole ladder for
everything it touches: TX 45 carries copy keys (reserved:U32 became
path_len:U32; Values = keys then titles), scene.rs's arms cover the
three addressings (live container / template-scoped-every-copy /
keyed-one-copy), stamping records bar_instances[(node, PathKey)]
unconditionally and emits each copy's bar apply with
click_tag(node, keys) — sort_requested's own identity — teardown
sweeps the maps, and seven unit tests (fixture dynamic_table_scene,
scene.rs) were each watched failing first. The APPLY record did NOT
change: backends receive ordinary per-copy applies and are expected
to need NOTHING — verify by measuring before touching one. The
generators read one is_padding predicate now (a spec field dropped
from signatures can never again be emitted by name); all eight
bindings pass path_len 0 spelling-neutral; both interpreter hash pins
moved.

THE DEPTH SLICE IS GREEN IN THIS ORDER; BREADTH REMAINS:
1. Rust — IMPLEMENTED. Nested Rows::columns() emits the template node plus
   empty path; Rows::on_sort registers in the Messages nodes table;
   Tx::columns_at takes the node handle and copy keys for per-copy
   re-declaration. Compile-time surface checks and the emitted key-
   before-title record were watched red first.
2. Python — IMPLEMENTED. Nested Collection.columns() emits the template
   declaration, on_sort reaches the node handler, and
   positions.at(account).set_columns() is the keyed spelling. The binding
   also gained Collection.rows(grow=, align=, a11y_id=) when the forcing
   app exposed the missing ordinary-For geometry/identity hop; each
   handoff and trace emission was watched red.
3. Harness copy-targets — IMPLEMENTED after maintainer approval of
   `kind@id[key]`, dot-joined string keys for depth
   (`column@positions[brokerage]`). The shared runner, GTK/WinUI stage
   routing and both interpreter resolvers map authored id -> template
   node -> exact live copy; malformed targets and I64 paths are refused.
4. Dashboard — IMPLEMENTED in the real shape. repopulate() is gone; every
   account stamps its own positions collection, and portfolio.steps
   clicks one copy's header, proves its sibling unchanged, then proves
   both independent sorts survive a tick. Desktop lanes only
   (portfolio is IOS_UNWIRED/ANDROID_UNWIRED until packaging).
5. Census — IMPLEMENTED for the two depth languages. tpl-surfaces.py reads
   Rust and Python's own nested table points, check-sugar-surface
   perturbs every new spelling, all three ordinary-For keyword/emitter
   pairs, and the portfolio's three nested geometry hops.
   check-steps holds the shared grammar and the Swift/Compose resolvers;
   the three desktop scene legs exercise GTK/WinUI's Stage routing. Go,
   C#, Java, Swift, OCaml and Haskell must extend the census tables in
   the same commits as their spellings.
6. Ladder — GREEN. The cargo suite passed 405 unit tests, 4 runnable
   docs and 14 compile-fail docs; all 42 gates and validate-mac's 329
   legs passed. The 2026-08-23 accepted concurrent matrix was ALL PASS: gates 374s,
   mac 323s/329 legs, Linux 439s/580, Windows 465s/191, iOS 429s/106,
   Android 252s/112; 467s wall time. The gate-sweep ceiling moved from
   390 to 490 against this slice's measured 378/387/391s band and 29
   new watched perturbations; its retention branch was watched red.

WORKTREE STATUS 2026-08-23: items 1–6 are implemented and watched in
the worktree.

BREADTH CLOSED 2026-08-24: all six remaining bindings spell the
template-zone bar, nested on_sort carrying the copy's key path, and
keyed re-declaration — Go (Tpl.Columns / App.OnSortNode / Tx.ColumnsAt),
C# (Node-typed overloads beside the live ones), Java (Tpl.columns /
onSort(Node, SortHandler) / Tx.columnsAt, RowSurface forwarding),
Swift (KayaTpl.columns / onSort(_ n:) / columns(_:at:_:_:)), OCaml
(Tpl.columns and its `?on_sort` / columns_at — the registrars
`on_sort`/`on_sort_node` died to the handler-consistency ruling on
2026-08-24, a binding registering a handler where its own click
convention does, which in OCaml is a labelled argument at the
declaration), Haskell (Declare's columns /
HandlerTarget's onSort / columnsAt — one name per zone-spanning point,
the `columnsNode`/`onSortNode` pair having died to the module's own
header rule on 2026-08-24; `SortTarget` was absorbed into the six-verb
`HandlerTarget` the same day, when the rule reached the other five
registrars). DO on every point in every language; zero
carve-outs. Every spelling joined the tpl-surfaces/check-sugar census
in the same change with its watched perturbations (the census
self-test runs every language's on every invocation; the gate's own
output is the count), and each compiles under a gate that already
runs. Three of the four dispatch loops (C#, Java,
Haskell) had silently DROPPED a keyed sort_requested before this — the
keyed arm is new in each. The fan-out also found a real core defect:
widget and template-node numbers are separate per-binding counters
over one u64 target, and a collision misrouted set_column_headers.
Fixed at two levels the same day, three watched reds first: keys
resolve in the template space alone, and the core refuses the
collision at declaration in both directions (scene.rs; the one-id-space
design question is a ledger DECISION entry). The breadth record:
407 unit tests + 4 runnable docs + 14 compile-fail docs, 42 gates,
and the five-lane matrix ALL PASS — mac 277s/329 legs, Linux 312s/580,
Windows 305s/191, iOS 371s/106, Android 132s/112, gates 291s, 425s
wall. (The first attempt printed a mac DURATION ANOMALY at 648s: the
coordinator edited docs mid-run, the lane's same-tree token failed,
and it swept all 42 gates itself — a matrix run wants a quiescent
tree; the rerun untouched was 277s.)

POST-MATRIX VISUAL FOLLOW-UP: the artifact review found GTK allocating
three unequal-natural, equal-weight account cards from an invalid summed
measure, and macOS giving the new accounts For its default start breadth.
GTK now inverts its exact weighted allocator (including rounding dust),
the Python rows spelling carries grow+stretch+authored id, and the app
requests 800x600. The scene pins the window, both nested alignments and
table containment; every backend's column-edge reader rejects horizontal
overflow. The watched numbers and why native cell ink is one-sided live
in docs/traps.md; the resolved ledger entry owns the screenshot finding.

The 2026-08-24 fix-forward attempt is recorded in docs/deferred.md's
resolved screenshot entry. Every scene assertion and the gate sweep
passed, but duration guards refused the matrix record; it does not move
the accepted depth record; the six-binding breadth closed later that
day (above).

MEASURED IN SLICE 1 — do not rediscover:
- A nested collection must be declared INSIDE the template scope
  (bind_collection's own-scope wall).
- The template-zone set_column_headers arm finds its For in the OPEN
  parent scope's ops: the nested For folds into the parent at its
  TemplateEnd before the header op arrives (Row Drop ordering). A
  grandparent-scope target is not expressible by the builders.
- A per-copy re-declaration requires the template bar first (walled,
  tested); a template re-declaration clears per-copy overrides
  ("replacing whatever was declared before" covers the copies).
- Types: bodies are Vec<Arc<TplBody>>; map keys are PathKey (Key is
  the hashable form of Value).
- In a fixture, dropping a cell's AddChild makes it a second ROOT —
  the one-root wall fires before the cell-count wall.
- check-abort's C# arm builds unconditionally since b819423 (its
  [ -f ] guard ran a stale dll and called it green).

Closed during the visual follow-up: per-phone iOS preparation removes
every exact prior-run `dev.kaya.*` bundle before LocalStorage admission,
deleting the stale editor containers. Still parked on the dialog-flake
entries: log the goto'd directory beside the picker's breadcrumb;
Android's blindness face waits on a non-empty-but-wrong window-list
sighting.
