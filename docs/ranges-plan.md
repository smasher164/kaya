# Text ranges — the design pass

Status: LANDED 2026-08-07 (`b30e621`) — the three primitives in
crates/kaya/src/spec.rs, all five backends, the bindings, and
`tools/scenes/ranges.steps` on every runner.

The reshaped find milestone (ratified in conversation 2026-08-06: the
framework ships range primitives; the find bar, engine, and regex
dialect belong to the text editor app — the prior-art survey's forty
citations record the industry drawing the same line). Probe reports:
docs/probes/range-probe-*.md (mac, ios, linux, windows, android) and
docs/probes/find-*.md (frameworks, editors); every claim cites its arm.

## §0 — what the probes found

- **The primitives are affordable everywhere — but not on three of the
  widgets kaya ships today.** The capability gaps are widget-choice
  gaps, not platform gaps:
  - **mac**: kaya's textarea is a bare SwiftUI TextEditor, and the
    blocker is TIMING, not API — kaya does not control when text lands
    in the underlying AppKit view; that push (~11ms after the app's
    write, measured) destroys declared ranges and resets the selection
    to document-end. The fix is the ratified gap policy's own tool: an
    NSTextView through NSViewRepresentable, interpreter-internal.
  - **windows**: the textarea is a TextBox, which cannot express
    highlight AT ALL (proven twice: the full 120-method winmd surface
    and live reflection agree). RichEditBox can, and the switch is
    measured, not estimated: one new bindgen input
    (Microsoft.UI.Text.winmd, already inside the fetched package), 22
    filter entries, +11,893 generated lines (+7.7%), zero transitivity
    traps, and every needed method present (ScrollIntoView, GetRange,
    CharacterFormat, BatchDisplayUpdates). Readback must be
    provider-side in-process (a UIA client attach is fatal — the
    file-dialog era's crash class, re-proven with a discarded helper).
  - **linux**: highlight and select are cheap (GtkTextTag) and
    AT-SPI-readable, but REVEAL exposed a pre-existing hole: kaya's
    GtkTextView has NO VIEWPORT — the widget grows to its full content
    height (a 400-line buffer renders 6400px tall), so scroll-to-range
    moves nothing. Reveal requires wrapping the textarea in a
    GtkScrolledWindow: a layout and accessibility-tree change, and
    arguably a fix to a shipped wart independent of ranges.
  - **ios**: all three affordable on the textarea at the iOS 16 floor
    through public UIKit API.
  - **android**: all three affordable at current pins; no bump, no
    rewrite.
- **The ENTRY is the weak sibling everywhere, in different ways** —
  linux: highlight rides absolute byte offsets that do not follow
  edits, and neither reveal nor any geometry is observable over
  AT-SPI; ios: three distinct gaps (its report §entry); the entry is
  also not what the editor needs.
- **IME**: select_range during an active composition CANCELS the
  composition (measured on linux; the design treats this as the
  general hazard).

## PREREQUISITE (ratified 2026-08-06): the text widget foundation

The three widget upgrades originally proposed as this plan's D3 are
now their OWN milestone, first — docs/textarea-foundation-plan.md
(rich-capable control, plain contract, parity exit bar). This plan's
depth starts on the re-founded widgets. D3 below is superseded by
that plan and kept for the record.

## §1 — the decisions (RATIFIED 2026-08-06, D1-D6 as a set)

### D1 — three primitives, one widget kind: the TEXTAREA

`highlight_ranges` (a set), `select_range` (one), `reveal_range`
(scroll into view) — window-and-widget-addressed, app-declared,
backend-lowered. The ENTRY is deferred with per-platform verdicts
recorded (invariant 2's sweep: linux can't-honestly, ios can't-fully,
and no consumer — the editor is a textarea). Deferral is recorded in
docs/deferred.md with the three measured reasons, not silently.

### D2 — ranges are app-owned and re-declared; a text edit clears them

The app declares ranges as data (start, end byte offsets into the
authoritative text); any text change invalidates them (the core clears;
the app re-declares from its next fold — the same uncontrolled-contract
shape as text itself). No range tracking/adjustment machinery in the
core: tracking is editor-component territory (the survey's line), and
the mac timing measurement shows platform range-persistence cannot be
trusted anyway.

### D3 — the three widget upgrades ride this milestone

- mac textarea: NSTextView via NSViewRepresentable (the gap policy
  ratified 2026-07-20 sanctions exactly this drop-down), which also
  ends the ~11ms uncontrolled-push behavior.
- windows textarea: TextBox → RichEditBox, with the measured bindgen
  bill; plain-text mode pinned (the RTF behaviors other frameworks were
  bitten by get negative tests, not trust).
- linux textarea: gains its GtkScrolledWindow viewport (also fixes the
  unbounded-growth wart).
  EXIT BAR for all three: every existing textarea/entry scene leg stays
  green on the changed widget (the full lane, not spot checks), plus
  the a11y legs re-proven where the tree changed (linux, windows).

### D4 — selection during IME composition is REFUSED, loudly

A select_range while a composition is active is the D4-of-undo shape:
refused at apply with a named reason (measured: honoring it cancels the
user's composition mid-word — data loss shaped like a feature). The
app that wants it waits for the composition to end (text_changed
arrives then anyway).

### D5 — one verb family, per-backend reads, every read measured

`expect_highlights`, `expect_selection`, `expect_revealed` (or one
verb with a mode — depth decides the spelling; depth kept the three
verbs, and that is what harness.rs carries):
- mac: attributed-string state via the Representable's own view (plus
  AX selected-range where the probe proved it readable);
- windows: provider-side in-process reads — GetAttributeValue
  (BackgroundColor) / GetSelection / GetVisibleRanges, each proven
  live before trusted (an interface existing is not the provider
  implementing it — the arm's own words). NOT AVAILABLE, and the arm's
  own warning is why: WinUI publishes no Text pattern on an in-process
  automation peer, so nothing answers those three, and a UIA client is
  barred here. The reads went one layer down instead, to Rich Edit's
  document model — a per-character `BackgroundColor` scan,
  `Selection.StartPosition/EndPosition`, and `ITextRange::GetRect`
  against the control's bounds for the viewport;
- linux: AT-SPI for highlight and selection; reveal via the viewport
  geometry the new ScrolledWindow provides;
- ios/android: the interpreter's state reads, failing when the apply
  arm is deleted (the dirty-milestone precedent).

### D6 — spec-first: two commands and one prop (depth decides the
### exact op shapes); the hash moves; everything regenerates

## §2 — sequencing

Depth: spec + Rust surface + the MAC arm (because it carries the
Representable rewrite — the riskiest single piece) + the ranges scene
(guest-side literal matching driving all three primitives + the IME
refusal's negative test) green on mac with the full textarea-scene
blast radius re-proven. Breadth: windows (RichEditBox switch), linux
(viewport + tags), ios, android, seven bindings' sugar, C floor; the
matrix. The editor unblocks when this lands — and did: the editor was
written three days later.

## §3 — deliberately not designed

- No find engine, no find UI, no regex anywhere in the framework (the
  reshape's whole point; the editor owns them — and its regex dialect
  is already ruled: no backreferences, no lookaround).
- No range-adjustment-across-edits machinery (D2's rejection).
- No entry-widget ranges this milestone (D1's recorded deferral).
