# Swiping a row for its actions — the design pass

Status: DESIGN, three rulings wanted (R1-R3). The chat app's C7
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

## §3 — Rulings wanted

- **R1 — where there is no swipe (Linux, and Windows with a mouse).**
  RECOMMENDED: the declaration is accepted and the actions stay in the
  context menu, which is already where they are. Honest on both, since
  GNOME and Microsoft both treat the menu as the route.
- **R2 — Apple below 27.** kaya's collections are not `List`s. The
  choices: (a) RECOMMENDED: move the pinned SDK to 27 when it ships and
  lower to `swipeActionsContainer()` there, menu-only below 27; (b) lower
  a collection that declares swipe actions to a `List`, which changes its
  layout and scrolling on every Apple lane; (c) draw kaya's own swipe,
  which is not the platform's.
- **R3 — Android's reveal.** Material's phone library runs one action on
  a full swipe and reveals nothing. (a) RECOMMENDED: the `full` item
  swipes, the rest stay in the menu; (b) kaya builds a reveal on
  `anchoredDraggable` to Material's guidance.

## §4 — How a leg sees it

A `swipe_action <row> <item>` verb resolves the row's declared item
through the model and activates it through the same path the gesture
takes, `context_open`'s shape; on the phones a real gesture beside it
(the iOS driver's `swipe`, `adb input swipe`). An `expect_swipe_actions`
verb reads what each backend lowered (edge, labels, the full item).
