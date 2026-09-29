# The range and the vertical slider: the design pass

Status: DESIGNED 2026-09-29; nothing built. The video editor's trim control
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
   by the slider's nudge and commit at once. A press on the track takes
   the nearest thumb; when they meet, the drag's direction picks
   (Material's `captureThumb`).
5. **Right to left mirrors the range as it mirrors the slider**
   (docs/slider-plan.md S10): in Arabic the low thumb sits at the right and
   is still the first focus stop.
6. **A vertical slider has its minimum at the bottom on every platform,
   Up raises it, and right to left has no effect on it.** GTK's scale
   needs `inverted` for that; the rest are native or rotated.
7. **The accessible shape is a group of two sliders.** Each thumb is its
   own adjustable element with the range's min and max and its own value;
   `expect_ax` reads `group/<label>` on the range and `slider/<name>` on
   each thumb, on every platform.

## §4. What is measured first

1. **Compose's RangeSlider**: the clamp on a drag and on `setProgress`, the
   nearest-thumb tap, `onValueChangeFinished` after an assistive adjust (the
   bytecode says yes), right to left, and that a thumb's own description is
   replaced when the arm sets one.
2. **The stacked pair (§6), four platforms**: that a press lands on the
   nearer thumb's slider (a container `hitTest` on AppKit and UIKit, a
   subclassed `GtkScale` answering `contains`, WinUI's z-order set on
   `PointerMoved` before the press), that each slider's track hides (a
   cell whose `drawBar` draws nothing, UIKit's empty track images, a CSS
   class on the `trough`, WinUI's template parts by name), that kaya's
   track meets the thumbs' centres, and that the reader sees two sliders.
3. **Vertical**: the bottom minimum and the Up key on all five; on the
   phones the rotated hit box, accessibility frame and adjust direction,
   and a layout that swaps Compose's constraints so the box is tall; under
   `KAYA_LOCALE=ar-EG`, that none flips.

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
  the three desktops; the phones' lane tables drop the lines (the number
  field's precedent).
- `expect_axis slider#1 "vertical"` and `expect_thumb slider#1 "0.25"`: the
  orientation read from the control, and the thumb's centre as a fraction
  of the track from the LEFT edge (horizontal) or the BOTTOM (vertical) in
  the platform's own geometry, two decimals; `expect_thumb range#0 low
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
| SwiftUI iOS | the stacked pair: two `UISlider`s with empty track images over one track view kaya draws, `hitTest` to the nearer `thumbRect` | the `KayaTickedSlider` wrapper rotated −90°, its intrinsic size swapped, left to right forced |
| GTK | the stacked pair: two subclassed `GtkScale`s answering `contains` near their knob, troughs hidden by a CSS class, one trough drawn in Adwaita's `scale trough highlight` nodes | `Orientation::Vertical` with `inverted(true)` |
| WinUI | the stacked pair: two `Slider`s in one Grid cell, track parts hidden by name, z-order to the nearer thumb | `Orientation::Vertical` |
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

## §8. The three rulings

1. **On the four platforms with no two-thumb control, stack two of the
   platform's sliders, or draw the whole control?** Drawing means kaya owns
   the thumbs' look, hit testing, keys and two hand-made accessibility
   elements per platform, the custom-drawn tax DESIGN.md refuses. Stacking
   means two real sliders with hidden tracks, hit routing being the one
   hard part (§4.2). RECOMMEND stacking; a platform where §4.2 fails draws,
   and the plan comes back with the measurement.
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
