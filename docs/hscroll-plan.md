# A scroll that runs sideways — the design pass

Status: BUILT 2026-09-28 on all four backends and in all nine bindings;
the right-to-left conventions each platform needed are in docs/traps.md
("a sideways scroll under right to left"). Designed the same day. The roadmap's first piece for the video editor
(its timeline and filmstrip) and the commerce carousel. Every choice below
is RECOMMENDED and needs no ruling to build: it reuses a prop kaya already
has and generalizes rules kaya already states. The ledger entry it closes:
docs/deferred.md, "Horizontal scroll axis: an axis enum prop".

## §1 — The surface

The `axis` prop a row and a column already carry (spec.rs prop 18,
`horizontal` 0 or `vertical` 1, docs/adaptive-layout-plan.md D1) becomes
legal on a `scroll`, where it names the direction the content scrolls.
Never set, a scroll is vertical, as every scroll is today. It is mutable
like any prop and a breakpoint may set it, as it may a container's.

No new word, no new record, and every binding already spells `axis` on a
widget handle, so an app writes `scroll.axis(horizontal)` in its own
binding's idiom. There is no `both`: no consumer on the roadmap pans in two
directions, and a zoomable canvas or image is the gestures item.

## §2 — The rules that follow the axis

Every rule kaya states about a scroll today is stated about its vertical
axis. Each becomes a statement about the scroll's own axis, and nothing
else changes.

- **Grow.** A weight on a child of a container running along the
  scroll's axis has nothing to divide and is refused at the root
  (DESIGN.md, "grow along a scroll's own axis"). Under a horizontal
  scroll that is a row's grow; a column's grow stays legal, bounded by the
  scroll's height.
- **The cross axis.** The content spans the scroll's cross axis, as a
  vertical scroll's content spans its width today: a horizontal scroll's
  content is as tall as the scroll, and the scroll hugs its content's
  height when nothing gives it one.
- **`follows_end`** follows the trailing end.
- **`scroll_to_row`** puts the row's leading edge at the viewport's leading
  edge.
- **The verbs** `expect_overflow`, `scroll_end`, `expect_at_end` and
  `expect_scrolled_to` read the scroll's own axis. No new verb.
- **`expect_no_clipping`** excuses overflow along the scroll's axis, as it
  excuses a vertical scroll's today.
- **Right to left.** Leading and trailing are the reading direction's: in
  Arabic a horizontal scroll starts at its right edge and its end is the
  left. Each platform mirrors its own scroll view; §4 measures that each
  one does before any arm relies on it.

A For inside a horizontal scroll stamps its rows as it does inside a
vertical one. Only a table is windowed (docs/virtualization-plan.md), and a
table scrolls its own columns, so nothing about windowing moves.

## §3 — The lowerings

| backend | mechanism |
|---|---|
| SwiftUI | `ScrollView(.horizontal)`; the content's height spans the viewport the way the vertical arm spans its width |
| GTK | `ScrolledWindow` policy `(Automatic, Never)` instead of `(Never, Automatic)`; the verbs read `hadjustment` |
| WinUI | `ScrollViewer` with the horizontal mode and bar enabled and the vertical ones disabled; the verbs read the Width/Offset pair |
| Compose | `horizontalScroll(state)` instead of `verticalScroll`; the verbs read the same `ScrollState` |

The table's own column axis already reads horizontal geometry on every
backend (`scroll_axis` on GTK, the columns arm on WinUI, `columnsAxis` on
Compose), so each backend has a horizontal reading to follow.

## §4 — What is measured first

1. Right to left, per platform: where a horizontal scroll rests at start,
   and which end `scroll_end` reaches, under `KAYA_LOCALE=ar-EG`.
2. SwiftUI's cross-axis span: the iOS vertical scroll was once as wide as
   its content (docs/traps.md, "iOS scroll viewport is as wide as its
   content"); the horizontal arm must not inherit the mirror image.

## §5 — How a leg sees it

The existing scenes carry it, so every lane and language already running
them runs it: tools/scenes/scroll.steps gains a strip wider than the window
in a horizontal scroll (`scroll@strip`), read with `expect_overflow`, the new
`expect_at_start`, `scroll_end` and `expect_at_end`, then a click on its last
card; tools/scenes/scrollto.steps gains a filmstrip whose For container runs
sideways, with `scroll_to_row` to a middle frame and `follows_end` holding
the trailing end as a frame is appended; tools/scenes/scrollrtl.steps runs
the scroll guest's strip under `ar-EG` on all five lanes. The grow refusal
is a unit test in the core, both directions.

## §6 — Guards

- The core's barrier is a unit test in both directions.
- check-sugar-surface: `axis` on a scroll handle in all nine bindings.
- check-scroll-to: the horizontal arm of each backend's `scroll_row` reads
  the horizontal pair.
