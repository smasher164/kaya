# The range and the vertical slider: the design pass

Status: DESIGNED 2026-09-29; the DEPTH and BREADTH slices built the same
day: all five backends and nine bindings, §4 MEASURED on every platform,
range, rangertl and the sliders fader on every lane, and rule 11 RULED and
built; what is left is docs/deferred.md's "WATCH — the range's tie and its
readers' names". The video editor's trim control
and its volume fader (docs/video-editor-plan.md §4, ruling 6, RULED
2026-09-28: a separate `range` kind, horizontal, two thumbs for trim in and
out; the vertical fader is the `axis` a row, column and scroll take, now
legal on a slider). It picks up docs/slider-plan.md S3 and S4, which
deferred both. Every choice in §1 to §7 is RECOMMENDED; §8 asks three.

## §1. What the platforms have

Read 2026-09-29 from the vendors' pages and, where named, from the code.

| | two thumbs | vertical | min end when vertical |
|---|---|---|---|
| macOS | none (`NSSlider` is one value) | `NSSlider.isVertical` | bottom |
| iOS | none (`UISlider` is one value) | none; apps rotate the view | (rotated: bottom) |
| GTK 4 | none (`GtkRange` is one adjustment) | `GtkOrientable` on `GtkScale` | TOP unless `inverted` |
| WinUI 3 | none in WinUI; Community Toolkit `RangeSelector` | `Slider.Orientation` | bottom |
| Compose (material3 1.3.1, the BOM pin) | `RangeSlider` | none at the pin | (rotated: bottom) |

**Compose, read from the pinned aar** (compose-bom 2024.10.01 in
android/kaya/build.gradle.kts is material3 1.3.1; `javap` over its
classes.jar): `RangeSlider(value: ClosedFloatingPointRange<Float>,
onValueChange, modifier, enabled, valueRange, steps: Int,
onValueChangeFinished: (() -> Unit)?, colors)` and a `RangeSliderState`
overload. `steps` counts interior stops as on `Slider`, and
`onValueChangeFinished` carries no value. A drag clamps at the other thumb
(`coerceIn(minPx, rawOffsetEnd)`): no crossing, no pushing, no gap. Each
thumb is its own semantics node whose `setProgress` calls
`onValueChangeFinished`, described by Material's "range start"/"range end"
strings. No key handling, as the slider's S7 cell found. `VerticalSlider`
is absent; it arrives in the 1.4.0 alphas under
`ExperimentalMaterial3ExpressiveApi`, top as the minimum by default.

**WinUI's RangeSelector** (NuGet `CommunityToolkit.WinUI.Controls.RangeSelector`
8.x, https://learn.microsoft.com/en-us/dotnet/communitytoolkit/windows/rangeselector/,
source read at github.com/CommunityToolkit/Windows): `RangeStart`,
`RangeEnd`, `StepFrequency`, `Orientation`, `ValueChanged`,
`ThumbDragCompleted`; two `Primitives.Thumb`s on a Canvas, a drag clamped
at the other thumb, and NO automation peer, so a reader meets two
`Thumb`s with no RangeValue pattern. It is a C# library, and kaya's WinUI
backend is Rust over windows-rs bindings from the App SDK metadata
(tools/winui-bindgen, tools/fetch-winappsdk.sh): a process hosting no CLR
cannot activate a managed control, so no exact pin would bring it in reach.

**What Apple and GNOME apps do without one.** Apple's trim bars (Photos,
QuickTime) are custom views; AppKit apps subclass `NSSliderCell` and draw
two knobs with its `drawBar`/`drawKnob` (SMDoubleSlider); SwiftUI apps draw
two `DragGesture` thumbs and, done well, give each
`.accessibilityRepresentation { Slider(…) }`. What each must expose: two
`UIAccessibilityElement`s with the `.adjustable` trait and
`accessibilityIncrement`/`Decrement` on UIKit, two `NSAccessibilitySlider`
elements on AppKit, one `GtkAccessibleRange` per thumb on GTK (4.10, "a
single value within an allowed range", role `SLIDER`), one RangeValue
provider per thumb on UIA. GNOME's Video Trimmer
(gitlab.gnome.org/YaLTeR/video-trimmer, src/timeline.rs) draws its own
`vt-timeline` widget with no accessible range and pairs it with start and
end timestamp entries, which are its accessible route.

**Rotation.** UIKit hit-tests through a view's `transform` and derives
`accessibilityFrame` from the transformed frame; Compose's `graphicsLayer`
transforms pointer positions and semantics bounds. VoiceOver and TalkBack
adjust by value, so a rotated slider's "increase" still increases (§4).

## §2. The surface

**`range`, a new kind (22), in both construction zones.** It shares the
slider's `min` (4), `max` (5), `step` (24) and `tick_spacing` (25), with one
meaning each, and adds:

- `low` (46, F64) and `high` (47, F64): two props, not one pair value. Each
  is an ordinary F64 write, so the template zone binds a stamped range's
  thumbs to two row fields (a clip's `trim_in` and `trim_out`) with no new
  value type, and the generators move nothing but two names.
- `min_gap` (48, F64, default 0): the least distance between the thumbs,
  in value units. A trim of zero frames is not a clip; the editor declares
  one frame's duration. When a step is declared the gap is a multiple of it.
- `low_label` (49) and `high_label` (50), Str: what each thumb speaks (§8
  ruling 2). The range's own `a11y_label` names the pair as a group.

**Two occurrences, the slider's pair in shape.** `range_changed` (37) on
every movement of either thumb and `range_committed` (38) once per gesture,
each carrying BOTH values as a two-value `span` field (`draw_requested`'s
`size` precedent), keys first when stamped. A handler never sees half a
trim. The sugar spells them `on_change` and `on_commit`, the slider's
words, the handler receiving `(low, high)`. A commit equal to the last
committed pair does not fire; an app write never echoes.

**The slider gains `axis`** (18), `horizontal` by default, mutable, a
breakpoint may set it (the scroll's extension, docs/hscroll-plan.md §1).
scene.rs's `Prop::Axis` legality grows `Slider`. A `range` refuses `axis`
at the root, per ruling 6, until an app asks for a vertical range.

## §3. The rules

1. **`min ≤ low ≤ high ≤ max` and `high − low ≥ min_gap`**, refused at the
   root on the complete declaration at the end of the transaction
   (`SliderRange::check`'s shape, the colour picker's any-order rule), so
   an app moving both thumbs writes them in either order.
2. **Thumbs stop; they neither cross nor push.** A dragged thumb halts
   `min_gap` short of the other, which is what Compose and the Toolkit
   both do. One core function snaps to the step, clamps to the range and
   to the other thumb, and every arm's commit path calls it, as the
   slider's `kayaSnappedSlider` twins do today.
3. **Live and committed as on the slider.** A playhead scrubs on
   `range_changed`; a trim commits once on `range_committed`. The commit
   doors are the slider's per platform (release, a key, an assistive
   adjust, a driven `set_value`), and a gesture on one thumb commits the
   pair.
4. **Keyboard: two focus stops, low first.** Arrows move the focused thumb
   by the slider's nudge and commit at once. A press is routed by
   GEOMETRY, never by which native slider is on top: the track splits at
   the midpoint between the thumbs and each half belongs to its thumb
   (Material Web's fix; wrong-thumb presses are the most reported defect
   in the survey, docs/probes/range-sliders-2026-09-29.md). When the
   thumbs coincide, the side of the thumb the press lands on picks, decided
   at press-down, when a native slider starts tracking (androidx's rule
   since 2025-07; material3 1.3.1, kaya's pin, still picks by drag
   direction, so Android differs on a tie until the BOM moves). The thumb
   drawn on top at a tie carries an outline, as Flutter, Compose and
   Material Web draw it.
5. **Right to left mirrors the range as it mirrors the slider**
   (docs/slider-plan.md S10): in Arabic the low thumb sits at the right and
   is still the first focus stop.
6. **A vertical slider has its minimum at the bottom on every platform,
   Up raises it, and right to left has no effect on it.** GTK's scale
   needs `inverted` for that; the rest are native or rotated.
7. **The accessible shape is a group of two sliders.** Each thumb is its
   own adjustable element with the range's min and max and its own value
   (a stacked native slider reports the whole range, not the other
   thumb's value; overriding that per platform is deferred, and the value
   still stops at the other thumb);
   `expect_ax` reads `group/<label>` on the range and `slider/<name>` on
   each thumb, on every platform.
8. **Every path clamps, the assistive one included.** The one core clamp
   runs on each native slider's value-changed path, whatever moved it (a
   pointer, a key, VoiceOver, TalkBack, Narrator, Orca), and writes the
   clamped value back into that slider; libraries that guarded only the
   touch path let a screen reader cross the thumbs.
9. **Only the native tracks are hidden.** A stacked slider's own track and
   tick marks are turned off and kaya draws one track and the ticks once;
   a native thumb is never resized or restyled (Material Web broke iOS
   dragging that way).
10. **Precision beside the control.** A trim needs finer steps than a
    thumb gives on a long clip; the pattern every editor surveyed uses is
    number fields beside the range (the number field, and the timecode
    formatter at video-editor time), which the editor's inspector will do.
11. **An app write is judged against the pair as it really stands.**
    RULED 2026-09-29 (the maintainer, option a). The core's record of the
    pair follows the user: every `range_committed` the user makes moves it
    (`Scene::user_range_committed`, called at every arm's commit door; the
    fullscreen and section mirrors are the precedent). A transaction that
    writes ONE thumb of a range the backend already holds, past the other
    thumb as it now stands (the user moved it and the app had not heard),
    is CLAMPED there through the one clamp, never refused; two thumbs
    written in one transaction are still read against each other and
    refused as rule 1 says. When the clamp changed the write, the app hears
    the settled pair in one `range_committed`: a correction, not an echo,
    since a write that lands as written fires nothing. The core reads the
    writes off the batch's ops (`settle_range_writes`), so a live range and
    a stamped copy's row field are one path; the app's own signal keeps what
    it wrote, as it already does after a user move.

## §4. What is measured first

1. **Compose's RangeSlider**: the clamp on a drag and on `setProgress`, the
   nearest-thumb tap, `onValueChangeFinished` after an assistive adjust (the
   bytecode says yes), right to left, and that a thumb's own description is
   replaced when the arm sets one.
2. **The stacked pair (§6), four platforms**: that a press lands on the
   nearer thumb's slider (a container `hitTest` on AppKit and UIKit, a
   subclassed `GtkScale` answering `contains`, WinUI's z-order set on
   `PointerMoved` before the press, superseded by a clip per slider, below), that each slider's track hides (a
   cell whose `drawBar` draws nothing, UIKit's clear track tints (empty track images restyle the thumb, measured below), a CSS
   class on the `trough`, WinUI's template parts by name), that kaya's
   track meets the thumbs' centres, and that the reader sees two sliders.
3. **Vertical**: the bottom minimum and the Up key on all five; on the
   phones the rotated hit box, accessibility frame and adjust direction,
   and a layout that swaps Compose's constraints so the box is tall; under
   `KAYA_LOCALE=ar-EG`, that none flips.

   MEASURED 2026-09-29, macOS 26 (a probe window driven only by events
   posted into its own queue and the AX API against its own pid, the host
   idle 150-350s; docs/probes/range-stack-mac-2026-09-29.swift):
   - Two `NSSlider`s whose cell's `drawBar(inside:flipped:)` draws nothing,
     in one container that draws the bar and the fill: the knobs' centres
     sit on the drawn bar's centre line (both cells' `barRect` coincide),
     and the picture is one track under two native knobs.
   - The container's `hitTest` answering by the midpoint split sends every
     press to the right slider, a click on the track included (that slider
     warps to it). At a tie (gap 0) the side of the shared centre the press
     lands on picks, at press-down: 3pt left moved the low thumb, 3pt right
     the high one.
   - The clamp in the slider's action stops a thumb at the gap and writes
     it back: low dragged to the end (raw 10) landed at `high - min_gap`.
   - The assistive path goes through the same action: `AXValue` set to 9.5
     on the low `AXSlider` and `AXIncrement` both arrive as the slider's
     action and are clamped and written back. `NSApp.currentEvent` there is
     stale (the last real event), which the slider's final test reads as
     final. An in-process `setAccessibilityValue` does NOT move an
     `NSSlider`: it stores an override the reader then reports, so no arm
     may call it on a live slider.
   - The reader sees `AXGroup` (the range's label) holding two `AXSlider`s,
     each named by its own label, each with the whole range as its bounds
     and increment/decrement actions (rule 7 as written).
   - `NSSlider.isVertical`: the minimum is at the bottom and the Up arrow
     reaches `moveUp:`, which KayaNSSlider already turns into +nudge.
   - A thumb's centre travels from half a knob in from each end of the bar,
     so `expect_thumb` reads the fraction of that TRAVEL (§5 amended).
   - Probe mechanics only: a posted drag reaches `NSSliderCell`'s tracking
     only while `NSEvent.pressedMouseButtons` says a button is down (it
     reads the hardware), and its tracking loop takes one posted drag per
     gesture; the harness drives through `set_value`, never a drag.

   MEASURED 2026-09-29, GTK 4.18.6 with libadwaita (the kaya-linux image
   under Xvfb, a real XTEST pointer and keyboard from xdotool, the reader
   an AT-SPI client in a second process;
   docs/probes/range-stack-gtk-2026-09-29.py, run LTR and under RTL):
   - GTK's pick tries a widget's CHILDREN before its own `contains`
     (gtkwidget.c `gtk_widget_do_pick`), so a subclassed `GtkScale`
     answering `contains` on its half routes nothing: its own full-width
     trough picks first, and every press went to the top scale, exactly as
     with no routing at all (7 of 7). AMENDED (§6): the scale's own
     children are made untargetable as well, so the pick reaches the
     scale's `contains`; then all 7 presses went to the right thumb, in
     both directions. The pick also trusts `contains` for the bounds, so
     it answers the widget's own rect AND the half.
   - A tie (gap 0) resolves by the side of the shared centre the press
     lands on, at the pick, which is press-down: 3px left moved low, 3px
     right moved high; under RTL the reverse, so the side is read from the
     widget's direction, never from the knobs' order.
   - The clamp in `value-changed` stops a dragged thumb at the gap and
     writes it back (low dragged past high rested at 7). An AT-SPI
     `Value.SetCurrentValue(9.5)` on the low slider, Orca's route, arrives
     as `value-changed` and was clamped to 7 and read back as 7.
   - The reader sees a `grouping` (the range's label) holding two `slider`s,
     each named by its own label, each with the whole range as bounds;
     kaya's track widgets, marked `Presentation`, do not appear.
   - libadwaita styles the knob's hover and press on the SCALE's state
     (`scale:hover > trough > slider`) and the focus ring on the focused
     scale's knob, so the untargetable knob keeps its look. The native
     trough and highlight hide by a CSS class that changes no size; kaya's
     trough, a `scale > trough > highlight` node tree placed at the native
     trough's bounds, matched it to the pixel, the fill running between the
     two knobs' centres. Ticks: marks on both scales so the troughs
     coincide, the high scale's at opacity 0.
   - The travel is GtkRange's own (`gtk_range_compute_slider_position`):
     the trough less the slider's measured size; low 2 and high 8 read
     0.2 and 0.8, and 0.8 and 0.2 under RTL.
   - `Orientation::Vertical` with `inverted(true)`: 0.25 from the bottom at
     0.25, the Up key raised it to 0.5, and RTL changed nothing.
   - What the routing costs: a press on a knob but off its centre warps the
     knob's centre to the pointer, since GtkRange sees no slider under the
     press (at most half a knob, usually inside one step), and GtkRange's
     shift-click fine-tune never starts.

   MEASURED 2026-09-29, WinUI 3 (Windows App SDK 2.2, the lane's Windows 11
   arm64 VM, 96 DPI; real `mouse_event` and `keybd_event` input on the
   system queue, the reader a UIA client in a separate PowerShell process;
   docs/probes/range-stack-winui-2026-09-29.py driving
   docs/probes/range-stack-winui-2026-09-29.ps1, run LTR and under
   `KAYA_LOCALE=ar-EG`, with the gap forced to 0 for that run so a tie
   could be pressed). AMENDED (§6): WinUI routes by CLIPPING, not by
   z-order. Each Slider's `UIElement.Clip` is its half of the track, split
   at the midpoint of the two thumbs' centres (the shared centre at a tie).
   XAML hit testing honours the clip, and the Slider marks its own
   PointerPressed handled, so the clip is the only routing surface
   available (slider-plan §6):
   - A click on the track in the low half moved low to the click (3.5), and
     in the high half moved high (6.5). A drag of low toward the far end
     stopped at the other thumb, with one commit for the whole drag.
   - At a tie, a press 3px left of the shared centre dragged low and 3px
     right dragged high. A press on one side dragged toward the other left
     both where they were and committed nothing. Under RTL the two sides
     swap, so the range mirrors: the slider's local coordinates flow right
     to left with it (low's centre read 37 on a 160 DIP slider at value 2),
     and the clip is set in them.
   - UIA's `RangeValue.SetValue(9.5)` on the low thumb (Narrator's route)
     arrives as `ValueChanged` and was clamped and written back: UIA read
     the clamped value. `SetValue(1)` on high left the pair unchanged.
   - The reader sees a `Group` named by the range's label holding two
     `Slider`s, each named by its own label. Each thumb's
     BoundingRectangle is its CLIPPED half: UIA reports the bounds after the
     clip, so a reader's highlight draws around the half a press would take.
   - The native `HorizontalTrackRect` and `HorizontalDecreaseRect` hide at
     opacity 0 by template name, which keeps the layout. The template's
     visual states animate only their Fill, never their Opacity. kaya's
     track, fill and ticks are drawn with `SliderTrackFill`,
     `SliderTrackValueFill`, `SliderTrackCornerRadius` and
     `SliderTickBarFill`, laid at the native track's box, and the fill runs
     from one thumb's centre to the other's (picture viewed). The keyboard
     focus rectangle is clipped with its slider, so it outlines the focused
     thumb's half. At a tie the two clipped thumbs draw as ONE knob made of
     two halves, with a faint seam and neither on top, so no outline is
     drawn (rule 4's outline marks the thumb on top, and there is none).
   - The travel is the template's own: an 18 DIP thumb whose centre runs
     from 9 DIP in at each end. Low 2 and high 8 read 0.2 and 0.8, and 0.8
     and 0.2 under RTL.
   - `Orientation::Vertical`: a press near the bottom read 0 and one near
     the top read 1, Up raised 0.25 to 0.5, and RTL flipped neither. It
     does flip the horizontal arrow keys on a vertical slider (Right
     lowered it under ar-EG), which is WinUI's own key mapping. The
     harness's nudge sends Up and Down only.
   - Probe mechanics only: a drag needs MOVE|ABSOLUTE input. A bare
     `SetCursorPos` raises no pointer update, and the thumb never moved.

   MEASURED 2026-09-29, iOS 26.5 simulator (iPhone, 375x812pt; the arm's
   mechanics in docs/probes/range-stack-ios-2026-09-29.swift, real touches
   from the lane's XCUITest driver, and the range legs themselves):
   - An empty track IMAGE restyles the thumb: UIKit drops the Liquid
     Glass capsule for the legacy round knob (the guest photographed beside
     its own playhead slider), and the thumb's `trackRect` becomes ZERO
     high. A CLEAR TRACK TINT (`minimumTrackTintColor` and
     `maximumTrackTintColor` `.clear`) keeps the platform's own thumb and a
     4pt `trackRect` centred on it, which is where kaya draws (§3 rule 9;
     tools/check-slider-commit.py holds it).
   - The knob's centre travels from the view's BOUNDS (31pt knob on a 300pt
     slider: 35.5 to 284.5), not from `trackRect`, so `expect_thumb` reads
     the knob's own centres at the minimum and the maximum. AppKit's compat
     design (a host with an SDK stamp below 26, the JVM) does the same while
     the modern one runs from the bar, measured headless the same day, so
     the mac arm reads its cell's knob at both ends too.
   - Routing: a drag from the high knob was routed to high and moved it;
     a TAP on the track right of the midpoint was routed to high, and
     `UISlider` does not begin tracking off its knob, so nothing moved (a
     click on the track warps only on macOS). At a tie (gap 0), a press 3pt
     left of the shared centre moved low and one 4pt right moved high,
     decided in `hitTest`, before `beginTracking`.
   - Right to left MIRRORS both platforms' sliders (a `UISlider` puts its
     minimum at the right; an `NSSlider` under `userInterfaceLayoutDirection`
     too, value 2 of 10 at 154 of 200pt), so the split reads which side of
     the midpoint the low thumb is on and the tie's minimum side from the
     slider's direction; the depth's split sent every ar-EG press to the
     other thumb and its fill drew nothing.
   - The reader sees a group of two `Slider`s 'In' and 'Out', each with its
     own value, each framed as the whole control; kaya's reader needs the
     container to answer its element count, so the arm declares
     `accessibilityElements = [low, high]`, low first in either direction.
     VoiceOver adjusts only by increment and decrement on iOS (no value
     set), and `UISlider`'s own increment did nothing here, so the arm's
     override through the clamp is the whole door; `nudge` drives it on the
     iOS legs (§5).
   - The fader: the rotated slider's minimum is at the bottom (window y 529
     at 0, 360 at 1), a real drag up the tall axis from the knob raised it
     0.25 to 0.73, the accessibility frame is the tall wrapper (34x200,
     where it is drawn), and increment raised the value and the knob. Under
     ar-EG the range mirrors (`rangertl` reads low at 0.8) and the fader's
     0.25 does not move.

   MEASURED 2026-09-29, Android (the lane's API 35 emulator, 360x800dp at
   density 160, material3 1.3.1 over compose-ui 1.7.5; the range guest driven
   by `adb input` between dumps of the thumbs' node info, and the provider's
   own `performAction`, the call TalkBack makes):
   - A drag of the low thumb past the high one stopped at `high - min_gap`
     (7 of 8), one commit. Material stops a drag at the other thumb; the
     arm's clamp adds the gap, and the control draws the answer.
   - A tap on the track moves the nearer thumb there (low 7, high 8: a tap
     at 2 moved low, one at 9.5 moved high), one commit each.
   - `ACTION_SET_PROGRESS` on the low thumb asked 9.5 came back 8.5 (high
     9.5, gap 1) and committed once: `onValueChangeFinished` runs after an
     assistive set. Asked below the other thumb, the high one stays and
     nothing commits. `set_value` on a range takes this door on the lane.
   - A tie (gap 0) is decided by the DRAG'S DIRECTION, never the press's
     side: pressed right of the shared centre and dragged left, low moved;
     pressed left and dragged right, high moved (rule 4's recorded
     divergence). Under ar-EG a drag toward the minimum moved low and one
     toward the maximum moved NEITHER thumb. While the thumbs coincide the
     low thumb has no node info at all (compose-ui drops a node another
     covers), so a service reaches only the high one.
   - Right to left mirrors the range: low at 2 sits at the right.
   - The thumbs' words: Material reads "range start" and "range end" through
     `LocalContext`'s resources, so the arm answers those two ids with
     `low_label` and `high_label` (the range's `a11y_label` when unset) and
     the merged semantics names the thumbs "In" and "Out", replacing
     Material's words rather than joining them. BUT compose-ui 1.11.4 (the
     version the foundation pin ships, not 1.7.5) put NO content description
     on any Material slider's node info (these two thumbs, the fader, the
     plain slider): the node merges its children and the thumb's
     `background(shape)` gives it one, and
     `populateAccessibilityNodeInfoProperties` then skips the description.
     `uiautomator dump` read `content-desc=""` on every SeekBar and "Trim"
     on the group. FIXED 2026-09-29 with kaya's own thumb (docs/traps.md,
     "A Material slider's thumb takes its name").
   - The fader (the Material slider in a −90° layer, constraints swapped,
     left to right inside): a 48x200dp box whose node info frame is tall
     (44x218); a drag of the thumb upward set 1.0 and a tap near the
     travel's bottom set 0 (hit testing goes through the rotation);
     `ACTION_SCROLL_FORWARD` raised 0 to 0.25 and the thumb moved up.
     Under ar-EG it does not flip.

## §5. How a leg sees it

A new shared scene, `range.steps`, one guest per language: a range 0..10
with `step 0.5`, `min_gap 1`, `low 2`, `high 8`, and labels its two
handlers write. And `sliders.steps` gains a vertical fader.

- `expect_value range#0 "2 8"`: both values from the CONTROL, the slider's
  fixed spelling, space-separated.
- `set_value range#0 low 3.2`: the thumb's own control moves and commits
  once; the value snaps to `3` and the committed label moves once.
- `set_value range#0 low 9.5`: stops at `7` (the gap); `expect_value`
  reads `"7 8"`.
- a button writes `low(1)`: the control moves, no label moves (the echo).
- `nudge range#0 high down`, `nudge slider#1 up`: the keyboard's path, on
  the three desktops; Android's lane table drops the lines (the number
  field's precedent). AMENDED 2026-09-29 (the iOS breadth): on iOS `nudge`
  calls the adjustable element's own `accessibilityIncrement` /
  `accessibilityDecrement`, what VoiceOver's swipe calls and the phone's
  only stepping door, so the iOS legs run the lines and the assistive path
  through the clamp is observed on a lane.
- `expect_axis slider#1 "vertical"` and `expect_thumb slider#1 "0.25"`: the
  orientation read from the control, and the thumb's centre as a fraction
  of its travel (its centre at the minimum to its centre at the maximum,
  AMENDED 2026-09-29 from "of the track": the knob rests half its width in
  from each end, §4) from the LEFT edge (horizontal) or the BOTTOM
  (vertical) in the platform's own geometry, two decimals; `expect_thumb range#0 low
  "0.2"` reads one thumb.
- `expect_ax range#0 "group/Trim"`, `expect_ax range#0 low "slider/In"`.
- a stamped range per row commits with its row's key.

`rangertl.steps` runs the same guest under ar-EG: the low thumb reads
`0.8` from the left, the vertical fader's `0.25` does not move.

Verbs: `set_value`, `expect_value`, `nudge`, `expect_axis` and `expect_ax`
grow range and slider targets (a thumb word after a range target). New:
`expect_thumb`, since neither the bottom minimum nor mirroring shows in a
value.

## §6. The lowerings

| backend | range | vertical slider |
|---|---|---|
| SwiftUI macOS | the stacked pair: two `KayaNSSlider`s in one container view, cells drawing knobs only, one bar drawn by kaya with the accent fill between | `isVertical = true` on the hosted `NSSlider` |
| SwiftUI iOS | the stacked pair: two `UISlider`s with clear track tints over one track view kaya draws, `hitTest` to the nearer `thumbRect` | the `KayaTickedSlider` wrapper rotated −90°, its intrinsic size swapped, left to right forced |
| GTK | the stacked pair: two subclassed `GtkScale`s answering `contains` on their half of the midpoint split, with their own children untargetable (§4 MEASURED), troughs hidden by a CSS class, one trough drawn in Adwaita's `scale trough highlight` nodes | `Orientation::Vertical` with `inverted(true)` |
| WinUI | the stacked pair: two `Slider`s in one Grid cell, track parts hidden by name, each Slider CLIPPED to its half of the track at the midpoint between the thumbs (AMENDED 2026-09-29, §4) | `Orientation::Vertical` |
| Compose | material3 `RangeSlider`, uncontrolled toward the app over the one commit path, kaya's tick painter as on the slider | the Material `Slider` in a −90° `graphicsLayer` with swapped constraints, `LocalLayoutDirection` Ltr inside |

**The stacked pair** is the web's answer to the same absence (two range
inputs over one track) in each toolkit. Each thumb is the platform's own
slider, so its look, keyboard, commit door (the arms' existing doors,
already held by tools/check-slider-commit.py) and accessibility element
(AXSlider, `.adjustable`, AT-SPI `slider`, UIA RangeValue) are the
platform's. kaya draws only the shared track and the fill between the
thumbs, in the platform's tokens; each slider's own track is hidden
because its fill runs from its minimum. A range takes the slider's
stand-in length; a vertical slider takes it as its height.

## §7. Bindings and guards

Bindings: `range(min, max, low, high)` with `step`, `tick_spacing`,
`min_gap`, `low_label`, `high_label`, `on_change` and `on_commit` in all
nine and both zones, spelled as each spells the slider; `axis` on a slider
handle in the idiom every binding already has for a scroll's. The C floor
packs the props. A do/can't/defer verdict per language at the sweep; no
carve-out expected. No dependency is added, so tools/check-pins.py has
nothing new to hold.

Guards:
- Core unit tests: the root's four refusals (order, bounds, gap, gap not a
  multiple of the step), `axis` refused on a range, and the one clamp
  function stopping a thumb at the gap, each watched failing on a cut.
- tools/check-slider-commit.py grows range rows: every `range_committed`
  emit sits inside its backend's commit door, since `set_value` is one
  finished gesture and a per-movement commit passes the scene byte for
  byte.
- tools/check-sugar-surface.py: the kind in both zones, its props and two
  handlers in nine, `axis` on the slider in nine, fake-name negatives.
- tools/check-verbs.py: `expect_thumb`, the thumb word, the kind and the
  two occurrences in both interpreters.
- tools/check-stubs.py: `depth_stub("range")` until each arm exists.
- tools/scenes/a11y.steps asserts the group and its two sliders;
  `rangertl.steps` is rule 6's wall, so it needs no static clause.

## §8.5. What this widget is not

A Photos- or iMovie-style trim bar (bracket handles over a filmstrip) is
not this kind: stacking gives the platform's slider thumbs on a plain
track, and kaya has no layering of a control over other content. Trimming
a clip's edge on the editor's timeline is a drag on the canvas timeline,
as in every editor surveyed. If the editor wants a filmstrip trim bar, it
is its own piece, drawn by kaya with one accessible element per handle.

## §8. The three rulings

1. **On the four platforms with no two-thumb control, stack two of the
   platform's sliders, or draw the whole control?** Drawing means kaya owns
   the thumbs' look, hit testing, keys and two hand-made accessibility
   elements per platform, the custom-drawn tax DESIGN.md refuses. Stacking
   means two real sliders with hidden tracks, hit routing being the one
   hard part (§4.2). RECOMMEND stacking; a platform where §4.2 fails draws,
   and the plan comes back with the measurement.
   RULED 2026-09-29 (the maintainer), stacking, after the survey of about
   thirty-five toolkits (docs/probes/range-sliders-2026-09-29.md): almost
   none stack, but most that draw ship no per-thumb accessibility, and the
   web moved to a native input per thumb for that reason; kaya owns press
   routing by geometry (§3 rule 4). Rulings 2 and 3 are built as
   recommended, pending the maintainer's word.
2. **Who names the two thumbs?** Only Compose has words for them
   ("range start", "range end", in Material's languages); kaya carries no
   strings of its own. RECOMMEND `low_label` and `high_label`, written by
   the app from its own catalog, replacing Material's on Android too. Left
   unset, each thumb speaks the range's `a11y_label`, and a listener tells
   them apart only by order.
3. **The vertical slider on the phones: rotate, or keep them horizontal?**
   S4 proposed a carve-out; neither UIKit nor material3 1.3.1 has a
   vertical slider, and Control Center's volume and Material 3's newer
   vertical slider show both platforms using one. RECOMMEND rotating (§6),
   because an app that declares a fader gets one everywhere; the carve-out
   is the fallback if §4.3 finds the rotation breaks hit testing or an
   assistive reader.
