# Following the end of a scroll — the design pass

Status: BUILT 2026-09-25 on all four backends and in all nine bindings,
the chat scene green on five lanes. The prop is ruled (docs/chat-plan.md R4, 2026-09-25: "if any
backend does not keep the newest row in view by itself, it becomes a scroll
prop with one meaning on every backend"). R4 was measured the same day: no
backend does. The details below are RECOMMENDED. The chat app is the first
consumer (docs/chat-plan.md C1).

## §1 — The semantics

`follows_end` on a `scroll`, a boolean, off by default.

- While the viewport shows the END of its content, content that grows keeps
  the end in view: a row appended to a chat thread that was showing its
  newest message leaves the new row showing.
- Once the user has scrolled away from the end, growth leaves the view
  where it is: someone reading an older message is not pulled down.
- Returning to the end, by the user's scroll or by the app's
  `scroll_to_row`, engages it again.
- "At the end" is decided at the moment BEFORE the content grows, within
  one line of text (the platform's own line height, rounded to its units),
  so a view a pixel short of the end still follows.
- It governs growth only. It never moves the view on its own for any other
  reason, and the app's `scroll_to_row` still goes wherever it is told.

## §2 — The lowerings

| backend | mechanism |
|---|---|
| SwiftUI | record whether the scroll sat at its end before each content-size change and, if it did, scroll the proxy to the end after it, without animation (`defaultScrollAnchor(.bottom, for: .sizeChanges)` is macOS 15 / iOS 18 and kaya's floor is macOS 13 / iOS 16) |
| GTK | the vertical adjustment's `changed` signal: if `value` was within a line of `upper - page_size` before the change, set it to the new `upper - page_size` |
| WinUI | `ScrollViewer.ViewChanged` records whether the view is at the end; `SizeChanged` on the content scrolls to the new end with `ChangeView(..., disableAnimation: true)` when it was |
| Compose | the scroll state's position against its max before the content's size changes, and `scrollTo(maxValue)` after it when it was at the end, never the animated form |

## §3 — How a leg sees it

`expect_at_end` already reads the viewport's own geometry on all four
backends. The chat scene stops scrolling to an arriving reply itself and
asserts `expect_at_end` after it (the follow), then jumps up to a quoted
message, lets a second reply arrive, and asserts the quoted message is still
in view (the user's position kept).

## §4 — The surface

Every binding spells it where its scroll's other options live: a chained
`.follows_end(true)` in Rust, `FollowsEnd()` in Go, `followsEnd: true` in
Swift, `follows_end=True` in Python, and so on per binding.
