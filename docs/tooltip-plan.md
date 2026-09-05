# Tooltips — the design pass (2026-09-05)

The maintainer's 2026-09-02 order names tooltips after sliders. DESIGN.md
already commits to "tooltips return as a plain property"; this is the pass
that says which property, what each platform does with it, and what a phone
does. The rulings were taken 2026-09-05 after the conversation recorded in
§1; the pickers and sliders passes are the precedents for the shape.

## §0 — What the platforms do

Read from the vendors' own documentation and, where the documentation was
silent, measured (dated below).

| | Trigger on a desktop | Trigger on touch | Pointer on a tablet or phone | Reaches the assistive reader as |
|---|---|---|---|---|
| macOS (SwiftUI `.help`, AppKit tooltips) | hover; keyboard focus through the help tag | — | — | `.help` sets the accessibility hint too (Apple's documented mapping); AXHelp |
| iPadOS (`.help`, UIToolTipInteraction) | — | none | tooltip on pointer hover (iPadOS 15+) | the accessibility hint |
| iOS on the iPhone | — | **none — long press is the context menu's** | none, even with a pointer attached | the accessibility hint |
| Android (`View.setTooltipText`, material3 `TooltipBox`/`PlainTooltip`) | mouse hover | **long press** (plain tooltips dismiss after about a second) | mouse hover | `AccessibilityNodeInfo` tooltip text |
| WinUI 3 (`ToolTipService.ToolTip`) | hover; **keyboard focus** | **press and hold** | — | UIA HelpText |
| GTK 4 (`gtk_widget_set_tooltip_text`) | hover after a delay; **NOT keyboard focus** (measured 2026-09-05 in the lane's container: Tab put the focus ring on a tooltip'd button and no tooltip came in 2.5s; the pointer hovering its neighbour drew one) | not measured — the lane injects no touch | — | the AT-SPI description |
| the web's `title` (for contrast) | hover | nothing on iOS Safari; Android Chrome shows it on long press | — | the accessible description |

What the guidelines say, in one line each. Fluent: a tooltip is supplemental
— if the text is essential it goes in the UI — one short sentence, never
interactive. Material: plain tooltips for icon buttons, rich tooltips with a
title and actions for more. Apple: help tags on the Mac; the phone offers
help through VoiceOver. GNOME: tooltips for controls whose purpose the
label does not make plain.

**The mobile web's first-tap "hover"** is a browser emulating CSS hover;
no native toolkit does it and kaya does not invent it. **The info button**
that opens an explanation is a different construct — essential text every
user must reach — and an app composes it today from a button and a popover.

## §1 — The rulings (RULED 2026-09-05)

The maintainer's questions, in order: does a mouse on a tablet or phone
show tooltips (yes on the iPad and on Android, never on the iPhone); does
the mobile web's first-tap count (no, it is the browser's); is the info
button the mobile equivalent (no, it is a different construct); is this a
different semantic construct that becomes a tooltip on the desktop and
something else on the phone (yes — Apple already named it: HELP TEXT); and
what about long press (Android and Windows do it natively; the iPhone
reserves long press for context menus, which kaya already uses).

### T1 — One universal prop, `help`

Plain text, one short sentence saying what the control is or does. Every
widget kind carries it, containers included, exactly as the two a11y props
do. Wire: PROPS `help` 26, `PropKind::Str`; the root refuses an empty one.
Sugar: `.help("…")` chained on Rust's widget, `help=` on Python's and JS's,
`?help` on OCaml's, the binding's own spelling elsewhere; in the template
zone a SOURCED prop (a row's help can be the row's own field), like the
a11y label.

### T2 — kaya draws no tooltip of its own

Each platform's own surface, timing and placement: the Mac's help tag, the
iPad's pointer tooltip, Android's tooltip on hover and long press, WinUI's
on hover, focus and press-and-hold, GTK's on hover. The iPhone shows nothing
visible and hands the text to VoiceOver — Apple's own idiom, stated here
once for every platform without a pointer: help reaches such a platform's
reader and nothing else. No kaya-drawn bubble on long press there, since
long press is the context menu's.

### T3 — Help and the accessibility hint are distinct; an authored hint wins

The hint says what activation does (a verb phrase, activation kinds only);
help says what the control is (any kind). Where a platform routes help to
its reader itself — Apple's `.help` sets the hint, WinUI's tooltip is UIA
HelpText, GTK's tooltip is the AT-SPI description, Android exposes the
tooltip text — that stands, and where both are authored on one widget the
hint occupies the hint slot. On SwiftUI that is an ordering: `.help` goes
on before `.accessibilityHint`, and the scene asserts the outcome rather
than assuming it.

### T4 — Rich tooltips refused

No titles, actions or images inside a tooltip. Material and WinUI offer
them; Apple and GTK do not, and Fluent's own guidance forbids interactive
content there.

### T5 — Read-back, and one measured surface per desktop

`expect_help <target> "text"` reads the help back from the PLATFORM — the
control's tooltip property on GTK and WinUI, the accessibility tree's help
or hint on Apple (AXHelp on the Mac, the hint on iOS), the tooltip state on
Compose — never kaya's model. It needs the target's authored `a11y_id`
where the read goes through the accessibility tree, as `expect_ax` does.
The visible bubble is pixels no verb reads, so it is measured once per
desktop with a real pointer (GTK's above; the Mac's and Windows' in §6 as
they are taken) and recorded, not asserted per run.

## §2 — The wire

One prop, no occurrence: help emits nothing. PROPS 26 `help` Str; the
generated setters (`tx_set_help`) and the C floor's constant ride every
emitter's existing string arm. Universal legality in scene.rs beside
`A11yId | A11yLabel`; the empty-string refusal beside the label's.

## §3 — The harness

`expect_help` and a no-default Stage method `help_text`, with the mocks.
On SwiftUI the verb reads the same accessibility attribute the hint verb
reads (that is where `.help` lands); GTK reads `tooltip_text()` off the
control; WinUI reads `ToolTipService.GetToolTip` as a string; Compose reads
the node's help state, which is what its TooltipBox draws from.

## §4 — The sweep

`help` in nine bindings in both zones (the a11y label's spelling in each),
tools/check-sugar-surface.py's universal-prop clause grown by one,
tools/check-universal-props.py holding the GTK and WinUI arms on the prop
alone and the SwiftUI wrapper unbypassed and the Compose per-kind modifier
carrying it; a `tooltips` scene in all nine guests on five rosters.

## §5 — Build order

Depth: spec, core, Rust sugar, `expect_help`, the SwiftUI arm, the GTK and
WinUI one-line arms with their readers, tools/scenes/tooltips.steps with
guests/rust/tooltips.rs green on the mac, linux and windows. Breadth: the
Compose arm (a TooltipBox around every kind's composable, the help state
field, the verb), the eight other bindings with nine guests, the iOS and
android rosters, the matrix.

## §6 — Measured on the way

- GTK 4 shows no tooltip on keyboard focus (2026-09-05, above).
- On the Mac a SwiftUI CONTAINED GROUP publishes no help through the
  accessibility tree: a column with `.help` read AXHelp "" on the first
  tooltips leg, and an explicit `.accessibilityHint` on the group read ""
  too (2026-09-05). The prop stays universal — the bubble draws over the
  container on hover — but the shared scene asserts help on leaves, and a
  container's tooltip is a capture's to witness.
- A stamped copy's help is read through the copy's accessibility
  identifier on Apple, so copies sharing one authored id cannot be told
  apart there (the first tooltips leg read the entry's help for both rows,
  which shared its id). The scene sources the copies' ids from the row's
  own field and addresses them by index, the a11yrows scene's shape.
- The authored hint wins over `.help` on the Mac when `.help` is applied
  first (measured on button#1 the same day: T3's ordering holds).
