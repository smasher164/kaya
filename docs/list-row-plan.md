# A list's row takes a click at no cost in height (2026-10-27)

The maintainer, on the task manager after bdbd0ad1 made each task's title
pair take a click: "The taller rows are an issue. Is there a way to
compensate for that row padding? ... Maybe we make the inner item smaller,
or make the row padding smaller, or we conditionally change the size".

## What made the rows taller

A task list is a plain column of stamped rows, spaced by kaya's normalized
8 units (DESIGN.md, the normalization worklist). An activatable container
takes the platform's filled inset on all four sides (SwiftUI 10 pt, GTK
12 px, WinUI and Compose 12), so its hover and selected surface do not run
flush against its content (the 2026-10-17 preview). In a list that inset is
added above and below every row ON TOP OF the column's spacing:

| lane | pitch before (no activatable) | pitch with the activatable item |
|---|---|---|
| macOS | 46 pt | 66 pt |
| GTK | 60 px | 77 px |
| WinUI | 57 px | 75 px |
| iOS | 54.3 pt | 70.7 pt |
| Android | 56 dp | 72 dp |

The coordinator's first reading was "the list row's padding plus the
item's inset"; on every lane the list is a plain column with no row padding
of its own, so making the whole row the activatable item moves the surface
but not the pitch. The double cost is the inset's vertical half plus the
column's spacing.

## The rule

An ACTIVATABLE row or column stacked in a column (a list's row), with no
`inset` and no `filled` of its own and not a declared table's row:

- pads its sides by the platform's filled inset, as every activatable does;
- pads its top and bottom by HALF THE COLUMN'S SPACING;
- and reaches that far past its slot on both ends, so the column lays it
  out at its content's height.

The pitch is then exactly the plain list's (content plus the spacing), the
surface covers the whole pitch, and two neighbours' surfaces meet edge to
edge, the way a native list's selection does (Finder, Reminders, Things,
a GtkListBox's navigation sidebar, a WinUI ListView). Cards in a grid, a
row in a row, and a container the app gave an inset keep the uniform inset.

Per backend: SwiftUI's `kayaListRowReach` (vertical padding in
`KayaInsetPadding`, a negative vertical padding at the end of the container
chain); Compose's `kayaListRowReach` and `kayaListRowOverhang` (a layout
modifier reporting the height less both reaches and placing the surface up
by one); GTK's `refresh_list_rows` after every batch (a `kaya-list-row-N`
class: `padding: Npx 12px` and negative top and bottom margins); WinUI's
`list_row_reach` (the Grid's Padding in `stamp_container_padding` and a
negative top and bottom Margin in `reindex`).
