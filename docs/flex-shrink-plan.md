# A flex cell shrinks to its longest word (ruled 2026-09-24)

The compliance review page (docs/deferred.md, the flex-row GAP entry;
https://claude.ai/artifact/FGJashLzHA17NNZ5YUFMBr) found the task manager's
Today row running off the iPhone in English at 1.0, and the same row on
Android breaking its last word in two. The maintainer ruled one rule for
all four backends, sequenced after the matrix filter.

## §1 What each backend does today with a row too wide for its cells

- **SwiftUI** (`KayaFlex.placeSubviews`): every non-growing cell gets its
  natural main-axis size and the cells are placed in turn; nothing shrinks,
  so the offsets run past the bounds and the last cells leave the window.
- **Compose** (the row arm's `Row`): Compose's Row measures the
  non-weighted children in order against whatever width is left, so the
  first cells take their natural width and the last is squeezed to the
  remainder, below one word, and `Text` breaks the word ("Detai/ls").
- **GTK** (`flex::FlexLayout::allocate`): a non-grower is allocated its
  natural width; the sum may exceed the container and the last cells are
  clipped by the window. Labels wrap with `WrapMode::WordChar`, so their
  MINIMUM is one character wide, which is the Compose failure one toolkit
  over if the allocator ever shrank to the minimum.
- **WinUI** (`reindex`, `track()`): a non-grower's column is `Auto`, which
  Grid measures unbounded; the row overflows and the window clips it.

Two of the four were photographed only at desktop widths, where nothing
overflows; the rule applies to all four because a window can be narrow on
any of them.

## §2 The rule (CSS flexbox's own defaults, `flex-shrink: 1` with
`min-width: auto`)

1. A cell's BASIS is its natural main-axis size; a grower's basis is 0 and
   it takes a share of the leftover, as today.
2. When the fixed cells' bases plus the gaps exceed the row's main extent,
   the fixed cells SHRINK, each in proportion to its basis, each no further
   than its MIN-CONTENT size: for text, the longest unbreakable unit (a
   word); for anything that cannot wrap, its natural size. A cell that
   would go below its minimum is frozen there and the rest redistributed
   among the others (CSS's own loop). Growers get nothing. The arithmetic
   is one function in the core, `crates/kaya/src/flex.rs`, with its unit
   tests; the two interpreters carry copies.
3. A shrunk text cell wraps inside its width and the row grows on the
   cross axis to fit it; a word is never broken.
4. Whatever still overflows once every cell is at its minimum is the
   row's, unchanged: the platform clips it, and `expect_no_clipping` says
   so (§4). That is the app's to fix, not the toolkit's.
5. The rule is the ROW's (the horizontal main axis). A column's fixed
   children keep their natural height as today: text has no min-content
   height short of its content, and a column that shrank one would clip it.
6. The rule is the FLEX row's: a row with a grower. On SwiftUI and GTK a
   row with no grower is the platform's own stack (an `HStack`, a
   `GtkBox`), which already shrinks its text children by the platform's
   own arithmetic and never places one off-screen; only the flex layout
   the two backends CONSTRUCT for growers (DESIGN.md's tier 3) placed cells
   at their natural width. Compose's row and WinUI's grid are the same
   code with or without a grower and take the rule either way. The task
   manager's row has a grown spacer, which is why it overflowed, and the
   scene's row has the same.

## §3 Per backend

- **SwiftUI**: one `extents(mainExtent:)` in `KayaFlex`, shared by
  `sizeThatFits` and `placeSubviews`. THE MINIMUM IS READ OFF THE NODE,
  not the subview: the subview is a `KayaCell`, which answers a proposal
  with the proposal, so a zero-width probe answers 0 and every cell would
  shrink to nothing (the first draft, measured on the iOS project screen:
  "Renew passport" at 88pt). A label's minimum is `kayaLongestWord` in the
  verb's own font; anything else keeps its natural. AND THE ROW'S HEIGHT
  IS MEASURED WITH THE HEIGHT LEFT OPEN: `sizeThatFits` re-measures the
  shrunk cells at `ProposedViewSize(width: extent, height: nil)`, because
  passing the row's own proposed height through makes `KayaCell` echo a
  List's probe (0, then inf) and the row reports a one-line height for
  two lines of text (the same screen, "Book the flights" at 99pt, 20pt
  tall for 41pt of text).
- **Compose**: the row arm's `Row` is `KayaFlexRow`, a `Layout` of its
  own (the grid arm's shape), reading each child's `maxIntrinsicWidth`
  (basis) and `minIntrinsicWidth` (min-content, a `Text`'s longest word)
  before measuring any of them, then measuring each against its extent
  and placing by the row's align mode, baseline included. `Modifier.weight`
  went with the Row; growers take the leftover by the same arithmetic.
- **GTK**: `allocate` reads each fixed child's (minimum, natural) and
  shrinks between them; labels move to `WrapMode::Word` so the minimum a
  label reports is its longest word rather than one character; and
  `measure` reports a row's MINIMUM as its fixed cells' minimums, since
  a minimum that summed their naturals could never be allocated less and
  GTK widened the flexshrink window from the declared 360 to 510 with the
  shrink never running (the first capture, 2026-09-24). The site
  chose `WordChar` under the 2026-08-29 wrapping ruling for wrapping's
  sake, not for the character break, so nothing is lost.
- **WinUI**: `Auto` columns cannot shrink, and the Grid's own STAR
  resolution is §2's arithmetic: a fixed cell's column is `Star` weighted
  by its natural width with `MinWidth` at what it measures at zero width
  (a wrapping `TextBlock` answers its longest word) and `MaxWidth` at its
  natural, so the Grid shrinks star columns in proportion to the basis,
  freezes one at its floor and hands what the caps release to the growers
  (`Star` by weight). Written in `reindex` from a measure of each child
  (`measured_widths`), and a label's text arm marks its ROW to come back
  through `reindex`, since the star weight carries the old natural. No
  LayoutUpdated hook, so no layout cycle to guard.

## §4 The verb's second and third clauses

`expect_no_clipping` also refuses, on every backend:

- a label OR A BUTTON whose frame leaves its window across, or down unless
  a scroll carries it, read in window coordinates (SwiftUI's
  `GeometryReader` frame in `.global`, Compose's `positionInRoot`, GTK's
  `compute_bounds(window)`, WinUI's `TransformToVisual(ground)`). Buttons
  because the cell a flex row places past its end is as often the row's
  trailing button as a label: the iOS task manager's "Details", and the
  first negative on the mac, whose two labels still fit while the button
  sat at 369...435pt in a 360pt window;
- a label narrower than its longest word (the Compose "Detai/ls" shape,
  which the height clause cannot see because both halves fit their
  taller frame): the widest whitespace-separated unit set in the label's
  own font, against the frame's width.

The sentences name the widget, its edges and the window's, or the label,
its width and the word's. Both land in the same slice as §3 because they
turn the iOS tasks legs red on the Today screen the moment they exist.

## §5 The Compose bar label

The navigation bar's label takes `TextOverflow.Ellipsis` on one line, the
platform's own truncation for a label that does not fit; `Visible`
(2026-09-06) stopped a word breaking and made the labels overlap at 200%.

## §6 Guards

- A new shared scene, flexshrink: a row of three fixed labels and a
  grower inside a window sized narrower than their natural widths
  (`resize_window`), `expect_no_clipping` (both clauses), the shares read
  through `expect_shares`, on every lane in Rust. The scene is what makes
  the rule observable; before it no scene had a row wider than its window
  on a desktop.
- The iOS tasks legs under the verb's new clauses: red until §3 lands on
  SwiftUI, green after, with the English 1.0 Today screen as the case. AT
  200% THE APP HAD TO ADAPT (§2.4): the switch, the two labels' longest
  words, the button and the gaps exceed a phone's width even at every
  cell's minimum, so the task manager's row is now
  [switch][column(title, caption)][spacer][Details], the platform's own
  list shape, and a column's min-content is its widest child.
- The verb's mac reading keys frames per RENDERING (docs/traps.md, the
  NavigationStack entry), since a pushed destination is rendered twice
  while it slides and the staged copy sits past the window.
- THE FIRST MATRIX'S TWO REDS, both the new clauses doing their job: the
  iOS formatbig leg read the format guest's last label at 788...827pt in
  an 812pt window, fourteen labels at 200% with no scroll, so the guest's
  column scrolls now; and the windows portfolio leg read a table's rows
  misaligned, because the label-text arm's new reindex of its row replaced
  the table's stamped Pixel tracks with star columns, so a table's rows
  are exempt from that mark.
- THE SHIPPED STATE WATCHED RED, by hand on the mac (2026-09-24): the
  shrink cut out of a copy of the interpreter (one substitution), the
  flexshrink leg reads `clipped: button 6 "Details" spans 369...435pt
  across ... past its 360x240pt window`; restored by copy, it reads
  `no clipping (2 labels measured)`. The row's two labels both fit, which
  is why the clause reads buttons.
- `gtk::flex::tests`: the shrink arithmetic on frozen numbers (proportional,
  floored at minimum, growers untouched).
- `winui::tests`: the same arithmetic, since both are Rust and the function
  is one module in the core shared by the two Rust backends; the two
  interpreters carry their own copies, held by the scene.
- check-universal-props: every backend's flex row names its min-content
  read — SwiftUI's `kayaMinContent` in `KayaFlex`, Compose's
  `minIntrinsicWidth` in `KayaFlexRow`, GTK's `crate::flex::shrink`, WinUI's
  `SetMinWidth` in `reindex` — four watched cuts, counts printed; a copy
  that dropped it would pass the scene only where the window is wide.

## §7 Sequence

Depth on SwiftUI with the verb clause and the scene, green on mac and
iOS by hand (`--only flexshrink,tasks`), then the three other arms, the
filtered run on all five lanes, the plain matrix, the review page with
the Today screen on the phones after.

## §8 Built

Landed 2026-09-24 in 880fe020 and the GTK measure follow-up after it; matrix ALL PASS (Mac 519, Linux 851, Windows 312, iOS 156, Android 165 legs, 62 gates); the review page https://claude.ai/artifact/KPqemDy3TpQPhkmJWDnMAi.
