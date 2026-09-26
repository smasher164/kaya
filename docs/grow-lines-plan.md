# A textarea that grows with its text — the design pass

Status: BUILT 2026-09-25 on all four backends and in all nine bindings,
the chat app's compose field on five lanes. The chat app's C1b (docs/chat-plan.md). The
first capture of the chat app found the need: a kaya textarea is several
lines tall at rest, so a compose field is either a single-line entry (no
newline, no room for a long message) or a box that dominates the screen.
Every chat client uses the third shape: one line at rest, growing with the
message to a few lines, then scrolling inside itself.

## §1 — The semantics

`max_lines` on a `textarea`: a whole number of at least 1.

- Unset, the textarea is what it is today.
- Set, the textarea is ONE line tall when empty, grows by whole lines as its
  text wraps or breaks, stops growing at `max_lines`, and scrolls its own text
  beyond that. The row it sits in grows with it, from the bottom up when the
  row is pinned under a growing sibling (a chat's compose row under its
  thread).
- The line height is the platform's own for the textarea's font, so the
  numbers are lines, never points.
- It composes with `submits`: a submitting textarea with `max_lines` is the
  chat compose field (Return sends, Shift+Return breaks the line).

## §2 — The lowerings

| backend | mechanism |
|---|---|
| SwiftUI | `sizeThatFits` on kaya's own text view (NSTextView, UITextView): the text's used height between one line and `max_lines` of its font; BUILT this way rather than as `TextField(axis: .vertical)`, which would have left the textarea's rich text, undo and submit wiring behind |
| Compose | the text field with `minLines = 1` and `maxLines = max_lines` and no fixed height |
| GTK | the text view's scroller with `propagate_natural_height` and a `max_content_height` of `max_lines` lines of the view's font |
| WinUI | the TextBox measured at its content with a `MaxHeight` of `max_lines` lines of its font, scrolling its own text beyond |

## §3 — How a leg sees it

It does not, and that is recorded rather than papered over: a height is not
portable, and the chat app has no reference row of one line to compare the
field against. The four arms are held by check-universal-props' growing
textarea clause, and the captures of a long message on every lane are the
observation (the chat review page).

## §4 — The surface

Every binding spells it where its textarea's options live: `.max_lines(5)`
in Rust, `MaxLines(5)` in Go, `maxLines:` in Swift and C#, `max_lines=` in
Python, and so on.
