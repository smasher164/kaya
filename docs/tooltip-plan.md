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
| iPadOS (`.help`, UIToolTipInteraction) | — | none | **NONE — iPadOS draws no tooltip at all.** Apple's UIToolTipInteraction page: "Tooltips appear when your app runs in macOS or visionOS"; SwiftUI's `help` page: the help tag appears "in macOS or visionOS". The API exists on iPadOS so an iPad app shows tooltips when it runs on a Mac (Apple silicon or Catalyst). Measured to match 2026-09-05: kaya's Save, Safari's back button, and a four-control probe (UIControl.toolTip, UIToolTipInteraction, SwiftUI `.help` on a Button and a Text) all raised nothing under the simulator's pointer | the accessibility hint |
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
do. Wire: PROPS `help` 26, `PropKind::Str`; the root refused an empty one until T6 made it the opt-out.
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

Each platform's own surface, timing and placement: the Mac's help tag,
Android's tooltip on hover and long press, WinUI's on hover, focus and
press-and-hold, GTK's on hover. The iPhone shows nothing visible and hands
the text to VoiceOver — Apple's own idiom, stated here once for every
platform without a pointer: help reaches such a platform's reader and
nothing else. THE iPAD IS SUCH A PLATFORM: iPadOS draws no tooltip for a
pointer at all — Apple's documentation for both UIToolTipInteraction and
SwiftUI's help says the bubble appears in macOS or visionOS, and the
iPadOS API exists so an iPad app shows tooltips when it runs on a Mac —
which kaya's `.help` already covers there (§6). The survey's first draft
had the iPad wrong. RATIFIED by the maintainer 2026-09-05 after the
measurement: no kaya-drawn tooltip on iOS or iPadOS — "most apps on
ios/ipados aren't trying to draw tooltips, so probably not worth it to try
to draw it ourselves." No kaya-drawn bubble on long press there, since
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

### T6 — Button-like controls default to their name (RULED 2026-10-25)

The maintainer, after a hand test of the music app: "by default we should
have tooltips for anything that is button-like." On the three DESKTOPS
(SwiftUI on the Mac, GTK, WinUI) a button-like control the app gave no help
shows its accessible name as its tooltip: the app's `a11y_label` when it set
one, else the control's text (an icon-only button's text is its name). The
button-like controls are the button kind in every role (text, prominent,
destructive, plain, icon-only), the checkbox in `role toggle` (the toggle
button), and every segment of a segmented control (which carry no help of
their own, so a segment's tooltip is always its name). NOT included: plain
checkboxes, switches and radios (their caption sits beside them), selects
(they show their value), links (the label kind; GTK's link button already
shows its address), and activatable rows, cards and columns, whose
accessible name is their own visible content and whose platforms (Finder,
Music, Files, Explorer) give a list row or a tile no tooltip; an app that
wants one there sets `help`.

The app's help wins, and AN EMPTY HELP HIDES THE DEFAULT: `help("")` is the
opt-out, through the setter every binding already has (the root refused an
empty help until this ruling; now it passes it through to the backend). The
phones show nothing (§0: no hover; iOS and iPadOS draw no tooltip, and a
default hint would make VoiceOver speak the name twice), and Compose takes
no default either: its long press would show the name over a phone's
button. Where a desktop routes help to its reader (AXHelp, the AT-SPI
description, UIA HelpText) the default rides along, as the platforms' own
toolbar buttons do. tools/scenes/music_header.steps reads a default on the
three desktops, tools/scenes/tooltips.steps the opt-out on all five lanes.

### T7 — A label cut short shows its whole text (RULED 2026-10-25)

The maintainer said yes to: on the three desktops, a label cut short with an
ellipsis (a `max_lines` label, a card's or a row's title among them) shows
its whole text as its tooltip on hover, as Finder, Music and Mail do; the
same label shown whole shows none, so T6's exclusion of plain labels, rows
and cards stands. The app's help still wins and `help("")` still opts out.
Each toolkit's own signal decides "cut short":

- SwiftUI (macOS): Text has no expansion tooltip (it is not an NSTextField),
  so a capped label carries KayaTruncationReader, a ViewThatFits behind it
  holding the label's text at the label's width with no line limit to the
  label's height; the branch that fits sets the node's `truncated`, and
  kayaShownHelp gives a cut label its text. Layout only, no GeometryReader
  (docs/traps.md, the mac app's interaction latency), and only on labels
  with `max_lines`, the only ones that can be cut.
- GTK: no built-in either. A capped label has a `query-tooltip` handler that
  answers the label's text while its Pango layout `is_ellipsized()`; the help
  reader asks the same function for a label with no tooltip text.
- WinUI: `TextBlock.IsTextTrimmedChanged` re-derives the tooltip
  (default_tip), whose label arm is the text while `IsTextTrimmed`.

The phones show none (no hover; §0): iOS and Android read `""` for the cut
label in their tails. tools/scenes/tooltips.steps reads `label@cut` (80 wide,
one line) as its text and `label@whole` (the same text, one line, room to
spare) as `""` on the desktops.

On the Mac a helped CONTAINER's bubble covers its children's: over the
tooltips scene's cut label and its stamped labels (each with help of its
own) AppKit drew the column's "The settings for this account", while AXHelp
on the label read the label's own (§6, measured 2026-10-26; docs/deferred.md,
a helped container's bubble covers its children on the Mac).

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

**LANDED 2026-09-05** in that order: the depth slice on the mac, linux and
windows (5f789d5), the breadth slice as two worktrees merged (Compose; the
eight bindings with the mac and iOS lanes), the remaining rosters at the
merge, and the fifth matrix on the merged tree ALL PASS on all five lanes and 55 gates, 1,691 legs (mac 427, linux 737, windows 265, ios 127, android 135) in 734s, launched detached at a one-minute load of 4.7 — the four before it each green on every lane but android's one contended leg (dnd-compose twice, save-jvm once, dnd-jvm once) or linux's wayland JS clipboard leg once, every one of them a pre-existing WATCH class green alone the same hour, every tooltips leg green on every lane in all five, and two of those WATCHes took their instruments on the way (the wayland clipboard's focus premise; the Compose drag verb's settled-box wait, which closed the stale-arrangement cause and left the emulator's drag session under contention as the open remainder)

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
- THE iPAD DRAWS NO TOOLTIP, and the survey had said it did (2026-09-05).
  The maintainer's own hovers on kaya-sim-pad with Simulator's pointer
  sent to the device raised nothing on kaya's Save button (guest confirmed
  alive), nothing on Safari's own back button, and nothing on any of four
  controls in tools/ios/tooltipprobe (UIControl.toolTip, a
  UIToolTipInteraction on a label, SwiftUI `.help` on a Button and on a
  Text). Apple's documentation, read after: UIToolTipInteraction —
  "Tooltips appear when your app runs in macOS or visionOS. To show a
  tooltip in macOS, your app must be an iPhone or iPad app running on a Mac
  with Apple silicon, or built with Mac Catalyst"; SwiftUI `help(_:)` —
  "configures the view's accessibility hint and its help tag (also called a
  tooltip) in macOS or visionOS". So iPadOS never shows one, with or without
  a trackpad; the iPad is a phone for help, the iPhone's rule covers it, and
  nothing is owed. The simulator was never the limit (Xcode 11.4's release
  notes: pointer capture forwards HID events; "any system that injects
  CGEvents directly isn't usable with Simulator's capturing support").
- The iOS help/hint reader walked the window tree off the main thread and
  UIKit logged "Unsupported layout off the main thread for UITextField" on
  every tooltips leg (device log, 2026-09-05); the reader hops to the main
  thread now, the Mac reader's shape.
- The authored hint wins over `.help` on the Mac when `.help` is applied
  first (measured on button#1 the same day: T3's ordering holds).
- ON THE MAC THE OUTER `.help` WINS THE BUBBLE (measured 2026-10-26, the
  tooltips scene held on an idle host, the guest made frontmost and a real
  pointer rested on each label): over the stamped label `a` (help "The
  first account, opened in March") and over the cut label of T7 the bubble
  read the root column's "The settings for this account" (as it should over
  the whole label, which has none of its own); with the column's help taken out of a scratch copy of the guest
  the cut label's bubble read its own text. AXHelp read each label's own help
  throughout, so expect_help cannot see it. GTK and WinUI drew the cut
  label's own over the same column (T7's captures).
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
  pick the innermost widget under the pointer (the Mac does NOT, measured
  2026-10-26 below). Left as the toolkit's:
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
