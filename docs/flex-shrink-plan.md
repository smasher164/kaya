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

## §9 The folded row's checkbox (the maintainer, 2026-09-24)

The folded task row put its checkbox mid-row: "it looks weird". That is
R5 (docs/tasks-plan.md, taken 2026-09-05): a row centres its children on
the cross axis, the core emitting `align = center` on every new row, live
and template alike, unless the app sets an align of its own. Nothing
drifted; the row grew a second line and the centre moved with it. What the
fold DID expose is that Start and End were not honest for CONTROLS on the
Apple lanes: a `KayaCell` handed its child the whole cell and a `Toggle`
answers the height it is offered and centres its glyph in it, so under
Start a checkbox sat mid-row exactly as under Center. A `KayaCell` places
its child with the size the child asked for now (a crossing container
asks for the whole cell and still spans it) and the Apple toggles keep
their own height (`fixedSize(vertical: true)`); GTK's `GtkCheckButton`,
WinUI's `CheckBox` and Material's `Checkbox` already honoured the mode
inside their own minimum boxes (24, 32 and 48).

To put the checkbox on the title's line, the platform shape of Apple's
own lists, the task manager's row has to SAY so, and the TEMPLATE zone had
no align setter in any binding (Python's and JS's `rows(opts)` were the
only route; tpl-surfaces' PROP_MEMBERS listed none).

RULED 2026-09-24 (the maintainer: "add the setter"), on the recommendation
below, and built the same day:

- THE DEFAULT STAYS CENTRE. R5's reason holds: Material's checkbox is a
  48dp touch box around a 20dp glyph, so under Start a one-line title hugs
  the row's top beside it, and a Start default would not put the glyph on
  the title's line either, only near the row's top. Centre is right for a
  one-line row on every platform; it is the two-line row that wants
  something else, and that row can say so now.
- `align` IS A TEMPLATE PROP in all nine bindings, spelled where each
  binding's other template props are (Rust's `Tpl::align` and the `Row`
  facade, Go's `SetAlign` on Tpl, SumCase and the generated `<Name>Row`,
  C#'s `SetAlign` on Tpl and the generated `<Rec>Row`, Java's `setAlign`
  on Tpl and RowSurface, Swift's `setAlign`, OCaml's `Tpl.set_align`,
  Haskell's `TplAlign` attribute, Python's and JS's existing `align` in
  `rows(opts)`), held by tpl-surfaces' PROP_MEMBERS row and the two
  generators' forwards (check-sugar-surface).
- THE TASK ROW SAYS `Align::Baseline`, the Reminders shape: the checkbox
  sits on the title's line whatever the row's height, and a taller text
  scale moves nothing. Start would put the glyph near the row's top and
  leave the title's line to the font.
- A BASELINE ROW ON FOUR BACKENDS, two rules no scene can read (no verb
  reads a cell's y), held by check-universal-props' BASELINE_LINKS with
  nine watched cuts: A COLUMN'S BASELINE IS ITS FIRST CHILD'S (a row's is
  its deepest cell's), so a title-over-date column sits on the title's
  line — SwiftUI's `KayaFlex.explicitAlignment` and `KayaCell`'s, GTK's
  measure returning the first visible child's baselines, WinUI's
  `first_text_baseline` walking to the first Label, Compose's Layout
  natively; and A CELL WITH NO TEXT HAS NO BASELINE AND SITS AT THE ROW'S
  TOP. That second rule is where the four had drifted: SwiftUI answers the
  guide for every view (a textless one reads its bottom, the iOS switch its
  empty label's line a fraction of a point under its top, measured through
  the layout trace: the switch was dropped 16pt to sit that line on the
  title's), Compose and WinUI used the CSS replaced-element rule (baseline
  = bottom, which put a 31pt switch mostly above a 17pt title), GTK's
  BASELINE valign on a baseline-less widget fills. Now SwiftUI's
  `textBaseline` answers nil within a point of either edge, Compose's
  `KayaFlexRow` keeps `null` for an unspecified FirstBaseline and sizes the
  row for its drops, WinUI's `baseline_compensate` compensates nothing for
  a textless child and a column with no label, and GTK's allocate sets
  Start on a cell whose measure reports none.
- Captures on all five lanes, the Today row with the checkbox on the
  title's line (target/session-notes/flex-2026-09-24/<lane>/today.png,
  the mac's today-baseline3.png), each viewed; the review page is
  republished with them.

## §10 The first line box (the maintainer, 2026-09-24, night)

§9's "a cell with no text sits at the row's top" put the checkbox at the
top of the title's LINE BOX, not at its ink: a line of text is a box
taller than its letters, with the font's ascent above the capitals, and
at 200% twice as much of it, so the checkbox read as aligned to an
invisible box above the title and by a different amount on every platform
(each toolkit's control pads its glyph its own way: Material's 48dp touch
box, a 31pt UISwitch, a 24px GtkCheckButton around a 14px indicator, a
20px CheckBox in a 32px minimum). GTK looked right at 100% by
coincidence and wrong at 200%, where its indicator does not scale with
the text. The maintainer: "I think this should be addressed".

THE RULE: in a baseline row, a cell with no text is vertically centred
on the FIRST LINE BOX of the cell that set the row's baseline — the strip
from that line's top to one line height down, which scales with the
text — and sits at the row's top only when no line box can be read. A
cell taller than the line overhangs it, and the row grows so that
nothing is placed above its top (CSS's own baseline-alignment growth).
The line box is read per backend from the provider's first LABEL, by
node, never by a guide:

- SwiftUI: the label's own firstTextBaseline guide records
  `kayaLineHeights[id] = height − (last − first baseline)`, one line at
  any wrap or scale, beside the ascent `kayaBaselineOffsets` already
  held; `KayaFlex.baselineLayout` finds the provider's first label
  through `kayaFirstLabel(node)` and centres on
  `[rowBaseline − ascent, + lineHeight]`. NOT a custom alignment guide:
  a column renders as a VStack, and a VStack answers a custom guide with
  the AVERAGE of its children's explicit values (measured: 12 for tops of
  0 and 24, 27 for bottoms of 16 and 38), so the guide route read the
  midpoint between the title and the date.
- Compose: `KayaFlexRow` takes `lineLabels`, the first label id under each
  cell, and reads `kayaLabelLayouts[id].getLineTop(0)/getLineBottom(0)`
  against `firstBaseline` after measuring its children, when the text's
  layout callback has fired.
- GTK: `first_line_metrics` walks to the first GtkLabel and reads the
  layout's baseline and line 0's logical height; `baseline_row_layout`
  serves both the measure and the allocate, and THE MANAGER PLACES EVERY
  CELL ITSELF at its natural height, a text cell at the row's baseline
  less its own, since a vertical GtkBox handed the row's baseline under
  BASELINE_FILL stacks from its top regardless (measured: the title column
  stayed at the row's top with its baseline 7px above the button's, and
  the checkbox, centred on the button's line, read 8px low); each cell's
  own baseline still rides the allocate for the align reader's
  participation check. AND THE PLAIN COLUMN'S BASELINE: a
  column without a grower keeps GtkBox's own layout, and a vertical
  GtkBoxLayout answers -1 until `set_baseline_child` names the child that
  carries it — measured through the diagnostic: the task row's title
  column reported `(44, 44, -1, -1)`, the Details button set the row's
  line, and the checkbox centred on the button's line 7px under the
  title's. §9's GTK column arm had only ever covered the flex-managed
  column, and the top rule hid that. Every column names child 0 now.
- WinUI: `text_line` reads `TextBlock.ContentStart().GetCharacterRect
  (Forward)` beside `BaselineOffset` (the pointer and the direction enum
  joined tools/winui-bindgen's filter); `baseline_compensate` sets every
  child's top margin from one pass, the overhang shifting all of them.
- macOS is out of the rule's reach in the task row: the AppKit checkbox
  is an NSButton with a text baseline, so it is a text cell and meets the
  baseline like a glyph, which is how AppKit's own forms align a checkbox
  beside its label.

AND THE ROW'S HEIGHT IS COMPUTED LAST on SwiftUI: `KayaFlex.sizeThatFits`
re-measures a row offered less than its cells at the shrunk extents and
took the plain maximum of their heights, which ignores the drops and the
overhang shift; computed before that pass the baseline height was
overwritten, and the first matrix's iOS tasksrtl leg read a two-line
title shifted under its switch at one line's height (`needs 41pt at
191pt wide and got 22pt`). The baseline block sits after the shrunk pass
now and the gate holds the order.

Guards: check-universal-props' BASELINE_LINKS hold each backend's line-box
read and its centring, the order above, GTK's column baseline child and
its self-placement, and the badge's cap and reader — 48 watched cuts in
all: the textless cell put back at the row's top on all four, the line
box read off the wrong label or dropped, SwiftUI's label no longer
recording its line height, the two passes swapped back to the shipped
order, GTK's cells handed back to GTK's own valign, a plain column with
no baseline child, WinUI's rectangle read the wrong way, the badge capped
at 16 again and its digit no longer measured. The runtime evidence is the captures: the Today row
on all five lanes at 1.0, 200% and Arabic, the checkbox centred on the
title's line. The layout trace (`KAYA_LAYOUT_TRACE=1` on the mac,
`SIMCTL_CHILD_KAYA_LAYOUT_TRACE=1` through run-sim) prints each baseline
row's baselines, line box and ys, which is how both measurements above
were made.

