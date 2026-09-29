# Two-thumb range sliders across toolkits

Research for docs/range-plan.md §1, §6 and §8, done 2026-09-29. Five agents
read the vendors' docs and, for most claims, the source code itself
(downloaded and read, not summarised). The full notes, with a line per
question (a) to (g) for every library and a link for every claim, are:

- docs/probes/range-sliders-2026-09-29/notes-flutter-qt-rust.md (Flutter, Qt Quick, Qt Widgets, egui, Slint, iced, Druid, Dear ImGui, ControlsFX, wxWidgets)
- docs/probes/range-sliders-2026-09-29/notes-android-rn.md (Compose material3, Material Components Views, React Native libraries)
- docs/probes/range-sliders-2026-09-29/notes-xaml.md (Windows Community Toolkit, WPF, Avalonia, .NET MAUI, Uno, UIA)
- docs/probes/range-sliders-2026-09-29/notes-apple-gtk.md (UIKit, SwiftUI, AppKit, Apple's trim UIs, GTK 4, GNOME apps)
- docs/probes/range-sliders-2026-09-29/notes-web.md (ARIA APG, HTML and Open UI, Material Web, React Aria, MUI, Radix, noUiSlider, Web Awesome, Spectrum Web Components, engine accessibility mappings)

Where a note says "unverified", the claim came from docs or inference and
not from reading the code or running it. This file repeats the key facts
and links; the notes carry line numbers.

## Terms

- **Stacked native sliders**: two of the platform's own single-value slider
  controls placed over one track, each keeping its own input handling,
  keyboard and accessibility element.
- **Hidden native input per thumb**: the thumbs are drawn, but each one
  holds an invisible native slider that serves only keyboard and assistive
  technology. The pointer is handled by the drawn control.
- **Drawn / templated control**: one control that owns every press and
  either paints both thumbs or holds two thumb parts (templated children
  with no slider logic of their own).
- **Tie**: both thumbs at the same value, so a press lands on both.
- **Stop / cross / push**: a dragged thumb halts at the other; passes it
  and the two swap roles; or carries the other along.

## Summary table

"2 adj" means two separately adjustable accessibility elements. "Bound"
means each thumb reports the other thumb's value as its min or max (the
APG rule); "whole" means both report the whole range.

| Toolkit / library | First-party? | Built as | Press routing; tie | Stop/cross/push | Accessibility | Thumb names | Keys | Vertical |
|---|---|---|---|---|---|---|---|---|
| Flutter `RangeSlider` | yes | one drawn RenderBox + 2 invisible Focus nodes | nearest by midpoint; tie by first drag direction | stop (`minThumbSeparation`) | 2 adj semantics nodes (iOS `.adjustable`; Android scroll actions, no RangeInfo) | none (value as %) | Tab; arrows only in material_ui | no |
| Qt Quick `RangeSlider` | yes | 2 handle parts in one control | inside a handle: that one, overlap: higher z (last pressed); else nearest | stop; cross since 6.12 (`crossingEnabled`) | ONE Slider element, current value empty (inferred) | none | Tab, arrows | yes, min at bottom |
| Qt Widgets (QxtSpanSlider, superqt) | no | one QSlider subclass; QStyle paints each handle | Qxt: upper first, swap on first move; superqt: lower always (bug #150) | Qxt: cross by default; superqt: stop | QSlider's one element, value unrelated (inferred) | none | Qxt: one stop, keys by axis; superqt: none | yes |
| Compose material3 `RangeSlider` | yes | one Layout, 2 thumb slots, parent owns the pointer | nearest; tie by drag direction ≤1.3.x, by press side since 2025-07 | stop | 2 semantics nodes, RangeInfo, bound | "Range start"/"Range end" | Tab, arrows, PgUp/PgDn, Home/End (fixed 2025-08) | no (single slider only) |
| Material Components Views `RangeSlider` | Google library | one drawn View, N thumbs | nearest value; tie by drag direction | stop, `minSeparation` | 2 ExploreByTouchHelper virtual SeekBars, whole | "Range start"/"Range end" | Tab inside the View, arrows | yes (since 2024-11) |
| React Native libs (multi-slider, rn-range-slider, miblanchard, @sharcoux) | no | JS views, one drawn control each | z-order hack / press side / first in index / press side | stop (sharcoux may cross; multi-slider patch pushes) | none, except @sharcoux: 2 adj | sharcoux: "min"/"max" | none (sharcoux: web only) | some, by rotating |
| WinUI (Community Toolkit `RangeSelector`, also Uno) | no | 2 `Thumb` parts on a Canvas | nearest; tie always Min | stop (push refused, #4029) | 2 focusable Thumbs, NO value (no peer; #3538 open since 2020) | "Min thumb"/"Max thumb" | Tab, arrows only | yes, since 2026-02 |
| WPF Xceed `RangeSlider` | no | **two stock WPF Sliders overlaid**, + a third hidden Slider for ticks | only thumbs hit-test; offset by one thumb width so they never overlap | stop, written back into the slider | 2 stock SliderAutomationPeers (and likely a 3rd for the tick slider) | none | stock Slider keys (inferred) | yes |
| WPF MahApps `RangeSlider` | no | 5 parts in a row (edges, 2 thumbs, middle thumb) | by region; never overlap | stop, `MinRange` | since 2026-09-15: one Slider with 2 RangeValue Thumb children | none | Tab, arrows, PgUp/PgDn, Home/End | yes |
| Avalonia (Ursa, Avalonia.RangeSlider) | no (request #20355) | one control, custom track, 2 Thumbs | nearest; tie by track half / by drag direction | Ursa: PUSH; other: stop | none | none | none / one stop | yes |
| .NET MAUI (Syncfusion, Telerik, DevExpress, PanRangeSlider, halkar) | no | cross-platform views or custom-drawn per platform; none stacks | various | stop | Syncfusion documents screen reader and keyboard as unsupported; others none | none | none | some |
| UIKit libs (TTRangeSlider, RangeSeekSlider, MultiSlider, WARangeSlider, SwiftRangeSlider) | no | one drawn UIControl each | nearest; tie: the thumb that can still move / press side / first hit (deadlock, WARangeSlider #1) | stop | TT/RangeSeek: 2 `.adjustable` elements; others none | "Left Handle"/"Right Handle", or empty | none | MultiSlider yes |
| SwiftUI (spacenation/swiftui-sliders) | no | one ZStack view, 2 DragGestures | z-order; thumbs offset by a thumb width | PUSH by default | none | — | none | yes |
| Apple Photos trim (iOS) | app | custom | — | — | 2 adj (Start, End); users report the step is too small for long videos | "Start"/"End" (unverified verbatim) | — | — |
| AppKit SMDoubleSlider | no | one NSSliderCell time-shared by 2 knobs via private ivars | nearest; tie: hi if jammed at min | stop | one element at best | none | Tab moves between knobs inside the view | yes |
| GTK 4 / libadwaita | no | — (GtkRange has one adjustment) | — | — | GtkAccessibleRange is one value | — | — | — |
| GNOME Video Trimmer | app | one drawn timeline, no thumbs (edges of a selection) | within 5px of end edge, then start; else scrub | CROSS (swap) | none; start/end text entries beside it | — | `i`/`o` set in/out at playhead | no |
| GIMP handle bar, darktable range | app | one drawn widget | nearest / edge snap | darktable crosses then normalises | none; spin buttons or entries beside it | — | none | GIMP yes |
| egui `RangeSlider` (new, 2026-09-17) | yes | one drawn widget + 2 focus-only rects | nearest; tie by press side, locked per gesture | stop, `min_separation` | 2 AccessKit sliders, bound | "low"/"high" | Tab, arrows | yes |
| Druid `RangeSlider` | yes | one drawn widget | left knob first; else nearest | stop | none | — | none | yes |
| JavaFX ControlsFX | no | 2 thumb panes in a skin | high on top; track press not nearest | stop | none | — | faked Tab, arrows, Home/End | yes |
| Dear ImGui `DragFloatRange2` | yes | 2 stock drag fields SIDE BY SIDE | no overlap | stop | none | — | — | — |
| Slint, iced, wxWidgets | none | — | — | — | — | — | — | — |
| Web: APG multi-thumb pattern | spec | one `role=slider` per thumb | not specified | stop (implied) | 2 adj, bound | app's label | Tab, arrows, Home/End, PgUp/PgDn | yes |
| Web: Open UI `<rangegroup>` (proposal) | proposal | **one native range input per thumb on one shared track** | nearest; tie OPEN | overlap allowed; `stepbetween` | 2 native | `<label>` | native | open question |
| Material Web `md-slider range` | yes (Google) | **two native `<input type=range>` stacked**, drawn track/handles/ticks | nearest, by clipping each input at the midpoint; tie by drag direction ("flip") | stop | 2 native, bound (aria override) | "{label} start"/"end" | native | no |
| React Aria / Spectrum | yes (Adobe) | drawn thumbs + hidden native input per thumb | nearest; thumb press by DOM z-order (stuck bugs #3387, #6408) | stop | 2 native, bound | "Minimum"/"Maximum" | native + PgUp/PgDn | yes |
| MUI | yes | drawn thumbs + hidden native input per thumb | nearest; tie last used | swap by default | 2 native, whole | none | native | yes |
| Radix, noUiSlider, Web Awesome | yes | drawn `role=slider` elements | nearest; ties vary | Radix crosses; noUi stops; Web Awesome PUSHES | 2 ARIA sliders | "Minimum"/"Maximum" (Radix) | Tab, keys | yes |

## Per-toolkit notes

**Flutter.** One `_RenderRangeSlider` paints the track, ticks and both
thumbs and does its own hit test; two invisible zero-size `Focus` widgets
give each thumb a Tab stop. The default `RangeThumbSelector` picks the thumb
on the press's side of the midpoint; when both thumbs' 48dp targets contain
the press, nothing is chosen until the first horizontal drag delta (drag
direction), and a zero-movement tap there moves nothing. Two child semantics
nodes, each `isSlider` with increase/decrease; on iOS they get
`UIAccessibilityTraitAdjustable`, on Android they are plain virtual views
with scroll actions and no `RangeInfo`. No default thumb names. No vertical.
Source: [range_slider.dart](https://github.com/flutter/flutter/blob/master/packages/flutter/lib/src/material/range_slider.dart),
[material_ui copy](https://github.com/flutter/packages/blob/main/packages/material_ui/lib/src/range_slider.dart),
[SemanticsObject.mm](https://github.com/flutter/flutter/blob/master/engine/src/flutter/shell/platform/darwin/ios/framework/Source/SemanticsObject.mm),
keyboard PR [#181525](https://github.com/flutter/flutter/pull/181525).

**Qt Quick Controls.** `first.handle` and `second.handle` are delegates
inside one control that handles all input. Press inside both handles: the
higher z wins, and the last pressed is raised. Multi-touch drags both at
once. Qt 6.12 added `crossingEnabled`. The whole control is ONE
`QAccessible::Slider` whose value is read from a `value` property the
RangeSlider does not have, so a reader hears no current value and cannot
adjust a handle (inferred from source). Source:
[qquickrangeslider.cpp](https://github.com/qt/qtdeclarative/blob/dev/src/quicktemplates/qquickrangeslider.cpp),
[qaccessiblequickitem.cpp](https://github.com/qt/qtdeclarative/blob/dev/src/quick/accessible/qaccessiblequickitem.cpp).

**Qt Widgets.** No two-thumb widget. QxtSpanSlider and superqt's
QRangeSlider are one QSlider subclass that calls
`QStyle::drawComplexControl(CC_Slider)` once per handle, so the handles are
native-style pixels in one custom widget. superqt paid for it: style sheets
kill the second handle ([#201](https://github.com/pyapp-kit/superqt/issues/201),
[#58](https://github.com/pyapp-kit/superqt/issues/58)), a macOS drag patch,
the upper handle ungrabbable at 0 ([#150](https://github.com/pyapp-kit/superqt/issues/150)),
no keyboard ([#313](https://github.com/pyapp-kit/superqt/issues/313)), and
the maintainer calls the QSlider inheritance "very ugly hacks"
([#249](https://github.com/pyapp-kit/superqt/issues/249)).

**Jetpack Compose material3.** One `Layout` with start thumb, end thumb and
track slots; one `pointerInput` on the whole Layout owns every press, so
z-order plays no part. Nearest thumb at press-down. Tie: by drag direction
until androidx commit
[d6ee1715](https://github.com/androidx/androidx/commit/d6ee1715ed20f18ab7ca173669338174948abfbf)
(2025-07-24, b/399393886), since then by which side of the stacked thumbs
the press lands. Stop. Two semantics nodes, `progressSemantics` plus
`setProgress`, each advertising the range bounded by the other thumb, named
"Range start"/"Range end" from compose-ui's strings. Keyboard was broken
until 2025-08. `VerticalSlider` exists for one thumb only; no vertical
range. Source:
[Slider.kt](https://github.com/androidx/androidx/blob/androidx-main/compose/material3/material3/src/commonMain/kotlin/androidx/compose/material3/Slider.kt).

**Material Components (Views).** `BaseSlider extends View` draws N thumbs.
`pickActiveThumb` takes the nearest value; at a tie it defers to the first
move and picks by direction. Stop with `minSeparation`. Accessibility:
`ExploreByTouchHelper` virtual views with class `SeekBar` and
`RangeInfo` over the whole range, "Range start"/"Range end". Tab moves
between thumbs inside the one View. Vertical since 2024-11. Source:
[BaseSlider.java](https://github.com/material-components/material-components-android/blob/master/lib/java/com/google/android/material/slider/BaseSlider.java).

**React Native.** `@react-native-community/slider` wraps the native slider
and has never had a range ([#269](https://github.com/callstack/react-native-slider/issues/269)).
The one recorded attempt to stack two native RN sliders,
[multi-slider #76](https://github.com/ptomasroos/react-native-multi-slider/issues/76)
(2018), reported "not being able to slide the one underneath. And preventing
overlap is another" and "on press down, it should grab the slider that the
press it is closest to ... tried for about a day"; it was abandoned.
multi-slider's own z-order hack still traps overlapping thumbs
([#280](https://github.com/ptomasroos/react-native-multi-slider/issues/280), open)
and its thumbs cannot be adjusted by TalkBack
([#218](https://github.com/ptomasroos/react-native-multi-slider/issues/218)).
Only @sharcoux/slider exposes two `adjustable` thumbs.

**Windows Community Toolkit `RangeSelector`** (and Uno, which ships it).
Two `Thumb` template parts on a Canvas. A track press goes to the nearer
thumb, ties to Min, which can strand both thumbs at the minimum. No
automation peer: Narrator hears "Min thumb, thumb" and no value, open since
2020 ([#3538](https://github.com/CommunityToolkit/WindowsCommunityToolkit/issues/3538)).
Arrows only. Vertical since 2026-02-10
([PR #756](https://github.com/CommunityToolkit/Windows/pull/756)). Source:
[components/RangeSelector/src](https://github.com/CommunityToolkit/Windows/tree/main/components/RangeSelector/src).
Microsoft declined a WinUI range control as a gallery sample: "Current
slider cannot cover this scenario"
([microsoft-ui-xaml #9919](https://github.com/microsoft/microsoft-ui-xaml/issues/9919)).

**UIA.** The RangeValue pattern holds one value
([docs](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-implementingrangevalue)),
and the Slider control type expects one Thumb child and focus kept on the
slider itself
([docs](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-supportslidercontroltype)).
So the conformant UIA shape for two values is two Slider elements, which is
what two stacked WinUI `Slider`s give without extra code.

**WPF Xceed `RangeSlider`: the one shipping desktop control built by
stacking stock sliders.** Two `Slider` template parts in one Grid cell, each
re-templated to a bare `Track` holding only a `Thumb`, so only the thumb
hit-tests. The parent draws the track with three RepeatButtons. Ticks come
from a THIRD hidden `Slider` kept only for its TickBar. The two sliders are
offset by one thumb width with margins, so their thumbs can never overlap:
at equal values they sit side by side, and the track is two thumbs shorter
than the control. A dragged value past the other thumb is clamped and
written back into the slider. Accessibility comes free from the two stock
`SliderAutomationPeer`s, but they are unnamed, and the tick slider probably
adds a third peer (inferred). Source:
[RangeSlider.cs](https://github.com/xceedsoftware/wpftoolkit/blob/master/ExtendedWPFToolkitSolution/Src/Xceed.Wpf.Toolkit/RangeSlider/Implementation/RangeSlider.cs),
Generic.xaml beside it.

**WPF MahApps.** Thumbs laid out in a row, never overlapping. Since
2026-09-15 a `RangeSliderAutomationPeer` exposes one Slider with two Thumb
children implementing RangeValue; its own comment: "A range slider holds two
values, and no automation pattern holds two."
[RangeSliderAutomationPeer.cs](https://github.com/MahApps/MahApps.Metro/blob/develop/src/MahApps.Metro/Automation/Peers/RangeSliderAutomationPeer.cs).

**Avalonia and MAUI.** No first-party control
([Avalonia #20355](https://github.com/AvaloniaUI/Avalonia/issues/20355),
[CommunityToolkit.Maui #115](https://github.com/CommunityToolkit/Maui/issues/115),
"The lack of activity hints that it won't be done"). Third-party ones are
drawn or templated with no accessibility; Syncfusion's own table marks
screen reader and keyboard unsupported
([overview](https://help.syncfusion.com/maui/range-slider/overview)). No
MAUI library found stacks native sliders per platform.

**UIKit and SwiftUI.** No first-party control
([UISlider](https://developer.apple.com/documentation/uikit/uislider) "a
single value"). Every popular library is one drawn control. TTRangeSlider
and its Swift port RangeSeekSlider are the only ones with two
`.adjustable` `UIAccessibilityElement`s, and their increment path skips the
no-crossing guard the touch path has (read, not run). WARangeSlider's
first-hit routing locks when the thumbs meet
([#1](https://github.com/warchimede/RangeSlider/issues/1), open since 2015).
No library stacks two `UISlider`s; the one repo found puts two sliders one
above the other on separate tracks. Apple's Photos trimmer gives VoiceOver
separate Start and End elements adjusted by swipe
([iPhone guide](https://support.apple.com/guide/iphone/use-voiceover-in-apps-iphe4ee74be8/ios)),
and users complain each swipe moves only a few frames
([AppleVis](https://www.applevis.com/forum/ios-ipados/submitted-feedback-voiceover-trimming-accessibility-issues-iphone-photos-app),
read as a search snippet only).

**AppKit.** No first-party control. SMDoubleSlider shares ONE
`NSSliderCell` between two knobs by writing the lo value into the cell's
private `_value` ivar before calling the native `drawKnob:` and
`startTrackingAt:`. It has no accessibility code
([SMDoubleSliderCell.m](https://github.com/jjk/SMDoubleSlider/blob/master/Framework_code/SMDoubleSliderCell.m)).
How Final Cut, Logic or Photos for Mac expose their ranges was not found.

**GTK 4 and GNOME.** `GtkRange` shows one `GtkAdjustment` with one slider
gizmo, and `GtkAccessibleRange` holds one value
([gtkrange.c](https://github.com/GNOME/gtk/blob/main/gtk/gtkrange.c)). No
GTK issue asks for a two-handle scale; libadwaita has none. A primary click
in a scale's trough WARPS its slider there (`gtk-primary-button-warps-slider`),
so the top scale of a stack takes every trough click unless the container
routes presses. Video Trimmer draws a timeline with no thumbs and no
accessibility, and puts Start and End text entries beside it, plus `i`/`o`
keys ([timeline.rs](https://gitlab.gnome.org/YaLTeR/video-trimmer/-/blob/master/src/timeline.rs)).
GIMP's Levels handle bar and darktable's range selector are also drawn and
inaccessible, each paired with spin buttons or entries. No GTK app was found
stacking two `GtkScale`s.

**egui.** A first-party `RangeSlider` landed 2026-09-17
([PR #8580](https://github.com/emilk/egui/pull/8580)); emilk had said a
two-handle slider is "its own widget type" because "the mouse/touch
interaction is wildly different"
([#2744](https://github.com/emilk/egui/issues/2744)). One drawn widget takes
the pointer; two extra focus-only rects give each handle a Tab stop and an
AccessKit slider node whose min and max are bounded by the other handle,
named "low"/"high". Tie by press side, locked for the gesture: "When the
handles coincide, the side the pointer is on decides, or a collapsed range
could only ever be opened in one direction." Source:
[range_slider.rs](https://github.com/emilk/egui/blob/main/crates/egui/src/widgets/range_slider.rs).

**Slint, iced, wxWidgets.** None. wxWidgets' `wxSL_SELRANGE` draws a
highlighted selection on one thumb's track (Windows only).

**The web.** No native two-thumb input: `<input type=range multiple>` was
removed from HTML in 2016 for lack of implementers
([whatwg/html #1520](https://github.com/whatwg/html/issues/1520)). The ARIA
APG
[multi-thumb slider](https://www.w3.org/WAI/ARIA/apg/patterns/slider-multithumb/)
is one `role=slider` per thumb, each thumb's min or max set to the other
thumb's value, each a Tab stop. The Open UI
[enhanced range input](https://open-ui.org/components/enhanced-range-input.explainer/)
proposal wraps one real `<input type=range>` per thumb in a `<rangegroup>`
drawn on one track, and leaves the tie ("disambiguating via drag
direction") open. Material Web ships the stacked design: two full-width
native inputs, each CLIPPED at the midpoint between the two values so a
press goes to the nearer thumb by geometry rather than z-order, a drawn
track, handles and ticks, a JavaScript clamp, `aria-valuemin`/`max`
overridden to the other thumb, and a "flip" that hands the drag to the other
input when both start equal
([slider.ts](https://github.com/material-components/material-web/blob/main/slider/internal/slider.ts),
[_slider.scss](https://github.com/material-components/material-web/blob/main/slider/internal/_slider.scss)).
Its problems: resizing the hidden native thumb broke iOS dragging
([#5016](https://github.com/material-components/material-web/issues/5016)),
and an intermittent undraggable state on Chromium/Windows
([#5108](https://github.com/material-components/material-web/issues/5108), open).
The maintainers moved to native inputs because the older ARIA-div slider
could not be adjusted by touch screen readers
([#1285](https://github.com/material-components/material-web/issues/1285));
MUI made the same move for the same reason
([#23506](https://github.com/mui/material-ui/issues/23506)), as did React
Aria (a hidden native input inside each drawn thumb,
[useSliderThumb.ts](https://github.com/adobe/react-spectrum/blob/main/packages/react-aria/src/slider/useSliderThumb.ts)).
React Aria's thumbs still stick at [max, max] because the later thumb is on
top ([#3387](https://github.com/adobe/react-spectrum/issues/3387),
[#6408](https://github.com/adobe/react-spectrum/issues/6408), open).
MUI [#45577](https://github.com/mui/material-ui/issues/45577) is a video-trim
case where nearest-thumb routing is wrong. Browsers map a native range input
to UIA Slider + RangeValue, AT-SPI slider + Value and AXSlider
([Core-AAM](https://w3c.github.io/core-aam/)), so a native input per thumb
is one platform slider per thumb on every desktop.

## Counts

Of the implementations read (first-party, third-party and apps):

- **Stack two native sliders over one track, shipping: 2.** Material Web
  (two native `<input type=range>`) and Xceed's WPF RangeSlider (two stock
  WPF `Slider`s). Plus the Open UI proposal (one native input per thumb,
  not shipped), the CSS-Tricks-style tutorials, and one abandoned attempt
  (React Native multi-slider #76).
- **Drawn thumbs with a hidden native slider per thumb for keyboard and
  accessibility only: 3.** React Aria/Spectrum, MUI, Spectrum Web
  Components.
- **One widget painting native-style handles: 3.** QxtSpanSlider, superqt,
  SMDoubleSlider.
- **One drawn or templated control: about 32.** Flutter, Qt Quick, Compose
  material3, Material Components Views, Toolkit RangeSelector, MahApps,
  Ursa, Avalonia.RangeSlider, PanRangeSlider, halkar Xamarin, egui,
  egui_double_slider, Druid, ControlsFX, Radix, noUiSlider, Web Awesome,
  four React Native libraries, seven iOS/SwiftUI libraries, Video Trimmer,
  GIMP, darktable.
- **Two stock widgets side by side, not over one track: 1.** Dear ImGui.

## What this says about kaya's §8 ruling 1 (stack two native sliders vs draw the control)

**Stacking is rare.** Every toolkit that owns its rendering (Flutter, Qt
Quick, Compose, egui, the Material Views library) draws one control, and
their authors said why: emilk calls the interaction "wildly different" from
a slider's, and the Qt Widgets hybrids that tried to reuse the native slider
regret it (superqt #249). The two shipping stacked controls are Material
Web and Xceed WPF. So kaya's §6 line "the stacked pair is the web's answer
to the same absence" is half true: stacking is the web's common hack and
one production library's design, while most serious web libraries draw the
pointer side and keep a native input per thumb for keyboard and
accessibility only.

**The accessibility argument holds up.** Of the ~32 drawn controls, only
seven give each thumb an adjustable element (Flutter, Compose, Material
Views, egui, TTRangeSlider/RangeSeekSlider, @sharcoux, MahApps since two
weeks ago). The rest ship with nothing (Qt Quick's one element with no
value, the Toolkit RangeSelector's value-less thumbs open since 2020,
Syncfusion's "unsupported", nearly every iOS library). That is the tax §8
names, measured: most teams that drew the control did not pay it. The web
went the other way for exactly this reason: Material Web, MUI and React
Aria moved to native inputs because touch screen readers could not adjust a
drawn thumb. Every reference (APG, Open UI, Photos' trimmer, egui, Compose)
agrees on two adjustable elements, one per thumb, and UIA's Slider rules make
two Slider elements the conformant shape on Windows. Stacking gets that
shape, the platform's keys (GTK and WPF Sliders give Home, End and Page keys
free) and the platform's slider role on every desktop.

**But stacking does not avoid owning the pointer.** Every stacked or
native-per-thumb build ended up routing presses itself: Material Web by
clipping each input at the midpoint, Xceed by stripping each slider to its
thumb and offsetting them, the tutorials with a JavaScript z-index swap, and
React Aria and MUI by giving the pointer to drawn thumbs entirely. On GTK a
scale warps to any trough click, so the plan's `contains` override (or
`can-target` false plus a parent gesture) is required, not optional. The
hit-routing failures are the most reported bugs in this whole survey (RN
#76, WARangeSlider #1, superqt #150, React Aria #3387 and #6408,
multi-slider #280). §4.2 is right to call routing "the one hard part"; the
evidence says it is where most two-thumb controls break, stacked or drawn.
The proven fix is geometric: split the track at the midpoint between the
thumbs, as Material Web does, so no press ever depends on z-order.

**Evidence against parts of the current plan:**

1. **The tie rule in §3.4 cites a rule Compose has since dropped.** "When
   they meet, the drag's direction picks (Material's `captureThumb`)" is
   material3 1.3.x behaviour; androidx changed it to press side in
   2025-07. Drag direction also fits stacking badly: a native slider starts
   tracking on press-down (UISlider `beginTracking`, NSSlider's cell
   tracking, GtkScale's gesture), before any direction exists. Material
   Web had to "flip" after the fact, writing the value into the other input,
   resetting the pressed one and moving focus. Press side (egui, Compose
   main, rn-range-slider, @sharcoux, MultiSlider) is decided at press time,
   which is when a container `hitTest` runs. The cost: kaya's Compose arm
   at the 1.3.1 pin would still pick by drag direction, and kaya cannot
   change RangeSlider's internal pointer code, so one of the two rules
   diverges on Android until the BOM moves. This needs a decision.
2. **Each native slider reports the whole range.** APG, Compose, egui,
   React Aria, noUiSlider and Material Web (by override) report each
   thumb's min or max as the other thumb's value. A stacked native slider
   maps its min and max to its pixel width, so narrowing them moves the
   thumb. Either kaya accepts whole-range reporting (as Material Views,
   MUI, Radix and Web Awesome do; a reader then hears "0 to 10" and the
   value stops at the other thumb), or it overrides the reported bounds per
   platform (an `accessibilityMinValue` override on AppKit, a custom peer on
   WinUI; on GTK, whether a manual `VALUE_MIN` survives GtkRange's own
   updates is unverified). §3 rule 7 should say which.
3. **The assistive path must clamp too.** A native slider accepts an
   assistive set past the other thumb. TTRangeSlider and RangeSeekSlider
   guard the touch path and not the accessibility path, so VoiceOver can
   cross them (read, not run). Xceed clamps and writes the value back into
   the slider. kaya's one clamp function must run on every native slider's
   value-changed path, the assistive one included, and write back.
4. **Hiding native parts is fragile.** Material Web broke iOS dragging by
   resizing the hidden native thumb (#5016). superqt broke under style
   sheets. §6 hides tracks (empty track images, a `drawBar` that draws
   nothing, a CSS class on the trough, template parts by name), which is
   the lighter touch; resizing or restyling the thumbs should stay off the
   table.
5. **Ticks and geometry.** Xceed kept a third hidden slider only for ticks,
   and Shoelace notes that a native thumb's real coordinates cannot be read.
   §4.2 already measures "that kaya's track meets the thumbs' centres"; the
   ticks need the same measurement, and each stacked slider's own ticks must
   be off so they are drawn once.
6. **Overlap at equal values.** Xceed and PanRangeSlider avoid ties by
   offsetting the thumbs a thumb width apart; kaya's `min_gap` in value units
   does not do that at `min_gap 0`. With coincident thumbs, the stacked
   native thumbs sit exactly on top of each other and the thumb drawn on top
   covers the other, which Flutter, Material Web and Compose answer with an
   outline on the top thumb. The plan does not mention it.
7. **For a trim control specifically**, the reference apps suggest the
   accessible path is as much about precision as about thumbs: Photos users
   find per-swipe steps too small for long videos, and Video Trimmer, GIMP
   and darktable all give text or spin fields beside the drawn range. The
   thumbs' assistive step size is worth a sentence in §3.

**Weighing it.** The evidence supports the plan's reason for stacking,
accessibility and keys for free in the platform's own shape, better than it
supports the plan's claim that stacking is what others do: almost nobody
stacks, and the ones who do own the pointer anyway. A fair statement of the
choice is: stack for keyboard and accessibility, and let a kaya container
own the press routing on all four platforms by geometry (the midpoint split),
deciding a tie by press side at press time. Drawing the whole control is
what the large toolkits did, and the survey shows it costs two hand-made
accessibility elements per platform that most teams never finished. React
Aria's middle path (drawn thumbs, an invisible native slider per thumb for
keyboard and assistive technology) is the third option the plan does not
name; on the native platforms it would still need kaya to keep an invisible
slider's frame over each drawn thumb, so it does not look cheaper than
stacking with hidden tracks. If §4.2's measurements fail on one platform,
that is the fallback to try before drawing everything.
