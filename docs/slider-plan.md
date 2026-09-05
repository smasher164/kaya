# Sliders — the survey (2026-09-04)

The maintainer's 2026-09-02 order names "sliders" after drag and drop and
the pickers, with the scope "whatever we don't already have". This is
the survey that scope asks for: what kaya's slider carries today, what
each platform's own slider can do, and the gaps as rulings. Nothing here
is built; §2 is the list to rule on. The pickers pass
(docs/datetime-plan.md) is the precedent for the shape of the answers.

## §0 — What kaya has

**The kind.** `slider` (kind 7) is one of the original roster controls
(DESIGN.md's v1 roster: "Slider and Entry cover state slots and
uncontrolled state"). It carries three props, all F64: `value` (3),
`min` (4), `max` (5). Nothing else: no step, no orientation, no labels,
no ticks, no second thumb.

**The occurrence.** `value_changed` fires on EVERY user movement with the
new position — continuous, never "committed" — and a property write never
echoes (spec.rs's doc on the record: "One occurrence per USER change …
without that, a handler writing back a different value would ping-pong
forever"). The widget owns its value; the app updates its model by
writing back or by binding a signal. The pickers borrowed this stance
(datetime-plan D7) and then added the part sliders lack: the committed
value.

**The sugar, all nine bindings, both zones.** `slider(min, max, value)`
and a signal-bound twin (`slider_bound` in Rust, `SliderBound` in Go,
`?bind` in OCaml, `sliderBoundOn` in Haskell, an overload in C#/Java/
Swift, `value=Signal` in Python, `SliderOptions` in JS); the template
zone takes a row source for the position and a constant range. The C
floor packs the three props by hand. Every spelling agrees that the range
is constant and the position varies.

**The harness.** `set_value slider#0 0.75` is the driving verb and there
is NO read-back verb: `expect` refuses slider targets by name
(datetime-plan.md §"What the slider's contract is"), so every scene reads
the slider through the label the guest's handler writes (the gallery's
`volume: 75%`). The pickers got `expect_picker`, which reads the
CONTROL; the slider never did.

**The arms, read 2026-09-04.**

| Backend | Control | Emits | `set_value` route | Notes |
|---|---|---|---|---|
| SwiftUI (mac, iOS) | `Slider(value:in:)`, a binding that mirrors the node and emits on set | every move | writes the node and emits BY HAND, not through the control | a 200pt stand-in width, lifted for growers (DESIGN.md) |
| Compose | `Slider(value, onValueChange, valueRange)` | every move | writes the node and emits by hand | `steps` unused |
| GTK | `Scale::with_range(Horizontal, 0, 1, 0.01)`, adjustment lower/upper rewritten by min/max | every `value-changed` outside the quiet guard | `scale.set_value` — THROUGH the control | 0.01 is the KEYBOARD increment only; a drag is continuous |
| WinUI | `Slider` with `StepFrequency(0.01)`, Minimum/Maximum rewritten by min/max | every `ValueChanged` outside the quiet guard | `SetValue` — through the control | 0.01 QUANTIZES the drag: WinUI snaps the thumb to StepFrequency, so a Windows drag lands on hundredths of the 0..1 default and stays 0.01 when min/max move — the one platform whose slider is discrete today, invisibly, since 0.75 lands on a hundredth everywhere |

Two divergences already stand: the set_value route (two backends drive
the control, two bypass it — datetime-plan D8's question, answered
"through the control" for pickers), and WinUI's silent quantization.

**What the core polices.** A `value` outside `min..max` is refused at
apply by name (datetime-plan.md D3's text names it as the precedent for
refusing the 31st of February).

## §1 — What the platforms have

Read from the vendors' own documentation on 2026-09-04 (SwiftUI's,
UISlider's and NSSlider's pages, Compose's slider guide and material3
release notes, the WinUI Slider class and design page, the Community
Toolkit RangeSelector page, GtkScale's reference, the GNOME HIG).

| Capability | SwiftUI `Slider` (mac + iOS) | AppKit `NSSlider` | UIKit `UISlider` | Compose material3 1.3.2 | WinUI 3 `Slider` | GTK 4 `GtkScale` |
|---|---|---|---|---|---|---|
| min/max | `in:` range | `minValue`/`maxValue` | `minimumValue`/`maximumValue` | `valueRange` | `Minimum`/`Maximum` | adjustment lower/upper |
| step (discrete) | `step:` | `numberOfTickMarks` + `allowsTickMarkValuesOnly` | **none** (apps round) | `steps` = count of INTERIOR stops (range must divide evenly) | `StepFrequency` + `SnapsTo.StepValues` | **none for drags**; `set_increments(step, page)` is keyboard only |
| committed ("drag finished") | `onEditingChanged(false)` | `isContinuous = false` | `isContinuous = false` | `onValueChangeFinished` | **none** — `ValueChanged` only; `IntermediateValue` is the pre-snap live value; pointer release on the control is the hook | **none** — `value-changed` only; pointer release is the hook |
| two thumbs (range) | **none** | **none** | **none** | `RangeSlider(value: ClosedFloatingPointRange)` | **none** in WinUI; Community Toolkit `RangeSelector` (Minimum/Maximum/RangeStart/RangeEnd/StepFrequency/Orientation, `CommunityToolkit.WinUI.Controls`) | **none** |
| vertical | **none** | `isVertical` | **none** | **none** through the versions read | `Orientation` | `GtkOrientable` |
| tick marks | drawn on macOS when `step:` is set | `numberOfTickMarks`, `tickMarkPosition` | none | drawn from `steps` | `TickFrequency`, `TickPlacement`, `SnapsTo.Ticks` | `add_mark(value, pos, markup)` — ticks WITH LABELS |
| value shown | none (guest labels) | none | none | value indicator on drag (M3) | `IsThumbToolTipEnabled` (default on) + `ThumbToolTipValueConverter`, `Header` | `draw-value`, `value-pos`, `set_format_value_func` |
| end labels | `minimumValueLabel:`/`maximumValueLabel:` | none | `minimumValueImage`/`maximumValueImage` | none | none (design page: label both ends) | none (marks serve) |
| keyboard | arrows on a focused mac slider | arrows (Left/Down −, Right/Up +) | none | not verified here; the `setProgress` semantics action is the certain route | `SmallChange`/`LargeChange` (arrows, PageUp/Down) | arrows/+/− by step, PgUp/PgDn by page, Home/End |
| direction | none | none | none | none | `IsDirectionReversed` | `inverted`, `has-origin` (fill from an origin) |
| a11y role today | AXSlider / `.adjustable` | AXSlider | `.adjustable` | `SeekBar` class | RangeValue pattern | `slider` — all five read back as `slider` already (tools/scenes/a11y.steps) |

What the guidelines say, in one line each. Apple: a slider is for a
range where relative adjustment matters; supplement with a text field or
stepper when an exact value matters; macOS alone has tick marks and a
circular variant. Material 3: continuous, discrete (stop indicators),
range and (2025's spec) centered and vertical variants; a value indicator
while dragging. Fluent: use steps when arbitrary values are wrong, show
ticks when the snap points are not obvious, label both ends, value label
below, thumb tooltip for the exact value. GNOME: mark significant values
along the track; pair with a spin button when precision is needed.

## §2 — The gaps, as rulings

**RULED 2026-09-04** by the maintainer, after the survey: the recommended
set stands (S1 yes, S2 yes as a second occurrence, S3 defer, S4 defer, S6 no
props, S7 derived from the step, S8 yes, S9 fixed with S1, S10 refuse), with
S5 amended to `tick_spacing` (below). His three questions and their
answers are recorded under S2, S5 and S10.

Each says what the platforms do, what kaya would add, and a
recommendation. Every one is a binding-surface change: nine bindings, two
zones, an explicit do/can't/defer per language (invariant 2), and the
census clause in tools/check-sugar-surface.py that holds a surface level
across them.

### S1 — A `step` prop (RECOMMEND: yes)

A discrete slider is the thing every guideline names first, and it is
what a frame-stepped playhead, a ticket count or a zoom with fixed stops
need. Add `step` (F64, 0 = continuous, the default) beside `min`/`max`.
The platforms: SwiftUI `step:` (mac and iOS); Compose `steps` derived as
`(max − min) / step − 1`, with the core REFUSING a range the step does not
divide evenly (the minute-step precedent, ruled as a fixed set there; a
free step needs the divisibility check instead); WinUI `StepFrequency`
with `SnapsTo.StepValues`; GTK has no drag quantization, so the arm snaps
in its commit path exactly as Compose's picker arm snaps the dial — the
declared step is the contract and the platform's absence is emulated, D3's
rule. Keyboard increments ride the step where a platform has them (S7).
Ticks come free where the platform draws them for a step (mac SwiftUI,
Compose, WinUI) and are not a separate prop (S5).

### S2 — The committed value (RECOMMEND: a second occurrence, both available)

Today every movement emits and nothing says "done". A scrub wants both:
the live value to move a preview, the committed one to write the model
and the undo stack. Three shapes: (a) keep continuous only; (b) add a
`value_committed` occurrence beside `value_changed`, the guest listening
to either or both; (c) a per-slider mode switching which one fires.
Recommend (b): (a) leaves the model written on every pixel of a drag, and
(c) makes the same slider mean two things in two apps. The platforms:
SwiftUI `onEditingChanged(false)`, Compose `onValueChangeFinished`,
UIKit/AppKit `isContinuous` (not needed — SwiftUI's hook serves both
Apple platforms); WinUI and GTK have NO finished event, so the arm
watches the pointer's release on the control (WinUI `PointerCaptureLost`
on the slider, GTK a `GestureClick` `released` on the scale) and a
keyboard change commits at once. A `set_value` step in a scene commits
(the driven move is one gesture); a new verb is not needed. The sugar
spelling: `on_commit` beside `on_change` in every binding's own idiom.

AMENDED 2026-09-04 when the GTK arm was built: a `GestureClick` on a
`GtkScale` never sees `released` at all — GtkRange's own drag gesture
claims the sequence and the click gesture gets `end` on the first motion
— so that arm reads the release off a capture-phase
`GtkEventControllerLegacy`, the only controller the raw button events
reach (measured, docs/traps.md).

### S3 — Two thumbs, a range slider (RECOMMEND: defer, record the shape)

Only Compose ships one. WinUI reaches one through the Community Toolkit
(`RangeSelector`, a package plus bindgen rows). Apple and GTK have none:
a range slider there is a composed control — two thumbs on one track
with hit-testing, keyboard focus per thumb and an accessibility node per
thumb — or two linked single sliders. The forcing app does not need it:
a clip's in and out points are trimmed ON the clip in the canvas
timeline (a drag on the canvas, which the drag-and-drop milestone and the
canvas already carry), not with a separate range control. Defer; if an
app arrives whose form has a "between X and Y" filter, the composed
control is the design and this row is where it starts.

### S4 — Vertical (RECOMMEND: defer)

Native on GTK, WinUI and AppKit; absent from SwiftUI's `Slider`, UISlider
and Compose at 1.3.2 (each is a rotation hack there, which breaks the
accessibility geometry and the hit box). A video editor's mixer would
want vertical faders; the timeline editor ruled as the first artifact
does not. Defer; when it comes, the Apple arm hosts `NSSlider.isVertical`
on the mac and the two phones stay horizontal by carve-out, stated
uniformly.

### S5 — Ticks (RULED 2026-09-04: `tick_spacing`, a second number)

The maintainer asked whether ticks should be explicit rather than follow
the step ("the playhead shouldn't have ticks"), how other frameworks handle
it, and whether one number could express everything. The field splits three
ways: ONE KNOB where ticks follow steps (Compose's `steps`, Flutter's
`divisions`, SwiftUI on the Mac) — an integer slider from 8 to 72 gets 65
ticks; TWO INDEPENDENT KNOBS (WinUI `StepFrequency` + `TickFrequency` with
`SnapsTo`, Qt `singleStep` + `tickInterval`, AppKit `numberOfTickMarks` +
`allowsTickMarkValuesOnly`, HTML's `step` + a datalist, GTK's per-call
`add_mark`); and AUTOMATIC WITH A DENSITY LIMIT (Material Components for
Android's tick visibility mode: hidden, hide-all-when-crowded, or draw as
many as fit). No single number covers the cases, because which values the
thumb rests on and which positions are drawn are independent: ticks-follow-
steps fails the integer slider, steps-follow-ticks fails it the other way,
and a step with a count threshold fails the balance slider (continuous, one
centre mark) and adds a number nobody chose. RULED: `tick_spacing`, in value
units, 0 = none, independent of `step`; it divides the range evenly, and
when a step is also declared it is a multiple of the step, so every tick is
a position the thumb can reach; ticks at hand-picked values (50, 100, 200)
are refused. The five shapes real apps ship, in that spelling: volume
(0, 0); balance −1..1 with a centre mark (0, 1); quality low/medium/high
0..2 (1, 1); font size 8..72 or a frame playhead (1, 0); a thermostat
60..80 with a tick every five (1, 5). ON THE IPHONE, DRAW THEM: Apple's own
Larger Text slider in Settings is a stepped slider with a tick at every
size, drawn under the track — a custom control, since UISlider offers no
ticks, and it looks like the platform. The Mac hosts NSSlider (SwiftUI's
own Slider draws a tick per stop for any stepped slider and offers no
switch), Windows and GTK take the spacing natively, and Compose draws kaya's
ticks when the spacing is coarser than the step, since Material's indicators
sit only on stops. The recommendation this replaced follows.

#### S5 as first recommended — ride the step, no prop (superseded)

Ticks appear wherever a stepped slider is drawn by a platform that draws
them (mac, Compose, WinUI); iOS and GTK draw none for a step. LABELLED
marks (GTK `add_mark` with markup; nothing equivalent on the other four)
are refused: a mark is a label the guest can place under the slider in
every binding today, and one platform's affordance is not a kaya prop.

### S6 — Showing the value and labelling the ends (RECOMMEND: no prop)

The kaya idiom is the gallery's: a label beside the slider, written by
the handler, byte-identical on five platforms. Platform dress stays at
its default — WinUI's thumb tooltip and Material's value indicator show
while dragging, GTK's `draw-value` stays off — and end labels are the
guest's labels. SwiftUI's `minimumValueLabel:` and UIKit's end images
are not exposed.

### S7 — Keyboard increments (RECOMMEND: derived from the step)

Every desktop moves a focused slider by keys; the increments differ:
GTK `set_increments(step, page)`, WinUI `SmallChange`/`LargeChange`
(defaults 0.1 and 1 — PageUp on a 0..1 slider jumps to the end), macOS
arrows. With S1 the arm sets the small increment to the step and the
page increment to ten steps; a continuous slider keeps (max − min)/100
and (max − min)/10. No harness verb: the existing typing verb reaches a
focused control on the three desktops if a scene ever needs it.

### S8 — Read-back and the drive route (RECOMMEND: yes, the pickers' precedent)

`expect_slider slider#0 "0.75"` reads the CONTROL's value in fixed
digits (six significant, trimmed), as `expect_picker` reads the calendar
and the spins — the verb the pickers pass measured as "a lot better than
relying on screenshots". And `set_value` goes THROUGH the control on
SwiftUI and Compose as it already does on GTK and WinUI (D8): with S1's
snap and the core's clamp living in the commit path, a verb that writes
the node and emits by hand would skip both and pass a scene the user
cannot.

### S9 — WinUI's quantization (RECOMMEND: fix with S1)

A latent divergence today: the WinUI arm's `StepFrequency(0.01)` snaps
every drag to hundredths of whatever range the guest declared, while the
other four are continuous. S1 replaces the constant: the declared step,
or for a continuous slider a frequency of (max − min)/1000 so the thumb
moves at pixel resolution on any range.

### S10 — Direction, origin fill, centered (RULED: refuse)

Asked what these are: DIRECTION flips which end is the maximum (GTK
`inverted`, WinUI `IsDirectionReversed`; Apple has no switch, and RTL
locales already flip a slider on every platform). ORIGIN FILL is where the
coloured part of the track starts: every platform paints from the minimum
to the thumb, GTK can turn the fill off, and Material's 2025 spec adds a
centered slider whose fill starts in the middle (exposure −2..+2), which is
not in the Compose version kaya pins and has no Apple counterpart. Refused:
every kaya slider fills from its minimum end and reads left to right.

GTK's `inverted`/`has-origin`, WinUI's `IsDirectionReversed` and
Material's centered slider have no counterpart on the Apple platforms
and no app in the roster asks. Refused, recorded.

## §3 — What the video editor needs from this list

From the forcing-app note (2026-09-02): the playhead is a frame-stepped
slider (S1) that scrubs live and commits on release (S2) with keyboard
nudging by one frame (S7); volume and zoom are continuous sliders as
today; in/out trimming is a canvas drag, not a range slider (S3
deferred). The minimal milestone is therefore S1 + S2 + S7 + S8 + S9,
with S3–S6 and S10 recorded as deferred or refused.

## §4 — The sweep

`step` in nine bindings' constructors in both zones (a keyword in Python
and JS, a labelled optional in OCaml, a chained setter or a parameter in
the rest, the C floor packing the prop by hand); `on_commit` beside
`on_change` in each binding's handler idiom and in the template zone's
`InstanceValueCommitted` twin; the record generators untouched (the value
type is still F64); tools/check-sugar-surface.py's census grows a clause
for the slider surface (constructor step, commit handler, both zones),
red until every binding has it — the mid-milestone red the sequencing
pattern expects.

## §5 — Build order, if ruled

Depth: spec (`step` prop, `value_committed` and its template twin),
core validation (step divides the range; value within it), SwiftUI arm
(`step:`, `onEditingChanged`, set_value through the binding), Rust sugar,
`expect_slider`, a `sliders.steps` scene (a stepped slider snapping a
driven 0.37 to 0.4, a commit counted once per gesture, the continuous
twin unchanged, read-back on both). Breadth: Compose (`steps`,
`onValueChangeFinished`), GTK (snap in the commit, release gesture,
increments), WinUI (StepFrequency, SnapsTo, PointerCaptureLost,
Small/LargeChange), the eight other bindings, the five rosters, the
matrix.

## §6 — The WinUI arm, measured on the guest (2026-09-04)

The breadth slice's Windows half. Everything here was measured on the VM
against a real drag and real keystrokes, because NO LANE CAN: `set_value`
is the only slider drive any scene has, and it is one finished gesture by
construction. The first draft of this arm committed on every ValueChanged
and `tools/scenes/sliders.steps` passed byte for byte —
`tools/check-slider-commit.py` is the wall that class earned.

**The probe, so it can be run again.** The sliders guest held open with
no `KAYA_SELFTEST` under `KAYA_SLIDER_TRACE=1` (the arm's own trace,
`winui_slider_trace`, one line per event); the window photographed with
tools/guest/shot-window.ps1 (which prints `946x536 at 137,130`, so a
pixel measured off the picture is a screen point); a drag injected with
`mouse_event` from the thumb's screen point across the track and
released; then VK_RIGHT and VK_PRIOR with KEYEVENTF_EXTENDEDKEY. Each
piece ran through `schtasks /create … /sc once /st 00:00 /it /rl highest
/f` + `schtasks /run` + `wscript run-hidden-args.vbs`, the lane's own
route. The labels the guest writes (`value: 90`, `commits: 1`) are the
end-to-end reading; the trace is the mechanism behind it.

**What a real drag raises on a WinUI 3 Slider.**

| Event | Fires? |
|---|---|
| `ValueChanged` | once per movement, ALREADY SNAPPED to `StepFrequency` (55, 60, … 90 on a step of 5), with `IntermediateValue` carrying the pre-snap pointer position |
| `PointerPressed` | **never** — the control marks its own press handled, and `slider.PointerPressed(…)` registers with handledEventsToo = false |
| `PointerReleased` | **never**, same reason |
| `PointerCaptureLost` | **once, on the release**, with the settled value — the one gesture end this control has |
| `PointerCaptures()` | unreadable (the call answered `Err` on the UI thread) |

`UIElement.AddHandler(PointerPressedEvent, handler, true)` is the
platform's own answer to a handled press and is OUT OF REACH from these
bindings: `AddHandler`'s handler parameter is `IInspectable` and a
windows-rs WinRT delegate implements `IUnknown` alone, so the call does
not typecheck (`PointerEventHandler: Param<IInspectable>` unsatisfied)
and forcing it would hand XAML a pointer that fails the QI it makes.

**So the drag/keyboard split is `GetKeyState(VK_LBUTTON)`**, read inside
the ValueChanged handler — which runs on the UI thread while that thread
is processing the very input message that raised it, so the answer is
that message's. It is the twin of the SwiftUI arm's
`NSApp.currentEvent?.type` test, and it gives the same answers: a drag's
movements are not final, a key's and a wheel's are, a driven `set_value`
is. Measured: eight movements with `button=true` and `committed`
unmoved, then `pointer_capture_lost` with `button=false` publishing once
— `value: 90`, `commits: 1` on the guest's own labels after an
eight-movement drag.

**Keyboard (S7).** `SmallChange` = the step is live: VK_RIGHT moved the
slider 90 -> 95 and committed at once (`commits: 2`). VK_PRIOR raised
NOTHING, with and without KEYEVENTF_EXTENDEDKEY, so WinUI 3's Slider does
not spend `LargeChange` on Page Up here; the arm sets it to ten steps per
S7 and the platform decides which key spends it.

**Ticks (S5) and the step (S1, S9).** `TickFrequency` = the spacing with
`TickPlacement::Outside`, which is what WinUI Gallery's own ticked slider
declares (WinUIGallery/Samples/Slider/SliderTicks.txt), and
`TickPlacement::None` when the spacing is 0. `StepFrequency` = the step,
or `(max − min) / 1000` for a continuous slider, with
`SnapsTo(StepValues)`: the measured drag on the 0..1 continuous slider
moved in thousandths (0.866, 0.887, 0.908 …) where the retired constant
0.01 had quantized it to hundredths.

**Order-independence.** The props arrive as separate `SetProp` writes in
the sugar's order (min, max, value, then the chained step and spacing)
and WinUI COERCES a value against the range and the step it holds at the
time, so each of the four shape props moves its slot in the arm's cell
and re-applies the whole shape (`winui_slider_shape`), quiet throughout
because Minimum and Maximum raise `ValueChanged` when they coerce.

**The bindgen rows this needed** (tools/winui-bindgen/src/main.rs):
`Primitives.SliderSnapsTo`, `Primitives.TickPlacement`,
`Input.PointerEventHandler` and `Input.PointerRoutedEventArgs`. Without
them `SetSnapsTo`, `SetTickPlacement` and every pointer event were
`usize` vtable pads while `SetStepFrequency` and `SetTickFrequency`
beside them were real methods — windows-bindgen pulls no referenced type
transitively.
