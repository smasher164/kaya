# What a table does when its columns do not fit — across UI frameworks

Research date: 2026-08-28. Sources: framework docs, API references, design
guidelines and framework SOURCE, verified live (not from memory).

Question this serves: kaya has no rule for a table whose columns need more
width than the viewport gives them. Today Compose clamps them into the track
and iOS clips the last column silently — neither is a decision anyone made.
The maintainer already ruled the adjacent half (CONTENT IS THE FLOOR, ruled
2026-08-26, docs/deferred.md): columns are never compressed below what their
content needs, and the mac native tier was changed to honour it. This survey
asks what the rest of the world does when that floor exceeds the screen, and
which answers are implementable on all four of kaya's backends.

STATUS: complete. Every API name, version and quotation below was verified
against a primary source, with the URL beside it. The report is explicit about
the handful of things that could NOT be verified — they are listed at the end
and marked as inference where they are inference.

## 1. Native table behaviour when columns don't fit

### 1.1 SwiftUI `Table` on macOS

**Column width API.** `TableColumn` has two sizing modifiers: a fixed
`width(_:)` and a resizable `width(min:ideal:max:)`.

Source: <https://developer.apple.com/documentation/swiftui/tablecolumn/width(min:ideal:max:)>
(fetched as `.../tutorials/data/documentation/swiftui/tablecolumn/width(min:ideal:max:).json`)

> "Creates a resizable table column with the provided constraints."

> **min:** "The minimum width of a resizable column. If non-nil, the value must be greater than or equal to 0."

> **ideal:** "The ideal width of the column, used to determine the initial width of the table column. The column always starts at least as large as the set ideal size, but may be larger if table was sized larger than the ideal of all of its columns."

> **max:** "The maximum width of a resizable column. If non-nil, the value must be greater than 0. Pass infinity to indicate unconstrained maximum width."

> "Always specify at least one width constraint when calling this method. Pass nil or leave out a constraint to indicate no change to the sizing of a column."

> "To create a fixed size column use width(_:) instead."

Availability: iOS 16.0+, iPadOS 16.0+, Mac Catalyst 16.0+, macOS 12.0+, visionOS 1.0+.

Note the asymmetry in the `ideal` sentence: it describes the column growing
past ideal when the table is *wider* than the sum of ideals. It says nothing
about the table being *narrower* than the sum of minimums — that case is
documented nowhere in the `Table` or `TableColumn` reference. See §1.3 for what
the underlying AppKit control does, which is the operative behaviour.

### 1.2 SwiftUI `Table` on iOS — CONFIRMED: compact shows only the first column

This is the headline verification the question asked for. It is **true** and it
is stated in Apple's own `Table` documentation.

Source: <https://developer.apple.com/documentation/swiftui/table>
(fetched as `.../tutorials/data/documentation/swiftui/table.json`)

> "However, on iPhone or in a compact horizontal size class environment — typical on iPad in certain modes, like Slide Over — the table has limited space to display its columns. To conserve space, the table automatically hides headers and all columns after the first when it detects this condition."

And the recommended adaptation:

> "To provide a good user experience in a space-constrained environment, you can customize the first column to show more information when you detect that the `horizontalSizeClass` environment value becomes `compact`."

**Version:** `Table` is iOS 16.0+ / iPadOS 16.0+ / macOS 12.0+ / Mac Catalyst
16.0+ / visionOS 1.0+. So the compact collapse behaviour dates from iOS 16
(2022), the first release in which `Table` existed on iOS at all.

Two things to note for kaya's purposes:

- This is not clipping and it is not scrolling. It is **column dropping** —
  a documented, automatic, non-overridable degradation to a single column, and
  the headers go away with it. Apple's answer to "columns don't fit" on a phone
  is not to scroll: it is to stop being a table.
- The escape hatch Apple documents is entirely in the app's hands: put the
  extra fields into the first column's cell content yourself. There is no API
  to force the other columns to appear.

### 1.3 AppKit `NSTableView` — autoresizing styles and overflow

**The enum.** Source:
<https://developer.apple.com/documentation/appkit/nstableview/columnautoresizingstyle-swift.enum>

> "The following constants specify the autoresizing styles. These constants are used by the `columnAutoresizingStyle` property."

Cases, verbatim:

| Case | Documented description |
| --- | --- |
| `noColumnAutoresizing` | "Disable table column autoresizing." |
| `uniformColumnAutoresizingStyle` | "Autoresize all columns by distributing space equally, simultaneously." |
| `sequentialColumnAutoresizingStyle` | "Autoresize each table column sequentially, from the last auto-resizable column to the first auto-resizable column; proceed to the next column when the current column has reached its minimum or maximum size." |
| `reverseSequentialColumnAutoresizingStyle` | "Autoresize each table column sequentially, from the first auto-resizable column to the last auto-resizable column; proceed to the next column when the current column has reached its minimum or maximum size." |
| `lastColumnOnlyAutoresizingStyle` | "Autoresize only the last table column." |
| `firstColumnOnlyAutoresizingStyle` | "Autoresize only the first table column." |

**The default is `lastColumnOnlyAutoresizingStyle`.** Source:
<https://developer.apple.com/documentation/appkit/nstableview/columnautoresizingstyle-swift.property>

> "This property determines how columns are resized when the table view size changes. The default value of this property is `lastColumnOnlyAutoresizingStyle`."

AppKit's own header (`NSTableView.h`, MacOSX SDK) adds the scope note:

Source: <https://github.com/phracker/MacOSX-SDKs/blob/master/MacOSX10.13.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSTableView.h>

> "This controls resizing in response to a tableView frame size change, usually done by dragging a window larger that has an auto-resized tableView inside it."

and, on the two "only" styles:

> "Autoresize only one table column one at a time. When that table column can no longer be resized, stop autoresizing. Normally you should use one of the Sequential autoresizing modes instead."

**The floor that produces overflow.** This is the important mechanism, and it
is documented crisply:

Source: <https://developer.apple.com/documentation/appkit/nstablecolumn/minwidth>

> "The default value of this property is `10.0`."
>
> "The table column width can't be less than the value of this property, whether the column is resized by the user or programmatically. If the table column's current width is less than the value of this property, the width is set to the value of this property."

So a column's `minWidth` is a hard floor that no autoresizing style can violate.
Once the clip view is narrower than the sum of the columns' minimum widths, the
`NSTableView` (which is the scroll view's *document view*) is simply wider than
the clip view. The scroll view then does what any scroll view does:

Source: <https://developer.apple.com/documentation/appkit/nsscrollview/autohidesscrollers>

> "The horizontal and vertical scroll bars are hidden independently of each other. When the value of this property is `true` and the content of the scroll view doesn't extend beyond the size of the clip view on a given axis, the scroller on that axis is removed to leave more room for the content."

Source: <https://developer.apple.com/documentation/appkit/nsscrollview/hashorizontalscroller>

> "When the value of this property is `true`, the scroll view allocates and displays a horizontal scroller as needed. The default value of this property is `false`."

Note the default of `hasHorizontalScroller` is `false` on a bare `NSScrollView`;
Interface Builder and `NSTableView`'s own scroll-view template turn it on. And:

Source: <https://developer.apple.com/documentation/appkit/nstableview/sizelastcolumntofit()>

> "Resizes the last column so the table view fits exactly within its enclosing clip view."

**What I can and cannot assert here.** Apple documents each of these pieces —
a hard per-column minimum, a document view that can exceed the clip view, a
horizontal scroller shown "as needed" — but I could **not** find a single Apple
sentence that says in so many words "an NSTableView whose columns exceed the
scroll view's width scrolls horizontally." Apple's own conceptual guide only
goes as far as:

Source: <https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TableView/TableViewOverview/TableViewOverview.html>

> "These two classes aren't part of the table view—nor are they required—but virtually all table views are displayed using the classes that make up the scroll view mechanism."

and on the column's role:

> [NSTableColumn is] "responsible for managing the horizontal position and the width of the cells of the table. Columns can be configured to allow resizing, re-ordering, and content sorting..."

So: **horizontal scrolling of an overflowing NSTableView is a consequence of
documented per-piece behaviour, not a directly documented behaviour.** Treat it
as strongly implied rather than quoted. `.noColumnAutoresizing` specifically is
documented only as "Disable table column autoresizing" — meaning the columns keep
whatever widths they were given when the frame changes, which is exactly the
configuration that produces a wider-than-clip-view document view.

### 1.4 GTK4 `GtkColumnView` inside `GtkScrolledWindow`

**GtkColumnView is itself scrollable — it implements `GtkScrollable`.**

Source: <https://docs.gtk.org/gtk4/class.ColumnView.html>

> "Presents a large dynamic list of items using multiple columns with headers."

> "The column view also supports interactive resizing and reordering of columns, via Drag-and-Drop of the column headers. This can be enabled or disabled with the `GtkColumnView:reorderable` and `GtkColumnViewColumn:resizable` properties."

The class implements `GtkScrollable` (it exposes `gtk_scrollable_get_hadjustment()`
and `gtk_scrollable_get_vadjustment()`), which is what lets a `GtkScrolledWindow`
scroll it natively in **both** axes rather than wrapping it in a viewport.

**Column sizing vocabulary.** Source:
<https://docs.gtk.org/gtk4/class.ColumnViewColumn.html>

> **expand:** "Column gets share of extra width allocated to the view."

> **fixed-width:** "If not -1, this is the width that the column is allocated, regardless of the size of its content."

> **resizable:** "Whether this column is resizable."

So GTK gives you exactly the two knobs kaya would need: a per-column fixed width,
and an "absorb the slack" flag. Note that `expand` is about *extra* width — the
overflow direction is governed by each column's minimum/natural size (or its
`fixed-width`), not by `expand`.

**The scroll policy.** Source: <https://docs.gtk.org/gtk4/class.ScrolledWindow.html>

> "Makes its child scrollable."

> **hscrollbar-policy:** "When the horizontal scrollbar is displayed."
> **vscrollbar-policy:** "When the vertical scrollbar is displayed."

> "If it isn't [a GtkScrollable], then it wraps the child in a GtkViewport."

> **propagate-natural-width:** "the natural width of the child will be calculated and propagated through the scrolled window's requested natural width."

`propagate-natural-width` matters for kaya: left at its default (`FALSE`), the
scrolled window requests a minimal width and the table happily overflows and
scrolls; set `TRUE`, the scrolled window asks the layout for the table's full
natural width, which is how you'd get "don't scroll until you really must".

### 1.5 WinUI 3 / Windows Community Toolkit `DataGrid`

**First, the availability problem — this is a surprise worth flagging.** The
Community Toolkit `DataGrid` is **not** shipped for WinUI 3 in the current
toolkit.

Source: <https://learn.microsoft.com/en-us/windows/communitytoolkit/controls/datagrid>
(raw: <https://github.com/MicrosoftDocs/WindowsCommunityToolkitDocs/blob/main/docs/controls/DataGrid.md>)

> "The DataGrid control provides a flexible way to display a collection of data in rows and columns."

> "The DataGrid control is not part of the WinUI 3 controls available in the Windows Community Toolkit version 8.0 and later yet."

It is available for UWP and Uno in toolkit 7.1.0, and there is a
`CommunityToolkit.WinUI.UI.Controls.DataGrid` 7.1.x package that WinUI 3 apps
have used. WinUI 3 itself has **no** built-in DataGrid — there is no
`Microsoft.UI.Xaml.Controls.DataGrid`. (I verified the absence by the toolkit
doc's own sentence above plus the absence of such a type in the WinUI control
list; I did **not** find a Microsoft sentence that says "WinUI 3 has no
DataGrid" in those words, so treat that as inference from the toolkit's
statement.)

**Column sizing modes.** Source:
<https://learn.microsoft.com/en-us/windows/communitytoolkit/controls/datagrid_guidance/sizing_options>

> "The DataGrid uses values of the **DataGridLength** and the **DataGridLengthUnitType** structure to specify absolute or automatic sizing modes."

| Name | Documented description |
| --- | --- |
| Auto | "The default automatic sizing mode sizes DataGrid columns based on the contents of both cells and column headers." |
| SizeToCells | "The cell-based automatic sizing mode sizes DataGrid columns based on the contents of cells in the column, not including column headers." |
| SizeToHeader | "The header-based automatic sizing mode sizes DataGrid columns based on the contents of column headers only." |
| Pixel | "The pixel-based sizing mode sizes DataGrid columns based on the numeric value provided." |
| Star | "The star sizing mode is used to distribute available space by weighted proportions. In XAML, star values are expressed as n\* where n represents a numeric value. 1\* is equivalent to \*. For example, if two columns in a DataGrid had widths of \* and 2\*, the first column would receive one portion of the available space and the second column would receive two portions of the available space." |

Defaults and growth:

> "By default, the **DataGrid.ColumnWidth** property is set to Auto, and the **DataGridColumn.Width** property is null. When the sizing mode is set to Auto or SizeToCells, columns will grow to the width of their widest visible content. When scrolling, these sizing modes will cause columns to expand if content that is larger than the current column size is scrolled into view. The column will not shrink after the content is scrolled out of view."

Per-column bounds (this is the same "hard floor" mechanism AppKit has):

> | Property | Description |
> | DataGrid.MaxColumnWidth | Sets the upper bound for all columns in the DataGrid. |
> | DataGridColumn.MaxWidth | Sets the upper bound for an individual column. Overrides DataGrid.MaxColumnWidth. |
> | DataGrid.MinColumnWidth | Sets the lower bound for all columns in the DataGrid. |
> | DataGridColumn.MinWidth | Sets the lower bound for an individual column. Overrides DataGrid.MinColumnWidth. |
> | DataGrid.ColumnWidth | Sets a specific width for all columns in the DataGrid. |
> | DataGridColumn.Width | Sets a specific width for an individual column. Overrides DataGrid.ColumnWidth. |

**Overflow behaviour, documented indirectly but decisively.** The doc's warning
about unconstrained containers tells you the model: the DataGrid sizes to its
content and *scrolls* only when its own size is constrained.

> "By default, the **Height** and **Width** properties of the DataGrid are set to *Double.NaN* ("Auto" in XAML), and the DataGrid will adjust to the size of its contents."

> "When placed inside a container that does not restrict the size of its children, such as a StackPanel, the DataGrid, like ListView and other scrollable controls, will stretch beyond the visible bounds of the container and scrollbars will not be shown. This condition has both usability and performance implications."

> "To avoid these issues when you work with large data sets, it is recommended that you specifically set the Height of the DataGrid or place it in a container that will restrict its Height, such as a Grid or RelativePanel."

That paragraph is about Height, but the same Width row exists in its sizing
table ("MinWidth — Sets the lower bound for the width of the DataGrid. The
DataGrid will shrink horizontally until it reaches this width."), and the
control is described as one of the "scrollable controls". So: a constrained
DataGrid whose columns exceed its width scrolls horizontally; an unconstrained
one grows and shows no scrollbar.

**Frozen columns ship as a first-class feature.** This is the strongest primary
source for the "frozen first column" pattern anywhere in this report:

Source: <https://learn.microsoft.com/en-us/dotnet/api/microsoft.toolkit.uwp.ui.controls.datagrid.frozencolumncount>

> "Gets or sets the number of columns that the user cannot scroll horizontally."

**User resizing:**

> "Users can resize DataGrid columns by dragging the column header dividers with mouse/touch/pen. The DataGrid does not support automatic resizing of columns by double-clicking the column header divider."

### 1.6 Jetpack Compose — there is no data table, and Material 3 dropped the component

**Material 3 has no data table component.** Google's own Material Web repository
answered this directly, and closed the request as not planned.

Source: <https://github.com/material-components/material-web/issues/4052>

Issue title: "Are Data Tables coming to Material 3?"
Body: "I'm only finding Data Table component in Material 2"
State: **closed as `not_planned`**.

Maintainer (`asyncliz`, a Material Web collaborator) reply, verbatim:

> "Yup! Closing this for now"

and a collaborator (`bivens-dev`) before that:

> "Take a look at the Readme file. Yes but not for 1.0"

Data tables **do** exist in Material 2. Flutter's own `DataTable` documentation
says so in its first sentence (see §1.7), which is the cleanest primary
attestation that data tables are an M2 component:

> "A data table that follows the Material 2 design specification."

(<https://api.flutter.dev/flutter/material/DataTable-class.html>)

I could **not** fetch `m3.material.io` or `m2.material.io` directly — both are
JavaScript single-page apps that return an empty body. So I have not quoted the
Material 2 data-table *spec text* on responsive behaviour.

**But I did get Google's own Material 2 implementation, which answers the
question in code.** `mdc-data-table` is Material Components Web's data table,
built to the M2 spec, and its stylesheet states the policy outright.

Source: <https://github.com/material-components/material-components-web/blob/master/packages/mdc-data-table/_data-table.scss>

> ```scss
> .mdc-data-table__table-container {
>   // Makes the table scroll smoothly in iOS.
>   -webkit-overflow-scrolling: touch;
>   overflow-x: auto;
>   width: 100%;
> }
>
> .mdc-data-table__table {
>   min-width: 100%; // Makes table full-width of its container (Firefox / IE11)
>   border: 0;
>   white-space: nowrap;
>   border-spacing: 0;
>   /**
>    * With table-layout:fixed, table and column widths are defined by the width
>    * of the first row of cells. Cells in subsequent rows do not affect column
>    * widths. This results in a predictable table layout and may also speed up
>    * rendering.
>    */
>   table-layout: fixed;
> }
> ```

And the README describes the container's purpose in words
(<https://github.com/material-components/material-components-web/blob/master/packages/mdc-data-table/README.md>):

> `mdc-data-table__table-container` is "used for horizontal overflowing of table content."

Plus the sticky header, from
`_data-table-header-cell.scss`:

> ```scss
> /// Sets header cell in sticky position on table content vertical scroll.
> @mixin header-cell-sticky($query: $query) {
>   .mdc-data-table__header-cell {
>     position: sticky;
>     top: 0;
>     z-index: 1;
>   }
> }
> ```

with the README's modifier:

> "mdc-data-table--sticky-header | Optional. Modifier class name added to root element to make header row sticky (fixed) on vertical scroll."

**So Material's own answer — in the generation that had data tables at all — is
exactly the consensus policy: `white-space: nowrap` so columns never compress
by wrapping, a container with `overflow-x: auto`, and a header that sticks
vertically while riding the horizontal scroll (which `position: sticky; top: 0`
does automatically, since it only pins on the block axis).**

**Compose itself has no Table.** Verified by listing the entire
`androidx.compose.material3` common source directory:

Source: <https://github.com/androidx/androidx/tree/androidx-main/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3>

The directory contains `Tab.kt` and `TabRow.kt` but **no** `Table.kt` and no
`DataTable.kt` (alphabetically both would sit in the listed range, so their
absence is a real absence, not truncation). There is likewise no table in
`androidx.compose.foundation` — that package's list is `Background.kt`,
`BasicMarquee.kt`, `BasicTooltip.kt`, `Border.kt`, `BorderStroke.kt`,
`Canvas.kt`, `CheckScrollableContainerConstraints.kt`, `Clickable.kt`,
`ClipScrollableContainer.kt`, `ComposeFoundationFlags.kt`, `DarkTheme.kt`,
`Expect.kt`, `ExperimentalFoundationApi.kt`, `Focusable.kt`, `FocusedBounds.kt`,
`GestureNode.kt`, `Hoverable.kt`, `Image.kt`, `Indication.kt`,
`InternalFoundationApi.kt`, `MutatorMutex.kt`, `Overscroll.kt`,
`ProgressSemantics.kt`, `Scroll.kt`.

**So on Compose there is no framework default to inherit. Whatever kaya does IS
the behaviour.** The community pattern (a `LazyColumn` whose rows carry
`Modifier.horizontalScroll` sharing one `ScrollState`, with a header `Row`
sharing the same state) is widely used but is **not** documented by Google as an
official pattern — I found only blog posts for it, not primary sources, so I am
not citing it as guidance. The *primitives* it is built from are documented; see
§4.

### 1.7 Flutter `DataTable` — it clamps, then it overflows

Source: <https://api.flutter.dev/flutter/material/DataTable-class.html>

> "A data table that follows the Material 2 design specification."

> "Columns are sized automatically based on the table's contents. It's expensive to display large amounts of data with this widget, since it must be measured twice: once to negotiate each column's dimensions, and again when the table is laid out."

> "A SingleChildScrollView mounts and paints the entire child, even when only some of it is visible."

> "For a table that effectively handles large amounts of data, here are some other options to consider: `TableView`, a widget from the two_dimensional_scrollables package. PaginatedDataTable, which automatically splits the data into multiple pages. CustomScrollView, for greater control over scrolling effects."

Note that the `SingleChildScrollView` sentence appears in a *performance
caution* — Flutter's own docs mention the wrapper only to warn about it, which
is indirect confirmation that wrapping in a scroll view is the assumed practice.

**What actually happens on overflow — read from Flutter's own source.** `DataTable`
builds a `Table`, and every column defaults to `IntrinsicColumnWidth`:

Source: <https://github.com/flutter/flutter/blob/master/packages/flutter/lib/src/material/data_table.dart>

> "If this property is `null`, the table applies a default behavior:
> - If the table has exactly one column identified as the only text column (i.e., all the rest are numeric), that column uses `IntrinsicColumnWidth(flex: 1.0)`.
> - All other columns use `IntrinsicColumnWidth()`."

And `RenderTable._computeColumnWidths` states its algorithm in a comment:

Source: <https://github.com/flutter/flutter/blob/master/packages/flutter/lib/src/rendering/table.dart>

> "// We apply the constraints to the column widths in the order of
> // least important to most important:
> // 1. apply the ideal widths (maxIntrinsicWidth)
> // 2. grow the flex columns so that the table has the maxWidth (if finite) or the minWidth (if not)
> // 3. if there were no flex columns, then grow the table to the minWidth.
> // 4. apply the maximum width of the table, shrinking columns as necessary, applying minimum column widths as we go"

Step 4's inner loop:

> "// Now we have to take out the remaining space from the
> // columns that aren't minimum sized.
> // To make this fair, we repeatedly remove equal amounts from
> // each column, clamped to the minimum width, until we run out
> // of columns that aren't at their minWidth."

and `performLayout` ends with:

> `size = constraints.constrain(Size(_tableWidth, rowTop));`

I grepped `rendering/table.dart` for `clipBehavior`, `Clip.`,
`paintOverflowIndicator` and `debugOverflow`: **zero occurrences of each**.

So the sequence is: **shrink columns to fit, floor at each column's minimum
intrinsic width, and once that floor is hit, keep positioning cells past the
constrained box and paint them outside it** — no clip, no scroll, no overflow
indicator from the table itself. Flutter's answer is "clamp, then spill."

**`data_table_2` exists to fix exactly this**, which is useful corroboration
that the stock behaviour is inadequate. Source: <https://pub.dev/packages/data_table_2>

> "In-place substitute for Flutter's stock **DataTable** and **PaginatedDataTable** widgets with fixed/sticky header/top rows and left columns."

> "You can limit the minimal width of the control and scroll it horizontally if the viewport is narrower (by setting `minWidth` property)."

> "All columns are fixed width, table automatically stretches horizontally"

> "Fixed width columns are faster than default implementation of DataTable which does 2 passes to determine contents size and justify column widths."

That package's `minWidth` is precisely the policy this research is looking for:
**a declared minimum content width, below which the table scrolls horizontally
rather than compressing further.**

### 1.8 Summary of §1

| Framework | Default when columns exceed the viewport | Developer control |
| --- | --- | --- |
| SwiftUI `Table`, macOS | Columns shrink to their minimums; beyond that the table is wider than the clip view and the scroll view scrolls (inferred from AppKit pieces, not directly documented) | `width(_:)` fixed, `width(min:ideal:max:)` |
| SwiftUI `Table`, iOS compact | **Hides headers and every column after the first.** Documented, automatic, no opt-out | Put extra fields into the first column yourself |
| AppKit `NSTableView` | `minWidth` is a hard floor; document view exceeds clip view; horizontal scroller appears "as needed" | 6 `ColumnAutoresizingStyle` values, default `lastColumnOnly` |
| GTK4 `GtkColumnView` | Implements `GtkScrollable`; a `GtkScrolledWindow` scrolls it in both axes | `fixed-width`, `expand`, `resizable`; `hscrollbar-policy` |
| WinUI 3 | **No table control at all.** WCT `DataGrid` is not shipped for WinUI 3 in toolkit 8.0+ | (WCT 7.1.x: `Auto`/`SizeToCells`/`SizeToHeader`/`Pixel`/`Star`, `MinWidth`/`MaxWidth`, `FrozenColumnCount`) |
| Jetpack Compose | **No table component at all**, in foundation or material3; M3 dropped data tables | Whatever you build |
| Flutter `DataTable` | Shrinks to minimum intrinsic widths, then paints outside its own box — no clip, no scroll, no overflow indicator | `DataColumn.columnWidth`; wrap in `SingleChildScrollView`; or use `data_table_2`'s `minWidth` |

**The one thing every framework that solves this agrees on:** a per-column
minimum plus horizontal scrolling of the whole grid once the minimums no longer
fit. The frameworks that *don't* solve it either drop columns (SwiftUI iOS) or
spill (Flutter).

---

## 2. The web's answer: `overflow-x: auto` on a wrapper

### 2.1 It is still the mainstream recommendation

The clearest primary source is Bootstrap, which ships this as its entire
responsive-table feature.

Source: <https://getbootstrap.com/docs/5.3/content/tables/>

> "Responsive tables allow tables to be scrolled horizontally with ease. Make any table responsive across all viewports by wrapping a `.table` with `.table-responsive`."

> "Or, pick a maximum breakpoint with which to have a responsive table up to by using `.table-responsive{-sm|-md|-lg|-xl|-xxl}`."

Bootstrap also documents the gotcha, which is worth carrying into kaya's
thinking because a clipping scroll container clips *everything*:

> "Responsive tables make use of `overflow-y: hidden`, which clips off any content that goes beyond the bottom or top edges of the table. In particular, this can clip off dropdown menus and other third-party widgets."

**Note:** Bootstrap's responsive-tables section contains **no** accessibility
note about `tabindex` or keyboard access on the scrolling wrapper. I looked
specifically. That omission is itself a finding — the most-copied
implementation of this pattern ships without the keyboard fix described below.

The CSS mechanism, from MDN:

Source: <https://developer.mozilla.org/en-US/docs/Web/CSS/overflow-x>

> "The **`overflow-x`** CSS property sets what shows when content overflows a block-level element's left and right edges. This may be nothing, a scroll bar, or the overflow content."

> **`auto`**: "Overflow content is clipped at the element's padding box, and overflow content can be scrolled into view. Unlike `scroll`, user agents display scroll bars _only if_ the content is overflowing and hide scroll bars by default."

> **`scroll`**: "Overflow content is clipped if necessary to fit horizontally inside the element's padding box. Browsers display scroll bars in the horizontal direction whether or not any content is actually clipped. (This prevents scroll bars from appearing or disappearing when the content changes.)"

`auto` versus `scroll` is a real design choice for kaya too: `scroll` reserves
the gutter permanently so the layout does not reflow when the overflow state
flips.

### 2.2 A scrollable region must be keyboard-focusable — this is the accessibility point

**MDN states the rule directly.** Source:
<https://developer.mozilla.org/en-US/docs/Web/CSS/overflow> (Accessibility section)

> "In some browsers, scrolling content areas are not keyboard-focusable, so they cannot be scrolled by a keyboard-only user. To ensure all keyboard-only users can scroll the container, enable the element to receive focus by setting `tabindex="0"` on the container. To give screen reader users context when the container receives focus, set an appropriate WAI-ARIA role on the container, such as `role="region"`, and an accessible name using the `aria-label` or `aria-labelledby` attribute."

**W3C's own ACT rule says the same normatively.** Source:
<https://www.w3.org/WAI/standards-guidelines/act/rules/0ssw9k/>

Rule name: "Scrollable content can be reached with sequential focus navigation"

> "scrollable elements or their descendants can be reached with sequential focus navigation so that they can be scrolled by keyboard."

Expectation:

> "Each test target is either included in sequential focus navigation or has a descendant in the flat tree that is included in sequential focus navigation."

It maps to **WCAG 2.1.1 Keyboard (Level A)** and 2.1.3 (Level AAA), and to
technique G202 "Ensuring keyboard control for all functionality".

WCAG 2.1.1 itself, verbatim from the standard
(<https://www.w3.org/TR/WCAG22/>):

> "All functionality of the content is operable through a keyboard interface without requiring specific timings for individual keystrokes, except where the underlying function requires input that depends on the path of the user's movement and not just the endpoints."

**For kaya this means:** whatever surface scrolls horizontally must be reachable
by keyboard and must respond to arrow keys, on every backend. It is not enough
to make the pixels scroll. Note that in kaya's case the table rows are already
focusable content, which satisfies the ACT rule's "or has a descendant in the
flat tree that is included in sequential focus navigation" clause — but the
*header* row and any empty state would not.

### 2.3 WCAG 1.4.10 Reflow — and data tables are an explicit exception

**The normative text**, verbatim from
<https://www.w3.org/TR/WCAG22/> (SC 1.4.10, Level AA):

> "Content can be presented without loss of information or functionality, and without requiring scrolling in two dimensions for: Vertical scrolling content at a width equivalent to 320 CSS pixels; Horizontal scrolling content at a height equivalent to 256 CSS pixels. **Except for parts of the content which require two-dimensional layout for usage or meaning.**"

**Your belief is correct: data tables are named in the exception.** From
<https://www.w3.org/WAI/WCAG22/Understanding/reflow.html>:

> "Examples of content which requires two-dimensional layout are images required for understanding (such as maps and diagrams), video, games, presentations, **data tables (not individual cells)**, and interfaces where it is necessary to keep toolbars in view while manipulating content."

And the Understanding document spells out the reasoning specifically for tables:

> "Data tables and grids have a two-dimensional relationship between column and row headers and their data cells. This success criterion therefore has exceptions for data tables and grids from needing to display without scrolling in the direction of text. However, individual cells would still need to meet Reflow."

The rationale for the criterion generally:

> "When lines of text extend beyond the edge of a viewport, users will be forced to scroll back-and-forth to read line by line. This can cause them to lose their place and can significantly increase both physical and cognitive effort."

**What this licenses for kaya.** Two-dimensional scrolling of a data table is
explicitly permitted at AA. So "the table scrolls horizontally while the rows
scroll vertically" is not an accessibility compromise — it is the accommodation
the standard carved out. But the carve-out is narrow in two ways worth
respecting:

1. **"not individual cells"** — a single cell's *contents* must still reflow.
   A cell holding a long string may not force horizontal scrolling of its own.
2. The exception covers the *table*, not the chrome around it. Toolbars,
   filters and the empty state still owe Reflow.

---

## 3. The named responsive-table patterns

Four patterns are named in the literature. Each is cited below to a framework or
library that ships it **as a feature**, not to a blog post describing it.

### 3.1 Horizontal scroll (the "swipe" pattern)

**Bootstrap `.table-responsive`** — <https://getbootstrap.com/docs/5.3/content/tables/>

> "Responsive tables allow tables to be scrolled horizontally with ease. Make any table responsive across all viewports by wrapping a `.table` with `.table-responsive`."

**Tablesaw "Swipe"** (Filament Group) — <https://github.com/filamentgroup/tablesaw>

> "Allows the user to use the swipe gesture (or use the left and right buttons) to navigate the columns."

**PrimeNG / PrimeReact `responsiveLayout="scroll"`** — and this is the notable
one, because it is a library that *changed its mind* and made scroll the only
supported answer. From PrimeNG's own source
(<https://github.com/primefaces/primeng/blob/master/packages/primeng/src/table/table.ts>):

> ```
> /**
>  * Defines the responsive mode, valid options are "stack" and "scroll".
>  * @deprecated since v20.0.0, always defaults to scroll, stack mode needs custom implementation
>  * @group Props
>  */
> @Input() responsiveLayout: string = 'scroll';
> ```

And PrimeReact's
(<https://github.com/primefaces/primereact/blob/master/components/lib/datatable/datatable.d.ts>):

> ```
> /**
>  * Defines the responsive mode, valid options are "stack" and "scroll".
>  * @defaultValue scroll
>  * @deprecated since version 9.2.0
>  */
> responsiveLayout?: 'scroll' | 'stack' | undefined;
> ```

**Read that carefully:** PrimeNG shipped both stack and scroll, made scroll the
default, then deprecated the option entirely with the note "stack mode needs
custom implementation." A mature component library converged on horizontal
scroll and pushed collapse-to-cards out of the framework.

### 3.2 Column priority / progressive disclosure

**DataTables Responsive extension** — <https://datatables.net/extensions/responsive/>

> "Responsive is an extension for DataTables that resolves that problem by optimising the table's layout for different screen sizes through the dynamic insertion and removal of columns from the table."

> "Full control over column visibility at breakpoints, or automatic visibility."

The priority mechanism — <https://datatables.net/extensions/responsive/priority>

> "Responsive will automatically hide columns in a table so that the table fits horizontally into the space given to it."

> "Priority order in Responsive is a numerical value, where a lower value equates to a higher priority."

> "Columns are automatically assigned a priority value of 10'000, which is used unless configured otherwise."

> "If multiple columns share the same priority value, the rightmost will be removed first."

**Tablesaw "Column Toggle"** — <https://github.com/filamentgroup/tablesaw>

> "The Column Toggle Table allows the user to select which columns they want to be visible."

> "Table headers must have a `data-tablesaw-priority` attribute to be eligible to toggle. `data-tablesaw-priority` is a numeric value from 1 to 6, which determine default breakpoints at which a column will show."

> "Keep in mind that the priorities are not exclusive—multiple columns can reuse the same priority value."

**Note that SwiftUI's iOS behaviour (§1.2) is a degenerate case of this
pattern:** priority = column order, and everything but priority 1 is dropped at
compact width, with no gradation and no way for the user to get the hidden
columns back.

### 3.3 Collapse to cards / stacked rows

**Tablesaw "Stack"** — <https://github.com/filamentgroup/tablesaw>

> "The Stack Table stacks the table headers to a two column layout with headers on the left when the viewport width is less than `40em` (`640px`)."

**DataTables Responsive child rows** — <https://datatables.net/extensions/responsive/>

> "Collapsed information from the table shown in a child row"

This is the half-way version: the row stays a row, and the columns that were
dropped reappear in an expandable detail row underneath.

**Deprecated in PrimeNG/PrimeReact**, as quoted in §3.1. Worth weighting: the
pattern reads well in design articles and has been retired by at least one large
library on the grounds that it needs a custom implementation per table.

### 3.4 Frozen / pinned first column

This one has the most first-party support of the four.

**Windows Community Toolkit `DataGrid.FrozenColumnCount`** —
<https://learn.microsoft.com/en-us/dotnet/api/microsoft.toolkit.uwp.ui.controls.datagrid.frozencolumncount>

> "Gets or sets the number of columns that the user cannot scroll horizontally."

**AG Grid column pinning** — <https://www.ag-grid.com/javascript-data-grid/column-pinning/>

> "You can pin columns by setting the `pinned` attribute on the column definition to either `'left'` or `'right'`."

> "The grid will reorder the columns so that 'left pinned' columns come first and 'right pinned' columns come last."

**DataTables FixedColumns extension** — <https://datatables.net/extensions/fixedcolumns/>

> "Freezes the column(s) to the start and / or end of the table"

**Flutter `data_table_2`** — <https://pub.dev/packages/data_table_2>

> "In-place substitute for Flutter's stock **DataTable** and **PaginatedDataTable** widgets with fixed/sticky header/top rows and left columns."

### 3.5 The accessible-scroll-container recipe (design literature)

Adrian Roselli's "Under-Engineered Responsive Tables" is the canonical write-up
of pattern 3.1 done accessibly. This is design literature, not a standard, and
is flagged as such — but its markup is what the MDN and W3C guidance in §2.2
adds up to.

Source: <https://css-tricks.com/under-engineered-responsive-tables/>

> ```html
> <div role="region" aria-labelledby="Caption01" tabindex="0">
>   <table>
>     <caption id="Caption01">Appropriate caption</caption>
>     <!-- ...  -->
>   </table>
> </div>
> ```

> ```css
> [role="region"][aria-labelledby][tabindex] {
>   overflow: auto;
> }
> [role="region"][aria-labelledby][tabindex]:focus {
>   outline: .1em solid rgba(0,0,0,.1);
> }
> ```

> "The wrapping `<div>` needs to be focusable and labelled."

The article does not itself cite WCAG SC numbers; §2.2 supplies those.

---

## 4. Horizontal scrolling primitives on the four target toolkits

All four exist. All four can do two-dimensional scrolling of one surface. The
idioms differ, and three of the four have a gotcha.

### 4.1 SwiftUI — `ScrollView(.horizontal)`, and both axes at once

Source: <https://developer.apple.com/documentation/swiftui/scrollview>

> "The scroll view displays its content within the scrollable content region. As the user performs platform-appropriate scroll gestures, the scroll view adjusts what portion of the underlying content is visible. **ScrollView can scroll horizontally, vertically, or both**, but does not provide zooming functionality."

`axes` parameter: "The scrollable axes of the scroll view."

Two-dimensional is a documented, first-class configuration; Apple's own example
in that page is:

> ```swift
> ScrollView([.horizontal, .vertical]) {
>     // initially centered content
> }
> .defaultScrollAnchor(.center)
> ```

> "Provide a value of center to have the scroll view start in the center of its content when a scroll view is scrollable in both axes."

Availability: iOS 13.0+, macOS 10.15+, visionOS 1.0+.

**Gotcha for kaya:** a `ScrollView` measures its content unbounded on the
scrolling axis. Putting a `LazyVStack` of 100k rows inside a two-axis scroll
view is fine (lazy), but the *width* must be resolved from the columns rather
than from the viewport, or every row will size itself to the viewport and the
horizontal axis will have nothing to scroll.

### 4.2 Compose — `Modifier.horizontalScroll`

Source: <https://github.com/androidx/androidx/blob/androidx-main/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/Scroll.kt>

> "Modify element to allow to scroll horizontally when width of the content is bigger than max constraints allow."

and its sibling:

> "Modify element to allow to scroll vertically when height of the content is bigger than max constraints allow."

`@param reverseScrolling`: "reverse the direction of scrolling, when `true`, 0 [ScrollState.value] will mean right, when `false`, 0 [ScrollState.value] will mean left"

**Two-dimensional scrolling on Compose: yes, but only in the orthogonal-mixing
form, and this is the toolkit's biggest trap.** Applying
`Modifier.verticalScroll` to an ancestor of a `LazyColumn` **throws at
measure time**. From Compose's own source:

Source: <https://github.com/androidx/androidx/blob/androidx-main/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/CheckScrollableContainerConstraints.kt>

> ```
> "Vertically scrollable component was measured with an infinity maximum height " +
>     "constraints, which is disallowed. One of the common reasons is nesting layouts " +
>     "like LazyColumn and Column(Modifier.verticalScroll()). If you want to add a " +
>     "header before the list of items please add a header as a separate item() before " +
>     "the main items() inside the LazyColumn scope. There could be other reasons " +
>     "for this to happen: your ComposeView was added into a LinearLayout with some " +
>     "weight, you applied Modifier.wrapContentSize(unbounded = true) or wrote a " +
>     "custom layout. Please try to remove the source of infinite constraints in the " +
>     "hierarchy above the scrolling container."
> ```

and the identical horizontal message for `LazyRow` inside
`Row(Modifier.horizontalScroll())`. The KDoc on the check function:

> "@throws [IllegalStateException] if the container was measured with the infinity constraints in the direction of scrolling. This usually means nesting scrollable in the same direction containers which is a performance issue and is discouraged."

**Read the constraint precisely:** the ban is on nesting scrollables *in the
same direction*. `LazyColumn` (vertical, lazy) with `Modifier.horizontalScroll`
applied to each row and to the header — **orthogonal directions** — is legal and
is the standard construction. What is illegal is `Column(verticalScroll)`
wrapping a `LazyColumn`.

### 4.3 GTK4 — `GtkScrolledWindow` policies, and `GtkColumnView` already does this

Source: <https://docs.gtk.org/gtk4/class.ScrolledWindow.html>

> "Makes its child scrollable."
> **hscrollbar-policy:** "When the horizontal scrollbar is displayed."
> **vscrollbar-policy:** "When the vertical scrollbar is displayed."

Source: <https://docs.gtk.org/gtk4/enum.PolicyType.html>

> "Determines how the size should be computed to achieve the one of the visibility mode for the scrollbars."

> **GTK_POLICY_ALWAYS**: "The scrollbar is always visible. The view size is independent of the content."
> **GTK_POLICY_AUTOMATIC**: "The scrollbar will appear and disappear as necessary. For example, when all of a `GtkTreeView` can not be seen."
> **GTK_POLICY_NEVER**: "The scrollbar should never appear. In this mode the content determines the size."
> **GTK_POLICY_EXTERNAL**: "Don't show a scrollbar, but don't force the size to follow the content. This can be used e.g. to make multiple scrolled windows share a scrollbar."

Two-dimensional: yes, natively, because `GtkColumnView` implements
`GtkScrollable` and exposes both adjustments. **GTK is the one backend where
the whole policy is already implemented in the toolkit** — see §5.3 for the
source reading.

### 4.4 WinUI — `ScrollViewer.HorizontalScrollMode` / `HorizontalScrollBarVisibility`

Source: <https://learn.microsoft.com/en-us/uwp/api/windows.ui.xaml.controls.scrollviewer.horizontalscrollmode>

> "Gets or sets a value that determines how manipulation input influences scrolling behavior on the horizontal axis."

> "A value of the enumeration. The typical default (as set through the default template, not class initialization) is **Enabled**."

> "Scrolling behavior can also be set through a `ScrollViewer.HorizontalScrollMode` XAML attached property usage... This is for cases where the ScrollViewer is implicit, such as when the ScrollViewer exists in the default template for a GridView, and you want to be able to influence the scrolling behavior without accessing template parts."

Source: <https://learn.microsoft.com/en-us/uwp/api/windows.ui.xaml.controls.scrollviewer.horizontalscrollbarvisibility>

> "Gets or sets a value that indicates whether a horizontal ScrollBar should be displayed."

> "A ScrollBarVisibility value that indicates whether a horizontal ScrollBar should be displayed. **The default value is Disabled.**"

**Gotcha for kaya, and it is the sharpest one on this platform:** the *default*
of `HorizontalScrollBarVisibility` is `Disabled`, not `Auto`. A WinUI
`ScrollViewer` does **not** scroll horizontally unless you say so. This is the
mirror image of the CSS default, and it is exactly the kind of thing that ships
as "the last column is clipped." Both `HorizontalScrollMode` **and**
`HorizontalScrollBarVisibility` need setting; `Disabled` visibility overrides an
`Enabled` mode.

Two-dimensional: yes, a single `ScrollViewer` scrolls both axes when both modes
and both visibilities allow it.

### 4.5 Two-dimensional scrolling — verdict per toolkit

| Toolkit | 2D of one surface? | Idiom |
| --- | --- | --- |
| SwiftUI | **Yes**, documented | `ScrollView([.horizontal, .vertical])` |
| Compose | **Yes**, but only with orthogonal mixing | `LazyColumn` + per-row `Modifier.horizontalScroll(sharedState)`; a same-direction nest throws |
| GTK4 | **Yes**, natively | `GtkScrolledWindow` + `GtkColumnView` (implements `GtkScrollable`, both adjustments) |
| WinUI 3 | **Yes** | one `ScrollViewer`, but horizontal is **off by default** |

**No toolkit here is unable to do it.** The floor is implementable on all four.

---

## 5. Frozen / sticky headers under horizontal scroll

The requirement is asymmetric and easy to state: **the header must scroll
horizontally with the body and must NOT scroll vertically with it.**

### 5.1 SwiftUI

`Table` supplies its own header and handles this internally on macOS (and hides
it entirely in compact, §1.2). For a hand-built table inside a `ScrollView`,
the mechanism is pinned section headers:

Source: <https://developer.apple.com/documentation/swiftui/pinnedscrollableviews>

> "A set of view types that may be pinned to the bounds of a scroll view."
> **sectionHeaders:** "The header view of each `Section` will be pinned."
> **sectionFooters:** "The footer view of each `Section` will be pinned."

Availability: iOS 14.0+, macOS 11.0+, visionOS 1.0+.

**Gotcha:** `pinnedViews:` pins along the *lazy stack's* axis. A
`LazyVStack(pinnedViews: .sectionHeaders)` pins vertically, which is the half
you want; the horizontal half comes for free only if the header is inside the
same horizontally-scrolling container as the rows. If you place the header
outside the horizontal scroll view to keep it vertically fixed, you must then
drive its horizontal offset yourself.

### 5.2 Compose

Source: <https://github.com/androidx/androidx/blob/androidx-main/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/lazy/LazyDsl.kt>

> "Adds a sticky header item, which will remain pinned even when scrolling after it. The header will remain pinned until the next header will take its place."

(No `@ExperimentalFoundationApi` on the current overload — it is stable API.)

**Gotcha, and it is the one that bites:** `stickyHeader` pins *vertically*
inside the `LazyColumn`. The horizontal offset is a *separate* concern carried
by whatever `ScrollState` the row content uses. If the header composable and
the row composables do not share **the same `ScrollState` instance**, the
header and the body drift apart the moment the user scrolls sideways. The
sharing is manual — Compose gives you no "table" abstraction that ties them
(§1.6). This is the single most likely place for kaya's Compose backend to be
subtly wrong.

### 5.3 GTK — already correct, and the source says exactly why

`GtkColumnView`'s CSS node tree makes `header` and `listview` siblings inside
one `columnview`:

Source: <https://gitlab.gnome.org/GNOME/gtk/-/blob/main/gtk/gtkcolumnview.c>

> ```
> columnview[.column-separators][.rich-list][.navigation-sidebar][.data-table]
> ├── header
> │   ├── <column header>
> ┊   ┊
> │   ╰── <column header>
> │
> ├── listview
> │
> ┊
> ╰── [rubberband]
> ```

The vertical adjustment is **forwarded to the inner listview**, so vertical
scrolling never moves the header:

> ```c
> case PROP_VADJUSTMENT:
>   g_value_set_object (value, gtk_scrollable_get_vadjustment (GTK_SCROLLABLE (self->listview)));
>   break;
> ```

The horizontal adjustment is owned by the `columnview` itself and is applied as
a translation to **both** the header and the listview:

> ```c
> static void
> gtk_column_view_allocate (GtkWidget *widget, int width, int height, int baseline)
> {
>   GtkColumnView *self = GTK_COLUMN_VIEW (widget);
>   int full_width, header_height, min, nat, x, dx;
>
>   x = gtk_adjustment_get_value (self->hadjustment);
>   full_width = gtk_column_view_allocate_columns (self, width);
>   ...
>   dx = (_gtk_widget_get_direction (widget) != GTK_TEXT_DIR_RTL) ? -x : width - full_width + x;
>
>   gtk_widget_allocate (self->header, full_width, header_height, -1,
>                        gsk_transform_translate (NULL, &GRAPHENE_POINT_INIT (dx, 0)));
>
>   gtk_widget_allocate (GTK_WIDGET (self->listview), full_width, hei...
> ```

**And the overflow policy itself is in that same file**, in
`gtk_column_view_distribute_width`:

> ```c
> scroll_policy = gtk_scrollable_get_hscroll_policy (GTK_SCROLLABLE (self->listview));
> if (scroll_policy == GTK_SCROLL_MINIMUM)
>   extra = MAX (width - col_min, 0);
> else
>   extra = MAX (width - col_min, col_nat - col_min);
> ```

`extra` is clamped at zero, so **GTK never shrinks a column below its minimum**.
`gtk_column_view_allocate_columns` then returns `total_width` as the sum of the
allocated widths, and the header and listview are both allocated at
`full_width` — which exceeds the widget's `width` when the minimums do not fit.
The `GtkScrolledWindow` scrolls the difference.

**GTK is therefore the reference implementation of the policy this research
recommends**: per-column minimums, expand for slack, horizontal scroll once the
minimums no longer fit, header locked to the body horizontally and free of it
vertically.

### 5.4 WinUI

There is no table, so there is no built-in. The nearest documented sticky
mechanism is grouped `ListView`:

Source: <https://learn.microsoft.com/en-us/uwp/api/windows.ui.xaml.controls.itemsstackpanel.arestickygroupheadersenabled>

> "Gets or sets a value that specifies whether a group header moves with the group when the group is panned vertically."
> Default value: **true**.

> "Group headers can be sticky only when the group is panned vertically and the GroupHeaderPlacement is Top. If the panel's Orientation is Horizontal or GroupHeaderPlacement is not Top, this property is ignored."

That constrains it to the vertical axis only, and says nothing about horizontal
offset. **For a table header that must track a horizontal scroll, kaya's WinUI
backend has to do the offset itself** — the same manual job as Compose.

### 5.5 Summary of §5

| Backend | Vertical pinning | Horizontal tracking |
| --- | --- | --- |
| GTK4 `GtkColumnView` | free (vadjustment forwarded to the listview) | free (one hadjustment translates header + body) |
| SwiftUI `Table` (macOS) | free (native control) | free (native control) |
| SwiftUI hand-built | `pinnedViews: [.sectionHeaders]` | manual if the header sits outside the h-scroll |
| Compose | `stickyHeader` (stable API) | **manual** — header and rows must share one `ScrollState` |
| WinUI | `AreStickyGroupHeadersEnabled` (vertical only) | **manual** |

---

## 6. What this adds up to for kaya

Stated as findings, not as a recommendation — the ruling is the maintainer's.

1. **There is a consensus policy and it is not "clamp" and not "clip."** It is:
   per-column minimum width; distribute slack to columns that opt into it;
   once the sum of minimums exceeds the viewport, scroll the whole grid
   horizontally with the header locked to the body. GTK implements exactly this
   (§5.3). `data_table_2` reimplements it for Flutter under the name `minWidth`
   (§1.7). AG Grid, DataTables and the WCT DataGrid all assume it (§3.4).
   PrimeNG deprecated its alternative in favour of it (§3.1).

2. **kaya's two current behaviours are each the losing side of a documented
   comparison.** Compose's clamp is Flutter's behaviour minus the spill, and
   Flutter is the framework everyone writes wrapper packages to escape. iOS's
   silent clip is the one thing no framework does deliberately — SwiftUI's iOS
   `Table` drops columns *and says so*, which at least does not lie about what
   the user is seeing.

3. **Accessibility is settled in kaya's favour.** WCAG 1.4.10 Reflow names data
   tables as an exception to the no-two-dimensional-scrolling rule (§2.3), so a
   horizontally scrolling table is compliant at AA. The obligations that remain
   are real but small: the scroll container must be keyboard reachable and
   operable (§2.2, WCAG 2.1.1 / ACT rule 0ssw9k), and an individual *cell's*
   content must still reflow.

4. **The floor is implementable on all four backends** (§4.5). GTK gets it free.
   SwiftUI has a documented two-axis `ScrollView`. WinUI needs
   `HorizontalScrollBarVisibility` explicitly turned on (its default is
   `Disabled`). Compose needs orthogonal mixing — legal — and a shared
   `ScrollState` between header and rows.

5. **The one place kaya cannot simply adopt the native default is iOS.**
   SwiftUI's `Table` in a compact horizontal size class hides headers and every
   column after the first, automatically and with no opt-out (§1.2). If kaya's
   iOS backend keeps using the native `Table` in the compact class, kaya cannot
   have a uniform overflow semantics there; if it synthesizes (which kaya
   already does for the compact table tier, per the repo's own
   `check-table-tier` notes), it can.

### Things I could not verify

- **Whether SwiftUI `Table` on macOS scrolls horizontally when columns exceed
  the width.** Apple documents `TableColumn` minimums and documents that a
  scroll view shows a horizontal scroller "as needed", but I found no Apple
  sentence stating the composed behaviour. §1.3 marks this as inference.
- **Material Design's own *prose* on responsive data tables.** `m3.material.io`
  and `m2.material.io` are JavaScript single-page apps that return an empty
  body to a fetch. I verified the *absence* of an M3 data-table component from
  Google's own repository, and I quoted Google's own M2 *implementation*
  (`mdc-data-table`'s stylesheet and README, §1.6) — but not the M2 spec page's
  written guidance about narrow screens.
- **Apple's Human Interface Guidelines on table column overflow.** The HIG
  "Lists and tables" page is likewise JS-rendered and returned no body.
- **The exact WinUI 3 status of the Community Toolkit DataGrid today.** The
  toolkit doc says it "is not part of the WinUI 3 controls available in the
  Windows Community Toolkit version 8.0 and later yet"; whether a newer
  release has since added it, I did not confirm beyond that sentence.
- **That WinUI 3 has no built-in DataGrid** is inference from the toolkit's
  statement plus the absence of the type, not a quoted Microsoft denial.
