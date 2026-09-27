# Swiping a row for its actions — the design pass

Status: BUILT 2026-09-26 (R1-R3 RULED 2026-09-25 as recommended). The chat app's C7
(docs/chat-plan.md): swipe a conversation to archive it on the phones.
Researched 2026-09-25 with sources.

## §1 — The semantics

A stamped row may declare swipe actions on its leading and trailing edges.
Each names an item of the row's OWN context catalog, so the swipe is never
the only way to an action: the same handler, the same row, the same
enablement, reachable from the context menu as well. At most one item per
edge is marked `full`, and a full swipe runs it (Gmail's archive). A swipe
item that is not in the catalog is refused.

## §2 — What each platform offers

| platform | native swipe | fit |
|---|---|---|
| iOS | `.swipeActions` | only on rows of a SwiftUI `List` until iOS 27, which adds `swipeActionsContainer()` for other containers; kaya draws a collection as a stack inside a scroll view, not a `List`, and pins the iOS 26 SDK with an iOS 16 floor |
| macOS | `.swipeActions` with a trackpad, as Mail does | the same `List` limit |
| Android | Material 3's `SwipeToDismissBox` | runs one action on a full swipe; revealing several buttons exists only in the Wear library |
| Windows | `SwipeControl`, Reveal and Execute | touch only; Microsoft calls it "a touch accelerator for context menus" |
| Linux | none | libadwaita has no row swipe; the GNOME guidelines point to the context menu |

## §3 — Rulings (RULED 2026-09-25 as recommended: the menu where there is no swipe, `swipeActionsContainer()` from the 27 SDK and the menu below it, Android's full swipe only)

- **R1 — where there is no swipe (Linux, and Windows with a mouse).**
  RULED: the declaration is accepted and the actions stay in the
  context menu, which is already where they are. Honest on both, since
  GNOME and Microsoft both treat the menu as the route.
- **R2 — Apple below 27.** kaya's collections are not `List`s. The
  choices: (a) RULED: move the pinned SDK to 27 when it ships and
  lower to `swipeActionsContainer()` there, menu-only below 27; (b) lower
  a collection that declares swipe actions to a `List`, which changes its
  layout and scrolling on every Apple lane; (c) draw kaya's own swipe,
  which is not the platform's.
- **R3 — Android's reveal.** Material's phone library runs one action on
  a full swipe and reveals nothing. (a) RULED: the `full` item
  swipes, the rest stay in the menu; (b) kaya builds a reveal on
  `anchoredDraggable` to Material's guidance.

## §4 — How a leg sees it

A `swipe_action <row> <item>` verb resolves the row's declared item
through the model and activates it through the same path the gesture
takes, `context_open`'s shape; on the phones a real gesture beside it
(the iOS driver's `swipe`, `adb input swipe`). An `expect_swipe_actions`
verb reads what each backend lowered (edge, labels, the full item).

## §5 — As built

- The declaration is a context item's `swipe` menu prop, one of `leading`,
  `trailing`, `leading_full`, `trailing_full`, const-only and actions only.
  The core refuses it on a window's menu bar and refuses a second full swipe
  on one edge of one row (across every root attached to that row). Rust's
  `swipe` exists only on a context-anchored action, and Haskell's `ISwipe`
  only in the context scope, so both refuse a bar item at compile time.
- Android wraps a row whose catalog holds a full swipe in Material's
  `SwipeToDismissBox`; the item runs through the context menu's own
  activation and the row settles back, the app deciding its fate. Its other
  swipe items stay in the menu (R3).
- Apple, GTK and WinUI keep every swipe item in the context menu (R1, R2).
  Windows' touch `SwipeControl` is not built: R1 names the menu for Windows
  with a mouse, which every lane and the VM are, and touch is not driven.
- `swipe_action <row> "<item>"` runs the item through its swipe: a real
  touch swipe across the row on Android, the context menu elsewhere. The
  interpreters refuse an item with no swipe declared; the Rust harness's
  menu route (GTK, WinUI) does not read the declaration. `expect_swipe_actions`
  is not built: every lane but Android lowers to the menu, and a verdict
  byte-compared across lanes cannot say which.
