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
   word); for anything that cannot wrap, its natural size. Growers get
   nothing.
3. A shrunk text cell wraps inside its width and the row grows on the
   cross axis to fit it; a word is never broken.
4. Whatever still overflows once every cell is at its minimum is the
   row's, unchanged: the platform clips it, and `expect_no_clipping` says
   so (§4). That is the app's to fix, not the toolkit's.
5. The rule is the ROW's (the horizontal main axis). A column's fixed
   children keep their natural height as today: text has no min-content
   height short of its content, and a column that shrank one would clip it.

## §3 Per backend

- **SwiftUI**: in `placeSubviews`, measure each fixed child twice — its
  natural (the bounded proposal, as today) and its minimum
  (`sizeThatFits(ProposedViewSize(width: 0, height: nil))`, which is a
  `Text`'s longest word) — and when the fixed sum exceeds the bounds, take
  the excess out of the fixed cells in proportion to (natural − minimum),
  never below minimum. `sizeThatFits` in the same shape so the row's
  reported height follows the wrapped text. The label arm carries no
  `fixedSize`, so a narrower proposal wraps it.
- **Compose**: the row arm's `Row` becomes a `Layout` of its own (the grid
  arm's shape), reading each child's `maxIntrinsicWidth` (basis) and
  `minIntrinsicWidth` (min-content, a `Text`'s longest word) before
  measuring any of them, then measuring each with exact width
  constraints. `Modifier.weight` goes with the Row; growers take the
  leftover by the same arithmetic as the other three.
- **GTK**: `allocate` reads each fixed child's (minimum, natural) and
  shrinks between them; labels move to `WrapMode::Word` so the minimum a
  label reports is its longest word rather than one character. The site
  chose `WordChar` under the 2026-08-29 wrapping ruling for wrapping's
  sake, not for the character break, so nothing is lost.
- **WinUI**: `Auto` columns cannot shrink, so the row Grid's columns are
  set by kaya after a measure: each fixed child is measured unbounded
  (basis) and at width 0 (min-content; a wrapping `TextBlock` answers its
  longest word), the widths are computed by §2 and written as `Pixel`
  columns whenever the fixed sum exceeds the grid's width, `Auto`
  otherwise, on the grid's `SizeChanged` (reflow_wrap's shape).

## §4 The verb's second clause

`expect_no_clipping` also refuses a label whose frame leaves its window on
the main axis, or leaves its nearest scroll viewport on the cross axis,
read in window coordinates on every backend (SwiftUI's
`GeometryReader` frame in `.global`, Compose's `positionInRoot`, GTK's
`compute_bounds(window)`, WinUI's `TransformToVisual(ground)`). The
sentence names the label, its edge and the window's. It lands in the same
slice as §3 because it turns the iOS tasks legs red on the Today screen
the moment it exists.

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
- The iOS tasks legs under the verb's new clause: red until §3 lands on
  SwiftUI, green after, with the English 1.0 Today screen as the case.
- `gtk::flex::tests`: the shrink arithmetic on frozen numbers (proportional,
  floored at minimum, growers untouched).
- `winui::tests`: the same arithmetic, since both are Rust and the function
  is one module in the core shared by the two Rust backends; the two
  interpreters carry their own copies, held by the scene.
- check-universal-props or a new clause in check-steps: the two
  interpreters' row arms name the min-content measure (`minIntrinsicWidth`,
  `ProposedViewSize(width: 0`) — a copy that dropped it would pass the
  scene only on the desktops.

## §7 Sequence

Depth on SwiftUI with the verb clause and the scene, green on mac and
iOS by hand (`--only flexshrink,tasks`), then the three other arms, the
filtered run on all five lanes, the plain matrix, the review page with
the Today screen on the phones after.
