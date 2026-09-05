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
| Android (`View.setTooltipText`, material3 `TooltipBox`/`PlainTooltip`) | mouse hover | **long press** (plain tooltips dismiss after about a second) | mouse hover | `AccessibilityNodeInfo` tooltip text — but NOT from Compose, which publishes none (measured 2026-09-05, §6); kaya's arm publishes the long-press action's label instead |
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
Sugar: THE A11Y LABEL'S SPELLING IN EACH BINDING, since the three
universal props must not be spelled three ways inside one binding —
`.help("…")` chained on Rust's widget and on python's and JS's shared
handle (the design pass guessed `help=` there; python and JS spell
`a11y_label` as a chained method, so a constructor keyword would have made
the third universal prop the odd one out in the two bindings where the
other two are most alike), `?help`/`?help_bind` on OCaml's constructors
beside `set_help`, and the binding's own spelling elsewhere; in the
template zone a SOURCED prop (a row's help can be the row's own field),
like the a11y label.

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
- WinUI's tooltip drew above the pointer on the VM (2026-09-05) only when
  the pointer MOVED through the input queue (`mouse_event` relative moves
  onto the Save button): a bare `SetCursorPos` teleport gave the Slider no
  PointerEntered and no bubble came. Centred above the pointer and not
  constrained by the window, the bubble ran past the window's left edge on
  a window parked at the screen's edge, exactly as the WinUI design page
  says it may. The Mac's bubble is not captured: a hover there drives the
  maintainer's live pointer, which only the walled drag driver may do.

- COMPOSE PUBLISHES NO TOOLTIP TEXT TO ACCESSIBILITY AT ALL (2026-09-05,
  emulator-5554, android 35): §0's Android row is true of
  `View.setTooltipText` and false of Compose. compose-ui 1.7.5 declares no
  tooltip semantics key (the 37 in `SemanticsProperties`) and its
  accessibility delegate never names one, so
  `AccessibilityNodeInfo.tooltipText` read null on EVERY node of the
  tooltips scene with material3's TooltipBox around each one. Material's
  own contribution to the reader is the anchor's long-press action LABEL,
  the string "show tooltip". So the Compose arm publishes the help itself,
  in the slot Android has for it: the LONG-PRESS ACTION'S LABEL, the
  hint's mechanism one key over (`onLongClick(label = help, action =
  null)`; the delegate adds ACTION_LONG_CLICK with the label whenever the
  action is present, even with a null action function — read out of the
  bytecode, then measured). T3 holds there on the platform: button#1
  carries the authored hint in the CLICK action's label and the help in
  the LONG-CLICK action's, two slots, neither disturbing the other.
- THE LABEL RIDES BOTH NODES, because material3's tooltip anchor sets
  `mergeDescendants = true`: a widget that is a merging root of its own (a
  Button) stays the node a service focuses, while a plain LABEL is
  ABSORBED into the anchor — and the anchor's own "show tooltip" then wins
  the label by the action key's merge policy (the parent's label, the
  child's action). The first Compose reading had exactly that: the two
  stamped labels read "show tooltip" and not the row's help. So the help
  is applied twice, in the `a11y` chain (the widget's own node) and as the
  TooltipBox's `modifier` (the anchor), and the second reading shows every
  helped node — leaves, stamped copies and the container — carrying its
  own help. One consequence, unasserted by any scene: a helped LEAF is
  absorbed, so its `a11y_id` test tag is not in the merged tree and an
  `expect_ax` on it would read "nothing carries test tag".
- A LONG PRESS INSIDE A HELPED CHILD OF A HELPED CONTAINER SHOWS BOTH
  BUBBLES on Compose (measured 2026-09-05, capture over the Save button:
  "Saves the draft to disk" with the root column's "The settings for this
  account" beside it). Material's anchor detects the press on the Initial
  pass at every level and neither stands down, where GTK, WinUI and AppKit
  pick the innermost widget under the pointer. Left as the toolkit's:
  arbitration would be kaya's own invention, and a composition local flows
  down, so an ancestor cannot learn that a descendant is helped.

- ON THE IPHONE, MEASURED 2026-09-05 on kaya-sim-0 with the tooltips
  scene HELD (the shared steps plus `settle 25000`), the rust-swiftui
  bundle: **the help text reaches the accessibility tree as the hint, and
  a long press shows nothing.** The hint half is the app's own read —
  iOS's `expect_help` is `kayaAxHintRead`, which walks the real
  UIWindow accessibility tree and answers with the element's
  `accessibilityHint` — and all seven reads passed before the settle
  (`expect_help button#0/entry#0/slider#0`, the rewritten `entry#0`, both
  stamped labels, and `expect_ax_hint button#1`). XCUITEST CANNOT ANSWER
  THE HINT HALF AT ALL: its element tree publishes label, identifier,
  value, frame and type and no hint, which is why the console of the held
  run is the reading. The long-press half IS an outside read: the XCUITest
  driver pressed the real Save button (found by label at 16,166,61,34) for
  1500ms, and the element tree taken 2s later was IDENTICAL to the one
  before it — 31 elements both times, zero added with the pointer
  addresses normalized. No tooltip, and no context menu either, since kaya
  declares none. T2's "nothing visible on the iPhone" is measured, not
  assumed.
