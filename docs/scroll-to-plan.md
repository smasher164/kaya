# Scroll-to — the app scrolls a list to one of its rows

The second piece on the chat app's path (docs/submit-plan.md §8, the
roadmap's menu): a chat opens at its newest message and jumps to the
first unread one, and today no app can move a scroll at all. The harness
can (`scroll_to_row` and `scroll_end` drive every lane), so the app-facing
command is the missing half, exactly as the roadmap card says.

Written 2026-09-24 after the submit slice, on the task manager's model:
the platforms first, then what kaya has, then the rulings, RECOMMENDED and
built on the recommendation unless the maintainer amends one.

## §0 — What the platforms do

Read from the vendors' documentation and from the arms kaya already
carries for the harness verbs.

| | scroll a child to a position | scroll to the end | what "position" means |
|---|---|---|---|
| macOS / iOS, SwiftUI | `ScrollViewProxy.scrollTo(id, anchor:)` — the child must carry an `.id`; `anchor: .top` puts the child's top at the viewport's top | `scrollTo(contentId, anchor: .bottom)`, which is what kaya's `scroll_end` verb does through `kayaScrollProxies` | the anchor is a unit point; the proxy clamps at the content's end |
| Android, Compose | `ScrollState.scrollTo(px)` on a plain scroll (kaya's scrolls are `verticalScroll(node.scrollState)`, never LazyColumn, docs/virtualization-plan.md §4); a child's offset comes from its placement | `scrollState.scrollTo(scrollState.maxValue)`, kaya's `scroll_end` | a pixel offset into the content; clamped by the state |
| Linux, GTK4 | the `GtkAdjustment`'s value IS the scroll position (scrollbars and kinetic panning write it); a child's y comes from `compute_bounds` against the viewport's child; `gtk_viewport_scroll_to` (4.12) exists but scrolls the MINIMUM to make a child visible, not to a position | `adj.set_value(upper - page_size)`, kaya's `scroll_end` | a value on the adjustment, clamped to `[lower, upper - page_size]` |
| Windows, WinUI 3 | `ScrollViewer.ChangeView(vertical: y)` (what scrollbars drive); a child's y comes from `TransformToVisual(viewer)`; `StartBringIntoView(BringIntoViewOptions { VerticalAlignmentRatio = 0 })` also aligns a child's top | `ChangeView(ScrollableHeight)`, kaya's `scroll_end` | an offset into the extent; clamped |

Every platform agrees on two things: a scroll position is an offset the
container clamps at its end, and a child's offset is readable from the
layout once the layout has RUN. Nothing can scroll before the first
layout — which is the chat app's whole opening frame (S4).

## §1 — What kaya has, and what the chat app needs

- `widget_command` (TX kind 17, apply kind 7): one-shot, fire-and-forget,
  `clear` and `focus` today; DESIGN.md's Commands paragraph names
  `scrollTo` as the next verb, admitted "when a long list arrives", and
  already rules its failure mode: an INSTANCE-ADDRESSED command (a key
  path) is a silent no-op when the copy is gone, since a stamped copy
  legitimately vanishes under rebuild. `widget_command` carries no
  payload, so a key cannot ride it.
- `reveal_range` (TX kind 40): the TEXT half of that instinct, shipped
  2026-08-07 — scroll a textarea range into view, a PURE EFFECT permitted
  inside an undo group and not inverted (docs/undo-plan.md A2).
- The harness: `scroll_to_row <container> <key>` parks a WINDOWED tier's
  band on the row and lands it at the viewport's top; `scroll_end
  <scroll>` drives a scroll to its end; `expect_window <container>
  <first> <N>` reads a windowed tier's first visible row; `expect_at_end
  <scroll>` reads a scroll's content bottom against its viewport's.
- The core: `scene.scroll_to_row(container, key)` maps a key to an index
  in the collection's CURRENT order (crates/kaya/src/scene.rs), and every
  lane's harness arm goes through it.
- WHICH FORS ARE WINDOWED TODAY: the ones that declare columns, on every
  tier — GTK's `core.tables`, WinUI's `TABLES`, SwiftUI's
  `kayaTableDrivers` (mac native) and `kayaTableWindows` (synthesized),
  Compose's `kayaTableWindows`. A plain For — a column of message rows
  inside a scroll, which is what a chat is — is REALIZED WHOLE on every
  tier (docs/virtualization-plan.md §6.3 is the plain-For band, not yet
  landed). So a scroll to a row of a chat is a scroll to a realized
  child, and the harness's park path does not apply to it.
- The chat app needs three moves: open at the newest message (the build
  transaction, before any layout), jump to the first unread (a handler,
  by key), and follow its own send (the handler that inserted the row).
  All three are "this row of this For", and the model knows the key
  each time (DESIGN.md: handlers ask the model which key is first or
  last; they never count widgets).

## §2 — The rulings (RECOMMENDED; built on the recommendation, amendable)

### S1 — One record, `scroll_to_row`, addressing a For's container and a key (RECOMMEND: yes)

A new TX record, kind 61 `scroll_to_row { widget_id: U64, key: Value
}`, with its apply twin, kind 49 carrying what the core resolved: the
row's index in the current order and, when the row is realized, the
id of its copy's root widget. Its own record rather
than a `widget_command` verb because the key is a payload
`widget_command` has no room for — the shape `reveal_range` took. The
container is the widget the For is mounted in (the same target the
harness's `scroll_to_row` names), the key is the row's key value. The
LIST half of DESIGN.md's `scrollTo` and nothing more: no "scroll to a
widget" form and no "scroll to an offset" form, because no artifact asks
for either (the admission policy — the chat app's three moves are all
rows). `scroll_end` stays a harness verb; an app that wants the end
scrolls to its last key, which lands clamped at the end (S3).

### S2 — Where the row lands: its top at the viewport's top, clamped (RECOMMEND: yes)

The row's top edge meets the viewport's top edge; where the content below
the row is shorter than the viewport, the scroll clamps at its end and the
row sits wherever that leaves it. This is the harness verb's rule for
windowed tiers already ("the tier scrolls that row to the viewport's
TOP"), it is what `expect_window`'s "first visible IS the scrolled-to
row" assumes, and it is the one placement every platform can state as an
offset (§0). No `anchor` argument: a chat's jump-to-unread wants the
unread row at the top, and open-at-newest wants the end, which the clamp
gives. An alignment prop can join the day an artifact needs `center`.

### S3 — A key the collection does not hold is a silent no-op (RECOMMEND: yes)

DESIGN.md's rule for instance-addressed commands, verbatim: a stamped
copy legitimately vanishes under rebuild, and a handler that reads "the
first unread" from a model another transaction has since emptied is not
a bug. The core resolves the key and, finding no row, applies nothing;
nothing is reported, nothing is logged at the guest. (The harness's own
`scroll_to_row` keeps its refusal sentence — a SCENE naming a missing key
is a scene bug.) A container that is not a For's host, or a For with no
scrollable ancestor, is the same no-op, measured per backend in §7.

### S4 — A scroll issued before the first layout lands after it (RECOMMEND: yes)

The chat's opening frame: the build transaction inserts the messages AND
scrolls to the newest, and nothing has laid out yet. Every platform in §0
can only scroll a container that has geometry, so the command is HELD by
the backend until the container's first layout and applied then — the
materialization class docs/traps.md already names for `focus` (GTK's
one-shot `map` re-grab, WinUI's one-shot `Loaded`), one command over.
One pending scroll per container: a second command before the layout
replaces the first, since only the last one could be what the user sees.
The scene proves it (S6): the first step after the mount asserts the end.

### S5 — A pure effect: no state, permitted in an undo group, not inverted (RECOMMEND: yes)

`reveal_range`'s rule (docs/undo-plan.md A2): undo restores state, not
where you were looking. The core's undo-group admission lists the record
beside `reveal_range` and `focus`.

### S6 — Instant, never animated (RECOMMEND: yes)

The row lands in the same frame the command applies (after S4's wait).
An animated glide is a per-platform behaviour with a per-platform
duration, and a scene that asserts the row's position would have to
wait out an animation no verb can measure. SwiftUI's proxy is called
outside `withAnimation`, Compose's `scrollTo` rather than
`animateScrollTo`, WinUI's `ChangeView` with `disableAnimation = true`,
GTK's adjustment set directly. An animated form can come with the
artifact that wants one.

### S7 — The observable: one verb, `expect_scrolled_to <container> <key>`, plus the two that exist (RECOMMEND: yes)

For a WINDOWED tier `expect_window` already says it: the first visible
row is the scrolled-to row. For a REALIZED For nothing reads a row's
place in its viewport, so one new byte-shared verb: `expect_scrolled_to
<container> <key>` passes when the row's top edge coincides with the
viewport's top edge within two units, OR the row is wholly inside the
viewport and the scroll is at its end (S2's clamp). Read from the
platform's own viewport-space geometry on every backend, never a model
copy — `expect_at_end`'s and `expect_revealed`'s rule. The scene also
uses `expect_at_end` after the open-at-newest scroll, which is the
chat's opening frame stated as the existing verb.

### S8 — Bindings: `scroll_to_row` beside `focus`, live zone only (RECOMMEND: yes)

Commands live on the transaction or the live handle in each binding
(DESIGN.md: `tx.focus(field)`, `entry.clear()`), and a template node has
no command surface. So: Rust `tx.scroll_to_row(container, key)` beside
`focus`; Go `tx.ScrollToRow(w, key)`; C# `tx.ScrollToRow(w, key)`; Java
`tx.scrollToRow(w, key)`; Swift `tx.scrollToRow(w, key)`; OCaml
`scroll_to_row w key`; Haskell `scrollToRow w key`; Python and JS on the
handle, `column.scroll_to_row(key)` / `column.scrollToRow(key)`, where
their `focus()` and `reveal_range()` already sit. The key is the
binding's own key type (the one `insert` takes). check-sugar-surface
censuses the nine, each row with its rename negative.

## §3 — The lowering, per backend

Two arms on every backend, split by whether the container is windowed
on that tier — the harness's `scroll_to_row` already has the first:

| backend | windowed (a table) | realized (a plain For) | S4's hold |
|---|---|---|---|
| SwiftUI | `KayaHost.scrollToRow` → the mac driver's `scroll(toRow:)` or the synthesized window's `scroll(node, toRow:)` | the copy's root view carries `.id(copyId)`; the nearest scroll ancestor's `kayaScrollProxies` proxy does `scrollTo(copyId, anchor: .top)` | a pending (container, key) on the scroll node, drained by the proxy's first appearance |
| Compose | `kayaTableWindows[id].park(index)` | the copy's root records its placed y (`onGloballyPositioned`) in the content; the ancestor scroll's `scrollState.scrollTo(y)` | a pending key on the node, applied from a `LaunchedEffect` once the copy has a placement |
| GTK4 | the harness arm's body (anchor, `window_moved`, `window_report`, `reflow_table`) | the copy's root widget's bounds against the scrolled window's child (`compute_bounds`); `vadjustment.set_value(y)` | a one-shot `map` handler on the container, `focus`'s shape |
| WinUI 3 | the harness arm's body (`table_band_to`, spacers, `table_scroll_to`) | the copy's root `TransformToVisual(viewer)`; `ChangeView(None, y, None, disableAnimation: true)` | a one-shot `Loaded` handler, `focus`'s shape |

The core does the key→index and index→copy resolution once, in
`scene.rs`, so every arm receives the copy's node id and the container;
the backends own only the geometry.

## §4 — The wire

- TX kind 61 `scroll_to_row { widget_id, key }`; apply kind 49
  `scroll_to_row { widget_id, copy, index, reserved }` — `copy` is the
  realized root's widget id or 0, `index` the row's place in the current
  order, so a windowed tier parks on the index and a realized one scrolls
  the copy.
- The spec hash moves; the nine wire files, kaya.h and both
  interpreters' hash copies follow.
- `check_command`-style validation at the root: the container must be a
  live container widget (column, row, scroll); the key a Str or I64.

## §5 — The scene and the sweep

tools/scenes/scrollto.steps, a Rust guest first: a scroll holding a
column of 60 message rows (a For over a collection, each row a label),
the build inserting them and scrolling to the LAST key; the scene's
first step is `expect_at_end scroll#0` (S4, the opening frame). Then a
button whose handler scrolls to `m10`: `expect_scrolled_to column#0
m10`. A button scrolling to a key that does not exist: `expect_scrolled_to
column#0 m10` still (S3, nothing moved). A button that inserts `m61` and
scrolls to it: `expect_at_end`. The scene runs on all five lanes in all
nine languages; the portfolio's table, already windowed, gains one
`scroll_to_row` from a button to prove the windowed arm through the app
rather than the harness.

## §6 — Build order

Depth: spec + protocol + wire + capi + scene.rs (kind 61/49, the
resolution), the Rust binding's `scroll_to_row`, the SwiftUI arms (both
tiers) with S4's hold, the `expect_scrolled_to` verb in harness.rs and
the SwiftUI interpreter, the scene and the Rust guest, green on the mac
and iOS by hand. Then breadth: the GTK, WinUI and Compose arms and the
verb, the eight bindings' sugar, check-sugar-surface's rows, the scene
on all five lanes, the matrix. Then the chat app's own plan.
BUILT 2026-09-24 in that order, the four arms and the eight bindings
together in the breadth step.

## §7 — Measured while the arms were built (2026-09-24)

1. SwiftUI: `proxy.scrollTo(id, anchor: .top)` on a stamped row of a stacked
   For lands the row's top at the viewport's top (the mac leg's
   `expect_scrolled_to column@messages m10` reads it within 2pt), but only
   once the row has a LAID-OUT frame: a call from the proxy's first
   appearance, before the content's frame has been reported, moves
   nothing, and the interpreter had recorded window-space frames for
   FLEX children alone — a stacked For's rows had none. So the stack
   path's KayaCellReader records the frame too, the drain runs when a
   frame lands, and the request stays pending until the copy has one
   (S4). The apply arm tries at once, so a jump from a handler lands in
   the same batch.
2. Compose: a request performed from a `LaunchedEffect` keyed on the
   request's sequence, waiting frame by frame (bounded) for the copy's
   and the scroll box's `onGloballyPositioned` placements, then
   `scrollState.scrollTo(top − boxTop + value)`; the state clamps at
   `maxValue`, which is S2's end.
3. GTK: the adjustment's `changed` signal is the hold — it fires when the
   content's extent moves, INSIDE the viewport's allocation, where a value
   written at once never reached the child's transform (the opening scroll
   read as landed on the adjustment while the pixels stayed at 0, on the
   linux lane), so the scroll runs from an idle after that pass.
   `compute_bounds` against the scrolled window's child, the GtkViewport,
   answers in viewport space AS THE LAST ALLOCATION LEFT IT — a click 11ms
   after the opening scroll read a row at its unscrolled offset with the
   value already at the end, and the jump clamped in place — so the row is
   read against the viewport's own child, the content, whose layout never
   moves with the scroll, and that content offset is the value written;
   `vadjustment.set_value` clamps at `upper − page_size`.
4. WinUI: `Loaded` is the hold, the focus arm's class; a loaded element's
   top comes from `TransformToVisual` against the viewer's CONTENT after
   `UpdateLayout` — a transform to the viewer itself carries the scroll
   offset as the composition last arranged it, one frame behind a
   ChangeView and a beat behind an insert (a row read 243 with the offset
   already at 1372, a just-inserted row read −1372, on the lane's VM), so
   the content space, which layout settles, is the one to read. And a
   row the SAME batch inserted is loaded but sits on the band's row 0
   until the reindex at the batch's end assigns its track (it read content
   top 0 with the extent unchanged), so the realized scroll is posted to
   the UI queue behind the apply, defer_role_refresh's idiom, and
   `ChangeViewWithOptionalAnimation(…, disableAnimation: true)` then moves
   the viewer, which clamps at `ScrollableHeight`.
4a. GTK and WinUI, the two whose hold is a signal per request: a jump
   clicked before the opening scroll's row had loaded saw both holds
   release together with the OPENING one last, and the list ended at its
   end (the windows lane's scrollto_go leg on the first plain matrix), so
   each keeps one pending request per container and a hold that is no
   longer the latest lands nothing — S4's "a second command before the
   layout replaces the first", which SwiftUI's and Compose's single
   request field had for free.
5. All four: the core resolves the container to its For site and the key
   to (index, copy root) in one place (`Scene::row_copy`), so a container
   hosting no For or a missing key never reaches a backend (S3, the unit
   test beside `scroll_to_row`'s); a For with no scroll ancestor drops the
   request at the backend.

THE GUARDS (invariant 3): the core's unit test on the resolution; the
scene on five lanes in nine languages, whose first step is the pre-layout
scroll (S4) and whose `nowhere` click is S3; check-verbs on the verb's
parity across the three harnesses and the apply constant's; and
tools/check-scroll-to.py for what the scene cannot see — an animated
arm (S6), a dropped hold (S4), a harness park that drifts from the
command's (§3) and a verb that reads the request instead of the layout
(S7), 13 watched negatives.

## §7a — What was to be measured, as written before the build

1. SwiftUI: does `proxy.scrollTo(id, anchor: .top)` on a child of a
   `VStack` inside `ScrollView` land the child's top at the viewport's
   top within 2pt, and does a call from the proxy's first appearance
   (the `ScrollViewReader` body's first evaluation) scroll at all, or
   must it wait a frame? Both on the mac and the phone.
2. Compose: is a child's `onGloballyPositioned` offset inside a
   `verticalScroll` column stable across recomposition, and does
   `scrollState.scrollTo` before the first layout clamp to 0 (so the
   hold is needed) or queue?
3. GTK: `compute_bounds` of a copy's root against the scrolled window's
   child, before and after the window is mapped; whether
   `vadjustment.upper` is final at `map` or only at the first
   `size-allocate`.
4. WinUI: `ChangeView` before `Loaded` — dropped or queued; the
   `TransformToVisual` y of a StackPanel child against the ScrollViewer.
5. All four: what a scroll to a row whose container has NO scrollable
   ancestor does (must be a no-op, S3), and to a container that hosts no
   For.
