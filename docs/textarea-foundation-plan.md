# The text widget foundation — the design pass

Ratified in conversation 2026-08-06 (the maintainer's own proposal):
before ranges, a milestone that ONLY re-founds the textarea on every
platform's rich-CAPABLE native control, pinned to plain-text behavior.
No new protocol surface, no spec change, no binding change, no scene
change: a backend refactor with a parity exit bar. The evidence base
is the range-probe fleet (scratchpad/range-probe-*.md).

## The rule this milestone lives by

**Rich-capable CONTROL, plain-text CONTRACT.** The control under each
textarea becomes the one that can express attributed runs (ranges next
milestone, a rich content model someday); kaya's textarea contract —
string in, string out, text_changed, the uncontrolled fold — does not
move by one byte. Every opinion a rich control carries (smart quotes,
formatting shortcuts, RTF paste, autocorrect) is PINNED OFF with a
negative test each: a rich control's opinion shipping by accident is
this milestone's named failure mode.

User-facing rich text (bold/italic, formatted documents) is explicitly
NOT this: that is a future protocol milestone (attributed text on the
wire, in eight bindings' models, in the undo ledger's texts runs) that
this foundation makes cheap. Recorded in docs/deferred.md.

## The four arms (android needs nothing — measured at current pins)

| arm | today | becomes | plus |
|---|---|---|---|
| mac | bare SwiftUI TextEditor (uncontrolled ~11ms async push that destroys downstream state — measured) | NSTextView via NSViewRepresentable (the gap policy ratified 2026-07-20) | kaya controls WHEN text lands; the native find bar stays disabled (usesFindBar false — the ranges era must not fight Cmd+F) |
| ios | SwiftUI TextEditor (same file's #else) | UITextView via UIViewRepresentable | same control the range probe proved affordable at the iOS 16 floor |
| windows | TextBox (cannot color a range — proven twice) | RichEditBox in plain-text mode | the measured bindgen bill: Microsoft.UI.Text.winmd input + 22 filters, +11,893 generated lines, clean first generation |
| linux | bare GtkTextView with NO VIEWPORT (400 lines = 6400px tall — a shipped wart) | GtkTextView inside GtkScrolledWindow | fixes unbounded growth; the a11y tree changes, so the a11y legs re-prove |

Entries are untouched everywhere: they are fine at their job; their
range weaknesses are the RANGES milestone's recorded deferral.

## The exit bar (the whole point)

Per arm: every existing scene leg that touches a textarea (or anything
whose layout/a11y tree the change reaches) green on the changed
widget — the FULL lane, not spot checks; the a11y legs re-proven on
linux and windows; each pinned-off rich opinion watched failing when
its pin is deleted. Then the full matrix, ALL PASS, before the commit
proposal. No new gates: the existing matrix IS the parity instrument.

## Sequencing note

The four arms are independent (no shared files, no protocol) and run
in parallel, each against its own lane. Ranges (docs/ranges-plan.md)
lands next on the re-founded widgets; the editor after that.
