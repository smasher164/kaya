# The colour picker: the design pass

Status: DESIGNED 2026-09-28; the DEPTH SLICE BUILT 2026-09-28 (the spec, the
core, the generators, the harness, the SwiftUI arm, the Rust binding and
tools/scenes/colorpicker.steps on the mac lane; docs/deferred.md holds the
breadth). §4.1 and §4.5 are MEASURED and AMEND §5 in two places, marked
below. The roadmap's fourth piece for the
video editor ("a new kind, native on four lanes and synthesized on
Android"; docs/deferred.md's forcing-app entry names the colour picker
among the editor's triggers), where the inspector sets a title's colour,
and a should-have for editors and annotation tools in the needs survey
(docs/probes/roadmap-app-needs-2026-09-05.md, the video editor's
must-haves; docs/probes/roadmap-framework-parity-2026-09-05.md, A7). Every
choice in §1 to §7 is RECOMMENDED and needs no ruling; §8 asks two.

## §1. What the platforms have

Read from the vendors' documentation on 2026-09-28; §4 lists what is
measured before an arm relies on it.

| | the control | the surface it opens | value | alpha by default | reports | eyedropper |
|---|---|---|---|---|---|---|
| macOS | SwiftUI `ColorPicker(_:selection:supportsOpacity:)` (macOS 11); AppKit `NSColorWell`, styles `default` (opens the system colour panel), `minimal` (a popover), `expanded` (both), macOS 13 | `NSColorPanel`, ONE shared panel per app (`NSColorPanel.shared`), modeless, on the host's screen | `Color`; the panel's colour can be in any colour space (generic, Display P3, a named catalog colour) | on for `ColorPicker` ("by default color picker supports colors with opacity"); `NSColorPanel.showsAlpha` is a panel-wide switch | the binding moves while the user drags (`isContinuous`); the panel has no "done" | the panel's magnifier, always drawn |
| iOS | the same `ColorPicker` (a `UIColorWell`) | `UIColorPickerViewController` (iOS 14), a popover or sheet | `UIColor`, extended range (Display P3 components can fall outside 0..1 in sRGB) | on (`supportsAlpha` "By default this value is true") | `colorPickerViewController(_:didSelect:continuously:)`: "A continuous selection is always followed by a noncontinuous one when the user finishes the gesture"; `colorPickerViewControllerDidFinish` on dismissal | drawn; `supportsEyedropper` (iOS 26) can hide it |
| GTK 4 | `GtkColorDialogButton` (4.10), a swatch button; `GtkColorChooser` and its widgets are deprecated since 4.10 | `GtkColorDialog`, a modal dialog with a palette and a custom editor | `GdkRGBA`, four floats, sRGB | on (`with-alpha` defaults TRUE) | `choose_rgba` finishes ONLY on Select (Cancel or close is an error, no colour); the button then sets `rgba`, whose `notify` fires for a programmatic `set_rgba` too | the editor's pick button, through `GtkColorPicker` (the portal's `Screenshot.PickColor`, returning sRGB doubles, then GNOME Shell, then KWin), drawn only when one answers |
| WinUI 3 | `ColorPicker`, an inline control (spectrum, sliders, hex and channel boxes); `IsAlphaEnabled`, `ColorSpectrumShape`, `IsMoreButtonVisible`, `IsHexInputVisible` | none of its own: Microsoft's guidance hosts it in a `Flyout` on a button | `Windows.UI.Color`, 8-bit ARGB | off (`IsAlphaEnabled` "The default is false") | `ColorChanged` on every movement; the guidance: "When used in a flyout, tapping in the spectrum or adjusting the slider alone should not commit", commit with OK and Cancel or "upon dismissing the flyout" | none |
| Compose | nothing: Material 3 specifies no colour picker, so material3 has none, and the framework has none (the survey's catalogue reading) | | | | | |

Sources: Apple's pages for SwiftUI `ColorPicker`, `NSColorWell` and its
`Style` cases, `NSColorPanel` (`showsAlpha`, `isContinuous`),
`UIColorWell`, `UIColorPickerViewController` and its delegate's two
methods, and `NSColor.usingColorSpace(_:)`; GTK's `ColorDialogButton`,
`ColorDialog` and `ColorChooser` pages at https://docs.gtk.org/gtk4/ with
gtkcolordialog.c, gtkcolordialogbutton.c and gtkcolorpicker.c (main), and
the portal's Screenshot interface; Microsoft's color-picker design page
(https://learn.microsoft.com/en-us/windows/apps/design/controls/color-picker)
and the `ColorPicker` class pages; for Android the surveys above and
Google Calendar's eleven named event colours
(https://developers.google.com/apps-script/reference/calendar/event-color).

Where they agree: a swatch that shows the current colour and opens a larger
surface; the value is an sRGB colour with an optional alpha; the user's
dragging is not the answer until something says it is. Where they differ:
alpha's default, whether the surface is modal (GTK), a flyout (WinUI), a
popover or sheet (iOS) or a shared modeless panel (macOS), and when each
reports a finished choice.

## §2. The surface

A new widget kind, `color_picker` (kind 21), in both construction zones,
presented as ONE thing everywhere: a swatch button showing the value, which
opens the platform's own surface (the date pickers' D6 rule: the compact
field, never inline). Its props:

- `color` (44, a new `PropKind::Color`): the committed value, always set
  (the pickers' D5: no empty state). Default opaque black.
- `alpha` (45, Bool): whether the user may choose translucency. Off by
  default (§3 rule 3).
- The label is the app's: a `labeled` row or the universal `a11y_label`,
  as for every other control. No title prop.

**One occurrence, `color_changed` (36), spelled `on_color`,** carrying the
committed value on the widget's identity tag, keys first when stamped
(`date_changed`'s shape, datetime-plan D7). An app write never echoes (the
echo doctrine; GTK and WinUI arm their quiet guard, since GTK's `notify::rgba`
and WinUI's `ColorChanged` both fire for programmatic writes). A commit
whose value equals the old value does not fire.

**The value type.** `PropKind::Color` rides the existing I64 as packed
`0xRRGGBBAA`, straight (not premultiplied) alpha, sRGB, 8 bits a channel:
the Date and Time precedent (a label the generators turn into a typed
setter and decoder in every binding, datetime-plan D2), and the same
spelling the canvas palette (crates/kaya/src/canvas.rs, `0x1C71D8FF`) and
the ruled literal paint floor use (docs/canvas-plan.md ruling 13). Each
binding gets a small `Color` value (r, g, b, a bytes, with a hex
constructor); none of the nine languages has a standard colour type
outside a UI toolkit, so this is kaya's own, and canvas's literal paint,
ruled and not yet built, takes the same type when it is. The template zone
binds a stamped picker to a row field, records learning a `Color` field
type the way they learned `Date` (datetime-plan D10, ruled WIDE).

This is data, not styling. docs/tints-plan.md keeps raw colours off
widgets; a colour the USER picks is the app's data (a title's fill in the
editor's canvas), and the picker's swatch is the platform's drawing of it.
Nothing here lets an app paint a widget.

## §3. The rules

1. **One colour space, converted at the edge.** A backend converts whatever
   its surface hands back to sRGB through its own platform
   (`usingColorSpace(.sRGB)`, UIColor's sRGB components), and one core
   function clamps each channel to 0..1 and rounds to 8 bits, so every
   backend quantizes the same way. A Display P3 colour outside sRGB is
   clamped: the app gets the nearest sRGB colour, never an extended value.
   An app write shows exactly its bytes (8-bit to float and back is exact).
2. **A settled choice commits; a drag does not.** On a surface that closes
   when the choice is made (GTK's dialog, WinUI's flyout, Android's sheet)
   the close commits, and GTK's Cancel commits nothing. On a surface that
   stays open (Apple's panel, popover and sheet) the end of each gesture
   commits: UIKit's noncontinuous select, and on the mac the panel's mouse
   up (§4.1). The app sees a sequence of committed colours, never an
   intermediate one; how many commits one visit to the surface makes is
   the platform's. The slider's `value_committed` is the precedent;
   the live twin is §8 ruling 1.
3. **Alpha off unless asked.** The platforms disagree (Apple and GTK on,
   WinUI and the panel's `showsAlpha` off); off is the case a title colour,
   a highlight or a label colour wants. With `alpha` off the surface draws
   no opacity control, the value's alpha is always FF, and the root refuses
   an app write whose alpha is not FF (the slider's range refusal, rather
   than SwiftUI's silent strip).
4. **The eyedropper is dress.** Drawn where the surface draws one (the mac
   panel's magnifier, iOS's eyedropper, GTK's pick button when a portal
   answers); no prop, no verb. Its pick commits like any other choice.
5. **The swatch is the platform's where the platform draws one.** On
   Apple and GTK its size, border and checkerboard for translucency are the
   control's own. WinUI and Compose have no swatch control, so kaya faces a
   button with a fill at the platform's control corner radius, over a
   checkerboard when the value is translucent; dress in DESIGN.md's sense.

## §4. What is measured first

1. **The mac commit.** What SwiftUI's `ColorPicker` is on this OS (which
   `NSColorWell` style, and whether it opens the shared panel or a
   popover), whether its binding moves per drag event, and which door
   says a gesture ended: the shared panel's `isContinuous` set false
   while this well is active, or the panel's own mouse up. Also that two
   wells with different `alpha` each get their own `showsAlpha` although
   the panel is shared. If SwiftUI hides the door, the arm hosts an
   `NSColorWell` directly (`NSViewRepresentable`).

   MEASURED 2026-09-28 (macOS 26.6.2; probes driving the panel with events
   posted into the probe's own queue, never the host's input, the host idle
   over 29 minutes each run):
   - SwiftUI's `ColorPicker` IS an `NSColorWell` (`PlatformColorWell`),
     style `.default`, AX role `AXColorWell`, opening the SHARED panel.
   - Its binding moves on EVERY drag event (a down and six drags set it seven
     times), and `NSColorPanel.shared.isContinuous = false` changes nothing.
     A hosted `NSColorWell` gets its action TWICE per drag event.
   - The panel's mouse up is invisible to a local event monitor: the wheel's
     tracking loop takes it. THE DOOR: the tracking loop runs in
     `NSEventTrackingRunLoopMode`, so a block scheduled at the panel's mouse
     down with `RunLoop.main.perform(inModes: [.default])` runs once, after
     the mouse up, holding the final colour; the arm keeps the drag's colours
     pending and commits that one.
   - `supportsAlpha` is per well and the shared panel's `showsAlpha` follows
     the active well. An opaque well HOLDS EVERY COLOUR OPAQUE: a panel
     colour at alpha 0.5 and an app write of `E01B2480` both read back with
     alpha FF. `NSColorWell`'s own default is `supportsAlpha` on.
   - An app write `well.color =` sends no action, so the mac arm needs no
     quiet guard for the echo.
   - The arm hosts `NSColorWell(style: .default)` directly, the same control,
     so the door and the read-back have a well to hold.
   - The panel's hex field is in the PANEL'S SELECTED COLOUR SPACE, not sRGB:
     `E01B24` typed into it in the RGB sliders mode committed `E9332FFF`
     (one action, since a keyboard change is no gesture). `pick_color` on the
     mac must choose the sRGB space first, or type into a field that is sRGB.
2. **The iOS commit.** Whether SwiftUI's binding exposes the continuous
   flag; if not, the arm presents `UIColorPickerViewController` itself
   behind a swatch so the delegate's noncontinuous select is the door.
3. **GTK's result.** That `choose_rgba`'s Select is the only route to a
   new `rgba` on the lane image's GTK, and whether its colour editor's
   pick button appears under the lane's portal (it should not; the leg
   does not need it).
4. **WinUI's flyout.** That `Flyout.Closed` fires for a light dismiss,
   Esc and a programmatic `Hide` alike, and reading `ColorPicker.Color`
   there is the commit. `ColorPicker` and `Flyout` join the bindgen
   filter (tools/winui-bindgen); the metadata carries both.
5. **The quantizing round trip** on all five: an app write of
   `0x336699FF` reads back `336699FF` from the control; a P3 colour
   outside sRGB comes back clamped, the same bytes on the two Apple arms.

   MEASURED on the mac 2026-09-28: `336699FF` round-trips exactly; Display P3
   (1, 0, 0) reads back through `usingColorSpace(.sRGB)` as exactly (1, 0, 0),
   AppKit clamping before the quantizer does, so `FF0000FF`. The iOS half is
   the breadth slice's. THE SWATCH'S PIXELS: the well's own cache is 8-bit in
   the DISPLAY profile, and through it 336699, E01B24, 3584E4, 26A269, 808080,
   F6D32D, 000000 and FFFFFF read back exactly while 1C71D8 reads 1E71D8, two
   off in red and outside the ruled ±1; the scene samples 3584E4 (§5).

## §5. How a leg sees it

A new shared scene, `colorpicker.steps`, one guest per language: a picker
with `color 0x336699FF`, a second with `alpha`, and a label `on_color`
writes in fixed hex.

- `expect_color color_picker#0 "336699FF"`: the control's own value, read
  back from the platform control (`expect_picker`'s shape and reason: the
  apply direction is otherwise invisible).
- `set_color color_picker#0 E01B24FF`: the label reads `color: E01B24FF`
  once, and `expect_color` agrees.
- `set_color color_picker#0 26A26980` on the opaque picker LANDS OPAQUE:
  the control reads `26A269FF` and the label `color: 26A269FF`; on the
  second picker `E01B2480` commits whole. AMENDED 2026-09-28 from "refused by
  the verb naming `alpha`": rule 3 promises an opaque picker's value is
  always FF, and AppKit's own well holds any colour opaque by either route
  (§4.1), so the verb that stands for a user's choice gets what a user gets.
  The ROOT still refuses an app write (§3 rule 3). Every backend owes the
  same answer.
- a button writes `color(0x3584E4FF)`: `expect_color` moves, the label does
  not (the echo check, with the one deliberate settle); a `set_color` of
  the colour already held emits nothing either.
- `expect_ink color_picker#0 "center = light 3584E4 dark 3584E4"`: the
  swatch is drawn in the value, sampled at its centre within the ±1 the
  mac's colour-managed window needs (docs/canvas-plan.md, the ink ruling).
  AMENDED from 1C71D8, which the display profile moves by two (§4.5).
  `expect_ink` learns a colour-picker target, whose one probe point is
  spelled `center` since the swatch's size is each platform's.
- a stamped picker per row commits with its row's key.

Verbs. New: `set_color <target> RRGGBBAA`, a user's choice through the
control's commit door WITHOUT opening the surface (`set_date`'s route:
SwiftUI's binding followed by the arm's commit, GTK's dialog-finish path
outside the quiet guard, WinUI's picker colour then the flyout's close,
Compose's sheet state then its dismissal); `expect_color <target>
"RRGGBBAA"`. Reused: `expect`, `click`, `settle`, `expect_ink`, `expect_ax`
(the shared verdict `button`, since every platform's swatch is a button;
the mac reader maps `AXColorWell` to it, measured first).

The panels themselves. `set_color` never opens a surface, so the scene runs
in the everyday pool on every lane. A second scene, `colorpanel.steps`,
opens the real surface and types a hex value into it (`pick_color <target>
RRGGBB`, `pick_emoji`'s precedent): GTK's dialog custom editor, WinUI's
flyout hex box, Android's sheet, iOS's picker through the XCUITest driver.
On the mac the shared `NSColorPanel` opens on the host's screen, where a
person at the keyboard would see it and could type into it, so that leg
joins the mac lane's `HOST_UI_SCENES` (EXCLUSIVE, with the idle-host wait)
and is driven through accessibility like the emoji palette; the lanes that
cannot reach a panel's hex field say so in their lane table.

## §6. The lowerings

| backend | swatch | surface | commit door | alpha |
|---|---|---|---|---|
| SwiftUI macOS | `ColorPicker` (or a hosted `NSColorWell`, §4.1) | `NSColorPanel`, shared | the gesture's end in the panel | `supportsOpacity` |
| SwiftUI iOS | `ColorPicker` (or a swatch presenting the controller, §4.2) | `UIColorPickerViewController` | the noncontinuous select | `supportsAlpha` |
| GTK | `GtkColorDialogButton` | `GtkColorDialog` | `choose_rgba` finishing with a colour | `with-alpha` |
| WinUI | a `Button` faced with a swatch | a `Flyout` holding `ColorPicker`, hex input shown, `IsMoreButtonVisible` false so the channel boxes show without a toggle | `Flyout.Closed` | `IsAlphaEnabled` |
| Compose | a Material `FilledTonalButton` faced with a swatch | a `ModalBottomSheet` (the emoji picker's Material sheet, docs/emoji-picker-plan.md) holding the synthesized picker | the sheet's dismissal or its Done | an opacity slider row |

**The synthesized picker on Android**, the minimum that reaches every
colour and reads as a Material component: a grid of preset swatches (one
fixed palette in the core, so the grid is the same everywhere it is
drawn), three Material `Slider`s for hue, saturation and brightness with
a preview swatch, a hex `TextField` (RRGGBB, or RRGGBBAA with alpha)
through the IME's own keyboard, and an opacity slider when `alpha` is on.
No custom drawing beyond the swatches and the sliders' track gradients.
Rule 2 on this sheet: moving the sliders previews inside the sheet and
commits nothing until the sheet closes, as on WinUI. §8 ruling 2 asks
whether to take a community library instead.

## §7. Bindings and guards

Bindings: `color_picker(color)` with `alpha` and `on_color` in all nine
and both zones, spelled as each spells the date picker; the `Color` type
per binding (§2) with its hex constructor and a `hex()` reading; the C
floor packs the I64. A do/can't/defer verdict per language at the sweep;
no carve-out is expected.

Guards:
- Core unit tests: the quantizing function (clamp, round, the exact 8-bit
  round trip), the root's refusal of a non-FF alpha on an opaque picker,
  the packing, each watched failing on a cut.
- The scene's echo, alpha-refusal and commit lines, each watched red with
  the arm's own line removed.
- check-sugar-surface: the kind in both zones, `alpha`, `on_color` and the
  `Color` type in nine, with fake-name negatives.
- check-verbs: `set_color`, `expect_color`, `pick_color` and the kind's
  constant in both interpreters.
- A static clause, check-slider-commit's shape: every `color_changed`
  emit sits inside its backend's commit door (§6), because `set_color`
  is one finished choice by construction and a backend that emitted on
  every drag would pass the scene byte for byte.
- check-exclusive: the mac panel leg is in `HOST_UI_SCENES`.

## §8. The two rulings

1. **Should the app hear the colour while the user drags?** A live
   occurrence (the slider's `value_changed` twin) would let the editor
   recolour a title in the program monitor as the user drags in the
   panel. GTK cannot give it: its only colour dialog reports once, on
   Select, and the live control it had (`GtkColorChooserWidget`) is
   deprecated. So a live occurrence would fire on four platforms and
   never on the fifth, which is a different app on Linux. RECOMMEND no
   live occurrence: the committed value only, as the date pickers do. On
   Apple each gesture's end already commits, so a mac or iPhone user who
   drags and lets go sees the title move per gesture; GTK, WinUI and
   Android show it when the surface closes.
2. **Android: build the picker, or take a library?** No first-party one
   exists. Community ones do (skydoves' colorpicker-compose, which the
   parity survey cites), each with its own look and a dependency to pin.
   RECOMMEND building §6's minimal picker in KayaCompose.kt out of
   Material's own `Slider`, `TextField` and `ModalBottomSheet`: it is
   small, it stays in Material's idiom, and it adds nothing to pin.
