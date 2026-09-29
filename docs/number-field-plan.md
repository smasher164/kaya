# The number field: the design pass

Status: DESIGNED 2026-09-28; BUILT on all five platforms and in all nine
bindings the same day (§9: the depth slice on the mac, then the breadth). The roadmap's third piece for the
video editor (its inspector: a clip's speed, volume in dB, a crop inset, a
frame count) and a table stake the needs survey ranks with the stepper
(docs/probes/roadmap-app-needs-2026-09-05.md, "number/formatted field" and
"stepper": quantity and timecode entry). Every choice in §1 to §7 is
RECOMMENDED and needs no ruling; §8's two are RULED (2026-09-28).

The roadmap names Apple's "digit entry view"; that is a tvOS-only PIN pad
(`TVDigitEntryViewController`, "Not supported in iOS, iPadOS, macOS"), so the
Apple controls here are a formatted text field and the stepper.

## §1. What the platforms have

Read from the vendors' documentation on 2026-09-28; §4 lists what is measured
before an arm relies on it.

| | the control | commits | text that does not parse | stepping | locale |
|---|---|---|---|---|---|
| macOS | SwiftUI `TextField(value:format:)` (AppKit: `NSTextField` with an `NSNumberFormatter`); `Stepper(value:in:step:)` beside it | Apple's page says editing updates the binding while the text parses, and that is what §4.1 measured (practice reports of Return or focus loss only do not hold on this OS) | "If the user stops editing the text in an invalid state, the text field updates the field's text to the last known valid value" | the HIG: "a stepper sits next to a field that displays its current value", with Shift-click for ten steps on the mac | the format style's locale |
| iOS | the same `TextField`, `keyboardType` `.numberPad` ("for PIN entry") or `.decimalPad` ("numbers and a decimal point") | as macOS | as macOS | `Stepper` exists; forms rarely pair it with a field | as macOS |
| GTK 4 | `GtkSpinButton`: a `GtkAdjustment` (value, lower, upper, step and page increments), `digits`, `climb-rate`, `numeric`, `update-policy` (`ALWAYS` or `IF_VALID`), `snap-to-ticks`, `wrap` | the value is read from the text on focus-out, on `activate` and on `gtk_spin_button_update()`; `value-changed` fires then, and for every button step | an `input` handler answering `GTK_INPUT_ERROR` leaves the value; `IF_VALID` displays "only if it is valid within the bounds" | `+`/`-` buttons always drawn; arrows, PageUp/PageDown | the `input`/`output` signals replace the parse and the display |
| WinUI 3 | `NumberBox`: `Value` (double), `Minimum`, `Maximum`, `SmallChange`, `LargeChange`, `SpinButtonPlacementMode` (`Hidden`, `Compact`, `Inline`), `ValidationMode`, `NumberFormatter`, `AcceptsExpression` | "evaluation is triggered on loss of focus or a press of the Enter key"; `ValueChanged` then | `InvalidInputOverwritten` puts back "the last valid value"; a cleared box sets `Value` to NaN | `SmallChange` on arrows and the wheel, `LargeChange` on PageUp/PageDown; buttons only when placement is not `Hidden` | `NumberFormatter` is an `INumberFormatter2` and `INumberParser` (a `DecimalFormatter`) |
| Compose | none. A `TextField` with `KeyboardOptions(keyboardType = KeyboardType.Number \| Decimal)` and an `InputTransformation`; Material 3 has no stepper | whatever the app does (`KeyboardActions`, focus) | whatever the app does | none | none |

Sources: Apple's `TextField(_:value:format:prompt:)`, `Stepper` and
`UIKeyboardType` pages and the HIG's steppers and digit entry views pages;
https://docs.gtk.org/gtk4/class.SpinButton.html; the NumberBox class and
https://learn.microsoft.com/en-us/windows/apps/design/controls/number-box;
https://developer.android.com/develop/ui/compose/text/user-input.

Where they agree: the value is a double; a range and an increment; the value
settles on Return or focus loss, never per keystroke; unreadable text goes
back to the last good value. Where they differ is chrome (stepper buttons)
and who parses, and §3 rule 5 takes the parse into kaya.

## §2. The surface

A new widget kind, `number_field` (kind 20), in both construction zones. It
reuses the slider's props, with one semantics each:

- `value` (3, F64): the committed value. `min` (4) and `max` (5): the
  bounds, never set meaning ±2^53, the range where every integer is exact.
  `step` (24): the increment an arrow key or a stepper button moves by, 1
  when never set; 0 or a negative step is refused at the root, since a field
  has no continuous mode.
- The root refuses `value` outside `min..max` (and `min` above `max`),
  read on the complete declaration at the end of the transaction. The
  slider did not do this until the breadth slice, whatever
  docs/slider-plan.md said; it does now, the same shape (scene.rs's
  `SliderRange::check`, `a_sliders_value_outside_its_range_is_refused`).
- `placeholder` (30) is legal, as on the three text kinds.

**One occurrence, `value_committed` (26), spelled `on_commit` as on the
slider.** It fires once per commit: Return, focus loss, one arrow key, one
stepper click (a held button's repeats are one commit each, as GTK and
WinUI report them). `value_changed` never fires on a number field and
`text_changed` never does either: the text between commits is not a value.
An app write never echoes; a commit whose value equals the old value does
not fire.

**The value type is F64**, as on the slider; an integer field is `step(1)`
and shows no fraction digits (§3). Out of this pass: `AcceptsExpression`
(WinUI alone has it), `wrap`, percent and currency display (the app labels a
unit beside the field), and an empty state (§8, ruling 2).

## §3. The rules

1. **Commit.** Return (or the phone keyboard's Done) and focus loss read the
   text, and the value moves; nothing is read on a keystroke.
2. **Unreadable text reverts** to the last committed value's text, and
   nothing fires (the `IF_VALID` and `InvalidInputOverwritten` behaviour).
   Empty text is unreadable text.
3. **Out of range clamps** to `min` or `max` and commits the clamped value;
   GTK and WinUI clamp natively, the other arms clamp in their commit path.
4. **Display digits come from the step**, the slider's S7 rule of deriving
   from the step: as many fraction digits as the step has (`1` shows `12`,
   `0.25` shows `12.50`, `0.1` shows `12.5`), capped at six. The committed
   value is rounded to those digits, so the text and the value agree; GTK's
   spin button already does this with `digits`.
5. **kaya formats and parses, through the formatter door.** The field's text
   is `fmt::number(value)` with the fraction digits of rule 4 and grouping
   off (no platform groups inside an editable number: GTK prints none and
   `DecimalFormatter` defaults to ungrouped), so `3.5` reads `3,5` under
   de-DE and `٣٫٥` under ar-EG. The door gains ONE call, `fmt::parse_number`,
   over the same platform formatter on each arm (`CFNumberFormatter`,
   Android ICU's `NumberFormat.parse` in KayaFormat.kt, glibc `strtod` under
   `LC_NUMERIC`, `DecimalFormatter.ParseDouble`). One reader of the text on
   five backends is what makes rule 2 one rule, and what lets a scene freeze
   the displayed text with `{fmt:number …}`.
6. **Stepping** moves by `step` from the committed value, clamped, and
   commits. The page keys move by ten steps (the slider's S7 page rule,
   and the mac HIG's Shift-click ten).
7. **Steppers are drawn where the platform draws them**: GTK always (the
   spin button has no other form), WinUI `Inline` (the desktop sibling of
   GTK's; `Compact` hides them until focus). Apple and Compose draw none:
   Apple's field has no built-in stepper and the HIG pairs one only where
   large and small changes both happen, and Material has none. This is
   dress in DESIGN.md's sense; the semantics (rule 6) are the same
   everywhere the user can reach a step.

## §4. What is measured first

1. **SwiftUI's commit.** Whether `TextField(value:format:)` moves its binding
   per keystroke (Apple's text) or on Return and focus loss (the reports).
   The arm binds a String and commits itself, so neither answer moves it.
   MEASURED 2026-09-28 on the mac (Darwin 25.6; a probe with keys through
   `NSApp.sendEvent`, the harness's route): PER KEYSTROKE while the text
   parses (typing `12` after `5` set 51, then 512); unparsable text leaves
   the binding at the last parsable value and the text goes back to it on
   Return or focus loss; an emptied field reverts on Return and `onSubmit`
   still fires. Tab moves `FocusState` to the next text field and wraps, and
   WITH ONE TEXT FIELD IN THE WINDOW Tab keeps the focus on it (buttons are
   not in the key loop), so `unfocus` needs a second field for the focus to
   leave to and the scene carries one. `onKeyPress(.upArrow/.downArrow)` on
   a focused `TextField(text:)` sees the arrows before the field editor, so
   the mac's stepping door is the arrow key.
2. **The phones' keyboards.** iOS `.decimalPad` has no minus and no Return
   key, so the arm picks `.numberPad` for integral steps with `min >= 0`,
   `.decimalPad` for fractional ones, and `.numbersAndPunctuation` when
   `min < 0`, and puts a Done button on the keyboard's toolbar as the commit
   (dress). Measure the Done route and the harness driver reaching it.
   MEASURED 2026-09-28 on the iOS lane's simulators (the kaya-sim pool,
   the XCUITest driver): the toolbar's Done is a real `UIToolbar` button
   (`app.toolbars.buttons["Done"]`), and its tap drops the FocusState,
   whose focus-loss commit reverts `12.5abc` to `12.5` (with the tap
   withheld the field keeps `12.5abc`, watched red). The harness's
   `press return` is the driver's Return (XCUITest `typeText("\n")`, a
   hardware keyboard's key, real on an iPad's): on a `.decimalPad` or
   `.numberPad` field it commits ONCE and ENDS EDITING, the submit
   scene's finding (docs/submit-plan.md S3): `onSubmit` and the resign's
   focus-loss commit both reach the commit path, and whichever runs second
   finds the value unmoved and fires nothing (which one ran first was not
   told apart). So the scene
   clicks the field again before typing into it. The driver types letters
   into a `.decimalPad` field, since XCTest synthesizes the events rather
   than tapping the keys drawn.
   Android: whether `KeyboardType.Decimal` shows a minus on the lane's IME.
   MEASURED 2026-09-28 on the android lane's emulator (API 35, Gboard,
   `show_ime_with_hard_keyboard` 1): `KeyboardType.Number` (inputType 0x2)
   and `KeyboardType.Decimal` (0x2002) draw the SAME pad, digits with a
   minus, a space, a comma, a point and Done, so either carries a minus
   here. The Compose arm keeps the iOS rule's shape (Number for an
   integral step with `min >= 0`, Decimal otherwise, since Decimal is the
   type that promises a separator and carries the minus on this IME), and
   `ImeAction.Done` shows the check key, whose tap commits and keeps the
   focus (the keyboard hides).
3. **GTK's display.** That the `output` and `input` handlers through the
   door hold under ar-EG's Arabic-Indic digits, which glibc's printf, the
   spin button's own output, would not write.
   MEASURED 2026-09-29 in the lane's image (Debian trixie glibc): ar_EG's
   LC_NUMERIC is a full stop and a comma, so the glibc arm writes `3.5`,
   ASCII, and reads it back (fmt's glibc test holds both); no backend on
   this lane writes Arabic-Indic digits, and text typed in them is refused
   and reverts. AMENDED 2026-09-29 (§6): the `input` handler does NOT
   answer `GTK_INPUT_ERROR`. Under `ALWAYS`, `gtk_spin_button_update`
   leaves its value uninitialized on that answer and then sets it (GTK
   4.20's gtkspinbutton.c), so the handler answers the committed value for
   text the door refuses, which GTK turns into a redisplay and no
   `value-changed`. `IF_VALID` would revert out-of-range text instead of
   clamping it (rule 3). The stepper buttons and the arrow keys run
   `gtk_spin_button_update` before they step, so typed text commits first.
4. **WinUI's formatter.** That a `DecimalFormatter` built with the door's
   own language list parses the user's separator, and whether a NumberBox
   left `Value` NaN by a clear can be put back before `ValueChanged` fires.
   MEASURED 2026-09-28 on the windows lane's VM: the door's language list
   parses the user's separator (de-DE `12,5`, en-US `12.5`, ar-EG `٣٫٥`,
   each refusing the other's), BUT `ParseDouble` reads a grouping separator
   whatever `IsGrouped` says (`1,234.5` under en-US), so the arm admits only
   digits and the characters the same formatter writes for an ungrouped
   `-1.5`. A cleared box raises `ValueChanged(old, NaN)` and cannot be put
   back before it; a value written INSIDE the handler is taken (NumberBox
   ignores the nested change and renders its text from that value), so the
   revert happens there and nothing fires. The NumberBox's `NumberFormatter`
   is kaya's own object over `number_field::text` and `fmt::parse_number`,
   so the box's parse IS the door; its Inline up button is disabled at the
   maximum, and its peer publishes `Spinner` (class
   `Microsoft.UI.Xaml.Controls.NumberBox`), which the `ax` read maps to
   `field`.
5. **Focus loss on each lane**: which user act moves focus off a field
   (§5's `unfocus`) and that the commit rides it on all five.
   MEASURED 2026-09-28, Compose: Tab through the activity's own key path
   (`dispatchKeyEvent`, a hardware keyboard's key) moves the focus to the
   next field, the scene's entry, and the focus-loss commit rides it; the
   check key's tap hid the keyboard and left the caret in the field, so a
   keyboard's dismissal is not a focus loss on Android and not the door.
   MEASURED 2026-09-28, iOS: the phone user's dismissal is the keyboard
   toolbar's Done, and `unfocus` taps it through the lane's driver
   (`keyboard_done`); the focus-loss commit rides it. The iOS field has no
   stepping door, so the phones' lane tables cut the scene at `nudge`,
   which the scene puts last for that reason.
   MEASURED 2026-09-29, GTK: Tab (`wtype`, `xdotool`) moves the focus to
   the entry and the commit rides it. AMENDED: focus loss means a focus
   move INSIDE the window. GTK's own focus-out door also fires when the
   window loses the keyboard (GTK_CROSSING_ACTIVE, gtkwindow.c), and on
   the wayland slots every `wtype` run's virtual keyboard arriving and
   leaving does that: the field committed `12.5` mid-type and clamped a
   typed `250` to `100` before Return (the numberfield-rust-wayland leg,
   red, 2026-09-29). The arm replaces GTK's controller with one that
   commits on the next turn only if the window's focus sits elsewhere; an
   app switch commits nothing, as on the other backends.
   check-submit holds both halves.

## §5. How a leg sees it

A new shared scene, `numberfield.steps`, one guest per language, a field with
`min 0`, `max 100`, `step 0.5`, and a label its `on_commit` writes:

- type `12.5`, `press return`: `expect_value number_field#0 "12.5"`,
  `expect number_field#0 "{fmt:field 12.5 0.5}"`, the label moved once, and
  not before the Return.
- type `abc`, `unfocus`: the text reverts, the label did not move.
- type `250`, `press return`: clamps to `100`.
- `nudge number_field#0 up`: `100` stays (clamped, no commit), then `down`
  reads `99.5`.
- a button writes `value(40)`: the field reads `{fmt:field 40 0.5}`, the
  label did not move (the echo check).
- a stamped field per row commits with its row's key (the template zone).

AS BUILT (2026-09-28): `type` APPENDS (the typing contract's point 3), so
the scene empties the field with `set_text number_field@amount ""` before
typing a new number; `set_text` on a number field writes its text and
emits nothing, since the text is not a value until it commits. `type`
expands `{fmt:…}`, so the German leg types `12,5`. The field and the
button are addressed by `a11y_id` (`number_field@amount`), and an entry
beside them is where Tab moves the focus (§4.1).

A `numberfieldde` leg runs the same guest under de-DE, which is where a
separator a backend reads for itself goes red.

Verbs. `type`, `press return` and `expect` (which reads an entry's text
through `read_text` today and takes `number_field` targets) already exist;
`{fmt:…}` gains a `field` kind, the value and the step, spelled as rule 5
spells it (grouping off, the step's digits). New: `expect_value <target> "<n>"`, the control's committed value in
`expect_slider`'s fixed spelling, with `expect_slider` renamed to it in the
same slice since it reads the same kind of thing; `unfocus <target>`, moving
focus off the field the way the platform's user does (Tab on the desktops,
the keyboard's dismissal on the phones); `step <target> up|down`, driving the
platform's stepping door (a stepper button on GTK and WinUI, the arrow key
on macOS, which §4.1 found the field takes). A lane with no stepping door
drops the `nudge` lines through its lane table, as the phones drop
`user_fullscreen`. AMENDED 2026-09-28: the verb is `nudge <target>
up|down`, not `step`, so it cannot be read as a scene step or as the `step`
prop; `unfocus` and `nudge` both refuse a field that does not hold focus
(the scene clicks it first), and on the mac both are real key events (Tab,
the arrow) through the platform's key path.

## §6. The lowerings

| backend | control | commit | parse and display | steppers |
|---|---|---|---|---|
| SwiftUI (macOS, iOS) | `TextField(text:)` on a String, the keyboard of §4.2 on iOS | `onSubmit`, the focus state going false, the keyboard toolbar's Done | the door both ways | none |
| GTK | `GtkSpinButton` over an adjustment of `min`, `max`, `step`, ten steps | `value-changed` outside the quiet guard | `input`/`output` handlers through the door, `input` answering `GTK_INPUT_ERROR` for text the door refuses; `update-policy` `ALWAYS`, so the adjustment clamps | drawn |
| WinUI | `NumberBox`, `ValidationMode` `InvalidInputOverwritten`, `SmallChange` step, `LargeChange` ten steps | `ValueChanged` outside the quiet guard | `NumberFormatter` a `DecimalFormatter` matching the door | `Inline` |
| Compose | `TextField` with `KeyboardType.Number` or `Decimal`, `ImeAction.Done` | `KeyboardActions.onDone`, `onFocusChanged` losing focus | the door both ways over JNI | none |

Accessibility: the shared verdict is `field`, the search field's precedent
(docs/search-plan.md S7); each backend keeps its own identity (GTK's
`SPIN_BUTTON`, the NumberBox's automation peer, AXTextField).

## §7. Bindings and guards

Bindings: `number_field(value)` with `min`, `max`, `step` and `on_commit`
in all nine and both zones, spelled as each spells the slider
(docs/slider-plan.md §0); the C floor packs the props. A do/can't/defer
verdict per language at the sweep; no carve-out is expected.

Guards:
- Core unit tests: the root refuses `step <= 0` and an out-of-range
  `value`; the digits rule and the rounding, frozen.
- `fmt::tests` for `parse_number` per arm: a refused string, and the
  round trip `number(parse(number(v))) == number(v)`.
- The scene's echo, revert and clamp lines, each watched red with the
  arm's own line removed.
- check-sugar-surface: the kind in both zones and `on_commit` in nine.
- check-verbs: `expect_value`, `unfocus`, `step` and the kind's constant in
  both interpreters.
- A static clause, check-submit's shape: every `value_committed` emit in a
  number-field arm sits inside a commit door (Return, focus loss, a step);
  a per-keystroke emit passes every scene line that ends in a commit.

## §8. The two rulings

1. **Where timecode lives.** A timecode (`01:02:03:12`, hours, minutes,
   seconds and frames at the project's rate) is not a locale number: no
   platform's number formatter reads or writes it, and a stepper step of
   "one frame" depends on the frame rate. Two homes: a `format` option on
   the number field (kaya formats and parses `HH:MM:SS:FF` itself, the value
   in frames or seconds), or the app's own entry, where the editor parses on
   `submitted` and shows the playhead in a label. RECOMMEND the app's own
   entry for now: the number field ships as a locale number with nothing
   the platforms disagree on, and a timecode format joins it as its own
   slice if the editor shows the entry is not enough (the entry has no
   focus-loss commit, which is the likely gap).
   RULED 2026-09-28 (the maintainer): the `format` option, built at
   video-editor time and not in this slice. The field gains a `format` prop
   that names one of the FORMATTER DOOR's formatters
   (docs/compliance-plan.md §1.4) rather than a vocabulary of its own:
   `number` by default; `percent` and `currency` later, since the door
   already formats them and needs only its parse half; and `timecode(rate)`
   joining the door as a formatter of its own (the value in whole frames,
   the step one frame, kaya formatting and parsing `HH:MM:SS:FF`), so the
   editor's playhead label and its timecode field share one formatter.
   Timecode is one case of a general "custom display and step" need; the
   general version, an app-supplied format and parse callback, is out,
   because it would put guest code on the UI thread's synchronous path,
   which kaya's wire never does. A closed set in the door, grown one
   formatter at a time, is the shape.
2. **Can the field be empty?** NumberBox reports a cleared box as NaN;
   the others leave it to the app. RECOMMEND no empty state: empty text
   reverts like any unreadable text, so `value` is always a number and no
   binding needs an optional; a later `optional` prop can add one.
   RULED 2026-09-28 as recommended: no empty state. A "may be blank" state
   for form fields in general is on the ledger (docs/deferred.md, 'A "may
   be blank" state for form fields').

## §9. As built, the depth slice (2026-09-28)

The rules live once, in crates/kaya/src/number_field.rs (the root's range
check, the digits from the step capped at six, the rounding, the text
through `fmt::number` at those digits with grouping off, a commit's
reading of the text and a step), and `fmt::parse_number` reads the WHOLE
text as one number in the process locale or refuses it. It is not guest
surface: the arms are its callers. The Apple arm is CoreFoundation's
parse over the full range with grouping off; the glibc arm is written
(the separator `localeconv` names, ASCII digits, an optional minus); the
Windows and Android arms refused by name until the breadth slice wrote
them (§4.4 for Windows; ICU's `NumberFormat.parse` in KayaFormat.kt for
Android).
The SwiftUI arm reaches the rules through three vtable slots
(`number_text`, `number_commit`, `number_step`), so its commit and its
text are the core's and not a Swift copy. The harness asks the platform
independently for `{fmt:field …}` (Foundation's `NumberFormatter` here),
which is what lets the German leg catch a separator either side wrote
for itself. `expect_slider` is renamed `expect_value` in all three
harnesses.
Both §8 recommendations are what is built: no timecode format on the
kind, and empty text reverts like any other unreadable text
(`a_commit_reads_the_text_through_the_door`), so `value` is always a
number.
