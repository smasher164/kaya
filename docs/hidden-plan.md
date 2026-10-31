# Rows that hide and keep their place and state

RULED 2026-10-30 (docs/deferred.md, the filtered-view entry: "i lean a
too"): a filter is the app's predicate, written in its own language, and
the framework's part is a prop that hides a row without forgetting it.
The prop already exists: `hidden`, prop 68, a Bool on any kind from a
constant, a signal or a row's field (DESIGN.md, Structural operators;
built 2026-10-27 for a single widget in a row or column). This pass makes
it hold inside a collection, which is where a filter lives.

## H1 — What hidden means

A hidden widget is not drawn, takes no extent and no gap, is out of the
focus order and the accessibility tree, and KEEPS ITS WIDGET: the same
native control, so the text typed into it, its expansion, its check and
its value are there when it is shown again. `When` is the other
operator: it destroys, and a When shown again is a fresh copy.

A row is hidden when every root of its stamped copy is hidden; one root
is the usual shape (`row.hidden(row_field)` on the template's row).

## H2 — The core knows which rows are hidden

The core evaluates each template root's `hidden` binding per row: a
constant, a signal's current value, the row's own field (level 0), or an
enclosing row's field (level > 0). No new wire record: the binding is
the declaration. A site whose roots cannot hide pays nothing.

## H3 — The row window counts shown rows

Every window function (the band, the declared total, positions, pitch
measurements, `scroll_to_row`, `window_row_of`, the row-height question
the mac table asks) indexes the site's SHOWN rows: its order less its
hidden rows. So a filter narrows `expect_window`'s total exactly as the
removals it replaces did, positions stay multiplication on the exact
path, and a hidden row never corrects the pitch.

- A hidden row entering the band is NOT stamped: it is data, like any row
  outside the band.
- A row hidden while realized KEEPS ITS COPY while its place (the number
  of shown rows before it) lies inside the band, and is torn down when
  the band moves away from that place, exactly as a shown row there
  would be. The state a hidden row keeps is the state a shown row in
  its place would keep.
- Kept copies are parked AFTER the band's rows in the container, so a
  tier that maps children to rows by position (children[k] is row
  first + k) reads the band first, and a measurement run past the band
  is not a row's height (`rows_measured` truncates at the band's end).
- An unwindowed For (no report, no seed) stamps every row, hidden ones
  included; the prop is the whole of it there.
- A filter is a run of `update_field` records; the band is reconciled once
  for the run (H4), the quadratic-remove precedent (docs/traps.md).

## H4 — Per backend

The toolkit's own spelling, recorded from the survey of 2026-10-31:

| backend | how it hides | what it keeps | what this pass fixes |
|---|---|---|---|
| SwiftUI (mac, iOS) | the node renders `EmptyView` and leaves `laidOut` (KayaNode.vacant); SwiftUI has no hidden-without-removal (List rows are removed, `.hidden()` keeps the space) | text, expansion, checks, values, focus id: all on KayaNode | table tiers (native NSTableView, synthesized, iOS Table) drew a hidden row whole; the grid chunked hidden cells; expect_order, expect_rows and the plain-For expect_window counted hidden rows |
| Compose | `KayaRender` returns early; `laidOut` skips vacant | TextFieldState (text, selection) and scrollState live on the node | KayaTableSurface drew hidden rows; the grid; the same three reads |
| GTK 4 | `set_visible(false)`; nothing unparents | everything: the widget stays | the windowed band walk, the grid's index placement, the reads, an AT-SPI rank given to a hidden target |
| WinUI 3 | `Visibility.Collapsed` on the outer element, no track (reindex VACATED) | everything: nothing recreates the element | a wrapper installed while hidden came up visible; the grid; the reads |

The question parked for the maintainer is Q1 below.

## H5 — Inside each container

- A row or column (a stack): no extent, no gap (M16 (3) vacancy).
- A collection: H3.
- A virtualized table: H3; the header stays. A table whose rows are all
  hidden is an empty table, not a vacant one: its header is the app's.
- A section (a column with a heading and a For): the heading is the
  app's widget and stays unless the app hides it; a For whose rows are
  all hidden is vacant (takes no extent), as an empty For already is.
- A grid: the shown cells flow into the hidden cell's place; no hole.

## H6 — Reads

No new verb. `expect_rows` and `expect_order` list shown rows only;
`expect_window` reads the shown total; `expect_grid_columns` sees the
shown cells. A hidden row's widgets still answer `expect` (the text is
kept), which is how tools/scenes/hiderows.steps proves the state.

## H7 — The bindings

`hidden` was spelled in both zones of all nine bindings on 2026-10-27, so
this pass moves no binding surface: the collection semantics are the
core's and the backends'. Verdict per language: Rust, Python, Go, C#,
Java, Swift, OCaml, Haskell and JS do (each has a hiderows guest and
the search guest converted); the C floor does through kaya.h's
`tx_set_hidden` packers and element bindings (no C guest, as the
search scene has none). No can't, no carve-out.

## Choices the build settled (for ratification)

1. No prop number moves: prop 68 is the prop; no new verb, no wire record.
2. A hidden row's place is the count of shown rows before it; a kept
   copy is torn down when that place leaves the band.
3. `scroll_to_row` to a hidden row scrolls to its place (the next shown
   row) rather than refusing.
4. Kept copies are parked at the container's end.
5. The scene is a new one, tools/scenes/hiderows.steps, in all nine
   languages: a list with a field per row, a 300-row table, a grid.
6. The search scene's nine guests were converted with the two apps: their
   remove-and-insert mirror was the same reconciler a third time.
7. A filter is one `update_field` per row each time the query changes, so
   the app writes N records for N rows; the core reconciles once per run.

## Questions for the maintainer

Q1 — SwiftUI forgets a hidden widget's VIEW-LOCAL state. The mac and iOS
interpreter removes a hidden node from the view tree, so what SwiftUI
holds in the view and not in kaya's model is lost on a hide: a scroll
container's offset, a text view's caret and selection, a text view's
native undo stack. Text, expansion, checks, values and focus are kaya's
model and survive. The other three backends keep all of it. Options:
(a) move scroll offset and caret into KayaNode and restore them when the
view comes back (also fixes the same loss under a When or a re-stamp);
(b) keep hidden views mounted at zero size with a custom layout that
gives them no gap (every column becomes a custom Layout: a broad visual
risk); (c) record it as a carve-out. RECOMMEND (a). Parked: nothing in
this pass depends on it, and the scene reads text, which survives.
