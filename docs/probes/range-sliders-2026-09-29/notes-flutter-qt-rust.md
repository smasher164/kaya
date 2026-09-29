# Range controls: Flutter, Qt, Rust toolkits and others

Every claim below cites a source I read. Where I did not read the code, the line says "unverified".

## Flutter, Material RangeSlider

Sources read:
- F1 = https://raw.githubusercontent.com/flutter/flutter/master/packages/flutter/lib/src/material/range_slider.dart (the in-SDK copy)
- F2 = https://raw.githubusercontent.com/flutter/packages/main/packages/material_ui/lib/src/range_slider.dart (Material has been split out into the `material_ui` package in flutter/packages. This copy is newer and has keyboard support.)
- Engine: https://raw.githubusercontent.com/flutter/flutter/master/engine/src/flutter/shell/platform/darwin/ios/framework/Source/SemanticsObject.mm and https://raw.githubusercontent.com/flutter/flutter/master/engine/src/flutter/shell/platform/android/io/flutter/view/AccessibilityBridge.java

- (a) Yes, first-party: `RangeSlider`, with `RangeValues` start/end (F1).
- (b) BUILT AS ONE CUSTOM-DRAWN CONTROL that owns both thumbs. `_RenderRangeSlider` is a single RenderBox. It paints the track, the tick marks and both thumbs (`rangeThumbShape.paint` is called twice, once for a bottom thumb and once for a top thumb). It performs its own hit test and drag (F1, `paint`, lines ~1519-1850). The build method puts two invisible zero-size `Focus` widgets (`startFocusNode`, `endFocusNode`) in a `Stack` next to the render object. These give each thumb its own keyboard focus stop (F1 ~784: "Adds two invisible focus nodes to the range slider for its two thumbs").
- (c) Routing is done by a replaceable `RangeThumbSelector` (`SliderThemeData.thumbSelector`). The default is `_defaultRangeThumbSelector` (F1 ~603-646):
  - When only one thumb's touch target (at least 48dp wide) contains the press, or neither does, the thumb whose side of the MIDPOINT the press falls on wins: `tapValue*2 < start+end` selects start.
  - When both thumbs' touch targets contain the press (the thumbs overlap or sit close), NO thumb is picked on pointer-down. The first non-zero horizontal drag delta decides: a negative dx picks start and a positive dx picks end. The mapping is mirrored for RTL. So the tie is broken by DRAG DIRECTION.
  - A tap with zero displacement in that ambiguous zone selects nothing, so nothing moves (`_startInteraction` only acts when the selection is non-null).
  - Z-order: the thumb selected last (`_lastThumbSelection`) is painted on top. The other thumb is drawn first as the "bottom" thumb. `isOnTop` is passed to the thumb shape when the thumbs are closer than one thumb width, so the shape can outline the top thumb (F1 ~1704-1714, ~1836).
  - Pointer-down also moves focus to the selected thumb's focus node.
- (d) The thumbs STOP. They do not cross and do not push. During a drag, start is clamped to `min(drag, end - minThumbSeparation)` and end to `max(drag, start + minThumbSeparation)` (F1 ~1415-1426). `minThumbSeparation` is a theme value, and it is 0 for discrete sliders. Semantic increase and decrease stop at the other thumb in the same way (`_increasedStartValue` returns the unchanged start when a step would pass the separation) (F1 ~1990-2020).
- (e) Accessibility exposes TWO ADJUSTABLE ELEMENTS:
  - `assembleSemanticsNode` builds two child `SemanticsNode`s, one per thumb. Each has `isSlider`, `isFocusable`, `isFocused` (from its focus node), `onIncrease`/`onDecrease`, `value`, `increasedValue` and `decreasedValue`. The rect of each is a 48x48 box centred on its thumb, with left and right swapped for RTL (F1 ~1895-1950).
  - Each node's value string is `semanticFormatterCallback(value)`, or by default a PERCENT like "40%".
  - NO LABEL is set on either thumb, so there is no default "start"/"end" or "minimum"/"maximum" name. The only per-thumb text on the widget is `RangeLabels`, which feeds the painted value indicator and not the semantics. I found no `config.label` in F1 or F2 (grep).
  - The step is 1/divisions, or else 0.05 (Android and desktop) or 0.1 (iOS) (F1 `_adjustmentUnit`).
  - Platform mapping (engine source): on iOS a node with increase or decrease actions gets `UIAccessibilityTraitAdjustable` (SemanticsObject.mm ~890), so VoiceOver swipe-up/down adjusts each thumb separately. On Android every semantics node is a virtual view of Flutter's AccessibilityNodeProvider with class `android.view.View`. `ACTION_SCROLL_FORWARD`/`BACKWARD` is mapped to INCREASE/DECREASE (AccessibilityBridge.java ~839, ~982-994). I found no `setRangeInfo` in that file. So TalkBack can adjust each thumb through the scroll actions, but it does not get a SeekBar class or a RangeInfo from Flutter. The web mapping (role=slider) is unverified; I did not read the web engine.
- (f) Keyboard:
  - F1, the SDK copy: two focus stops (Tab moves between the thumbs) but NO key handling. I found no `LogicalKeyboardKey` in the file. The open PR to add it is https://github.com/flutter/flutter/pull/181525 ("Add keyboard support for RangeSlider", state open when read), which fixes #179638. The earlier PR is https://github.com/flutter/flutter/pull/161154.
  - F2, material_ui: each thumb's focus node has its own Shortcuts/Actions. In traditional navigation the Up/Right arrows increase and Down/Left decrease that thumb, and Left/Right follow RTL. In `NavigationMode.directional` (TV-style), Enter toggles an adjust mode (F2 ~500-530, ~679-695; issue https://github.com/flutter/flutter/issues/181968).
  - F2 has no Home/End/PageUp/PageDown; grep found none.
  - There is a bug about hover stealing focus from a thumb: https://github.com/flutter/flutter/issues/173574.
- (g) There is NO VERTICAL orientation. All geometry is `dx` and track width, and the widget has no axis parameter (F1). This is part of the umbrella issue https://github.com/flutter/flutter/issues/125329 (rework of Slider/RangeSlider). The umbrella issue itself is unverified in detail.
- Stacking: not applicable. The two thumbs are drawn in one render object, and the only "stacked" parts are the two invisible focus widgets.

## Qt Quick Controls RangeSlider

Sources read:
- Q1 = https://raw.githubusercontent.com/qt/qtdeclarative/dev/src/quicktemplates/qquickrangeslider.cpp (dev branch)
- Q2 = https://raw.githubusercontent.com/qt/qtdeclarative/dev/src/quickcontrols/basic/RangeSlider.qml (Basic style)
- Q3 = https://raw.githubusercontent.com/qt/qtdeclarative/dev/src/quick/accessible/qaccessiblequickitem.cpp

- (a) Yes, first-party: `RangeSlider` (QtQuick.Controls). It has `first` and `second` sub-objects of type `QQuickRangeSliderNode`, each with value, position, handle, pressed, hovered, increase() and decrease() (Q1).
- (b) BUILT AS TWO THUMB PARTS TEMPLATED INSIDE ONE CONTROL. `first.handle` and `second.handle` are delegates, which in the Basic style are two `Rectangle` items. The `background` delegate draws the track and its fill (Q2). The template reparents each handle into the control and marks it `setActiveFocusOnTab(true)` (Q1 ~255-270). All input is handled by the one control: `handlePress`, `handleMove` and `handleRelease` on the RangeSlider. Each handle is a visual item used for hit tests, focus and z. It is NOT a nested Slider. There is no stacking of two stock sliders.
- (c) Routing, from `QQuickRangeSliderPrivate::handlePress` (Q1 ~505-575):
  - If the press is inside exactly one handle's shape, that handle wins.
  - If the press is inside BOTH handles, the one with the HIGHER z wins. The pressed handle is set to z=1 and the other to z=0, so the last-pressed handle stays on top and wins the next overlapping press.
  - If the press is inside neither handle, the handle NEAREST by position wins. On an exact tie, it picks the handle that can move TOWARD the press: first if the press is below first's position (with `from > to` inversion taken into account), otherwise second.
  - The press also gives the chosen handle active focus when `focusPolicy & Qt::ClickFocus`.
  - Before any press, `updateFocusOrder` stacks second above first (`secondHandle->setZ(firstHandle->z()+1)`) (Q1 ~935-958).
  - Hover follows the same higher-z rule when handles overlap (Q1 ~640-656).
  - Multi-touch: each node keeps a `touchId`, so two fingers can drag the two handles at the same time (`acceptTouch`, `pressedNode(touchId)`, Q1 ~447-505). There is a `touchDragThreshold` property.
- (d) By default the handles STOP: `setPosition` bounds first to [0, second.position] and second to [first.position, 1], and `setValue` clamps the same way (Q1 ~100-122, ~172-210). `setValues(a,b)` clamps a to b when they cross (Q1 ~1256-1300). NEW in Qt 6.12, `crossingEnabled` (default false) lets them CROSS: `handlesCrossed` tracks the swap, `effectiveFirstValue`/`effectiveSecondValue` report the lower and upper value, focus order is re-stacked, and turning crossing off swaps the values back (Q1 ~836-915, doc blocks marked `\since QtQuick.Controls 6.12`). There is NO push mode.
- (e) Accessibility is ONE ELEMENT, and in practice its value is empty:
  - `QQuickRangeSlider::accessibleRole()` returns `QAccessible::Slider` for the whole control (Q1 ~1606-1610).
  - The generic Quick accessibility layer gives a Slider-role item a value interface whose `currentValue()` is `item()->property("value")`, and whose min and max come from `from`/`to` (Q3 ~731-790).
  - RangeSlider has NO `value` property (only `first.value` and `second.value`), so by that code the reported current value is an invalid QVariant. Setting a value through assistive technology (`setProperty("value")`) would do nothing.
  - The Basic-style handles are plain Rectangles with no `Accessible` role (Q2), so they are not separate accessible objects.
  - Conclusion, INFERRED from the source and not tested with a screen reader: Narrator/Orca/VoiceOver see one slider with a range and no current value, and cannot adjust each handle through the accessibility API. They can adjust each handle only through keyboard focus (below).
  - I found no QTBUG specifically for this in a quick search, so a tracker entry is unverified.
  - An app can attach `Accessible.role: Accessible.Slider` etc. to each handle delegate itself. That is not done in the stock styles I read (Basic only; other styles unverified).
- (f) Keyboard (Q1 ~1375-1435):
  - Each handle is its own Tab stop (`setActiveFocusOnTab(true)`), and `updateFocusOrder` keeps first before second in the chain. When the control itself gets focus it forwards focus to the first handle, or to the second when the handles are crossed.
  - `keyPressEvent` acts only on the handle with active focus. Horizontal: Left/Right call decrease/increase, swapped when mirrored. Vertical: Up/Down. Each step is `stepSize`, or when stepSize is 0 an absolute 0.1 in VALUE units, not 0.1 of the range (`QQuickRangeSliderNode::increase`, Q1 ~329-341).
  - NO Home/End/PageUp/PageDown.
- (g) Vertical is supported: `orientation` is Horizontal or Vertical. In vertical, first is at the BOTTOM ("bottommost in vertical orientation"), and `visualPosition` inverts (Q1 ~231, ~973-997, ~1224-1253).

## Qt Widgets: no first-party control; QxtSpanSlider (libqxt) and superqt QRangeSlider

Qt Widgets has no two-thumb slider. QSlider has one handle. Both third-party widgets below are the HYBRID the charge asked about. Each is ONE QSlider subclass that asks the platform STYLE to draw the groove, the ticks and each handle (`QStyle::drawComplexControl(CC_Slider, QStyleOptionSlider)`, once per handle, with `opt.sliderPosition` set to that handle's position). Each also uses the style's own `subControlRect`/`hitTestComplexControl` for geometry. So the handles are native-styled pixels, while the widget, its input handling and its focus are custom and single. Neither stacks two QSlider widgets.

### QxtSpanSlider (libqxt)
Sources:
- X1 = https://raw.githubusercontent.com/mnutt/libqxt/master/src/gui/qxtspanslider.cpp (a mirror of libqxt; the original was on bitbucket)
- X2 = https://raw.githubusercontent.com/mnutt/libqxt/master/src/gui/qxtspanslider.h

- (a) Third-party: `QxtSpanSlider`, `class QxtSpanSlider : public QSlider` (X2 l.34), with `lowerValue` and `upperValue`.
- (b) HYBRID, one widget drawn with QStyle. `paintEvent` works in steps (X1 ~700-744):
  - It draws the groove and the tick marks ONCE with the style (`SC_SliderGroove | SC_SliderTickmarks`, sliderPosition 0).
  - It computes both handle rects with `subControlRect(SC_SliderHandle)`.
  - It paints its OWN span bar between them with a Highlight gradient (`drawSpan`).
  - It then calls `drawComplexControl(CC_Slider)` with `subControls = SC_SliderHandle` once per handle (`drawHandle` ~143-155), adding `State_Sunken` for the pressed handle.
  - The tick marks therefore come from the style and are drawn once.
  - The docs admit the subclassing is "for implementation specific reasons", and warn that the single-handle QSlider properties do not apply (X1 ~318-340).
- (c) Routing (X1 `mousePressEvent` ~590-600, `handleMousePress` ~85-102):
  - It hit-tests the UPPER handle first with the style's `hitTestComplexControl`, and tries the lower handle only if the upper missed. So on overlap the UPPER handle wins the press.
  - A press on the groove outside both handles does nothing: no page step, no jump.
  - Tie-break when lower == upper: on the FIRST movement of a drag, if the drag goes below lowerValue the controls SWAP, so the drag moves the lower handle (`firstMovement`, X1 ~625-640). This is tie-breaking by drag direction, like Flutter's.
  - Z-order: `paintEvent` draws the last-pressed handle on top (X1 ~730-744).
- (d) Configurable by `HandleMovementMode` (X2 l.52-54, X1 ~344-346, ~645-680):
  - `FreeMovement`, the default (X1 ~44), lets them CROSS: the lower/upper ROLES SWAP (`swapControls`), so lower stays lower.
  - `NoCrossing` STOPS them, and equal values are allowed.
  - `NoOverlapping` stops them one unit apart.
  - There is no push mode.
- (e) Accessibility: I found no accessibility code in X1. As a QSlider subclass it gets Qt's stock `QAccessibleSlider`, ONE element, whose value is `QAbstractSlider::value()`. QxtSpanSlider keeps lower and upper in its own private fields, and the base value only moves as a side effect of `QSlider::keyPressEvent` (below). So the value a screen reader hears is unrelated to either handle. This is INFERRED from X1 and Qt's QSlider accessibility; I did not run it or read Qt's `QAccessibleSlider` for this note.
- (f) Keyboard: ONE focus stop, with no Tab between handles. `keyPressEvent` binds keys to handles by AXIS, not by focus (X1 table ~298-310, code ~546-588):
  - Horizontal: Left/Right move the lower handle and Up/Down move the upper handle.
  - Vertical: Up/Down move the lower handle and Left/Right move the upper handle.
  - Home moves the lower handle to the minimum and End moves the upper handle to the maximum.
  - No PageUp/PageDown.
  - It ALSO calls `QSlider::keyPressEvent` first, which moves the hidden base value.
- (g) Vertical is supported (QSlider orientation, `pick()` per axis).

### superqt QRangeSlider (pyapp-kit/superqt, used by napari)
Sources:
- S1 = https://raw.githubusercontent.com/pyapp-kit/superqt/main/src/superqt/sliders/_generic_range_slider.py
- S2 = https://raw.githubusercontent.com/pyapp-kit/superqt/main/src/superqt/sliders/_generic_slider.py
- S3 = https://raw.githubusercontent.com/pyapp-kit/superqt/main/src/superqt/sliders/_sliders.py

- (a) Third-party: `QRangeSlider` and `QDoubleRangeSlider`, plus labeled variants. It supports N handles: `value()` is a tuple (S3, S1 ~21-40).
- (b) HYBRID, the same as Qt's own QSlider drawing path. `_GenericSlider(QSlider)` re-implements QSlider's logic in Python (S2 l.62). `_draw_handle` draws its own "bar" (`_drawBar`, a pen and brush rect between the first and last handle centres, S1 ~277-310). It then loops over the handles, calling `painter.drawComplexControl(CC_SLIDER, opt)` with `subControls = SC_HANDLE` and `opt.sliderPosition` set to each position (S1 ~311-326). The groove and ticks are drawn once by the style (`_draw_groove_and_ticks`, S2 ~392-420). Handle rects come from the style's `subControlRect` (S1 `_handleRect`).
  - Problems this hybrid hit: style sheets and themes break the second handle and the bar. Issue #201 says "the custom stylesheet is killing the paintEvent drawing the second handle", and the workaround is `background:none` (https://github.com/pyapp-kit/superqt/issues/201). A qdarkstyle global sheet breaks the drawing (https://github.com/pyapp-kit/superqt/issues/58). macOS 12 with Qt5 needs a QSS patch because sliders do not drag properly (`applyMacStylePatch`, S1 ~113-120). Tick marks are drawn by hand under that patch because "they are badly behaved with style sheets" (S2 ~404-420). The maintainer calls the QSlider inheritance "very ugly hacks" and proposes rebasing on QWidget (https://github.com/pyapp-kit/superqt/issues/249, open).
- (c) Routing (`_getControlAtPos`, S1 ~347-372):
  - The FIRST handle in index order whose style rect contains the press wins. So on overlap the LOWER handle always wins.
  - Otherwise: a press below the lowest handle takes handle 0, and a press above the highest takes the last handle.
  - A press between two handles grabs the whole BAR by default (`barMovesAllHandles`, which drags the range, rigid by default). With that option off, the handle nearer by midpoint wins.
  - There is no drag-direction tie-break. Bug https://github.com/pyapp-kit/superqt/issues/150 (open): when both handles are at 0 the upper handle cannot be grabbed, because the lower one always wins the hit test. The maintainer's workaround is to click to the right of it.
- (d) STOP, with a minimum gap of one `singleStep` (`_neighbor_bound`, S1 ~229-238), so dragging keeps them at least a step apart. Handles can still be set equal programmatically (issue #150). No crossing and no push, except that dragging the bar moves all handles.
- (e) Accessibility: I found no accessibility code in S1 or S2. As a QSlider subclass it gets Qt's single `QAccessibleSlider`, whose value comes from the C++ `QAbstractSlider::value()`, which superqt does not keep in sync (it stores `_value` in Python; S2 ~69-80). So there is one element with a wrong or stale value. This is INFERRED and not run.
- (f) Keyboard: effectively NONE for the range handles. `keyPressEvent` is commented out as a TODO (S2 ~523-524). Issue https://github.com/pyapp-kit/superqt/issues/313 reports no key events at all on the range slider, and was closed without a fix that I could see.
- (g) Vertical is supported. `_barRect` and `_handleRect` branch on `opt.orientation` (S1 ~277-300).

## egui: first-party `RangeSlider` (NEW, added 2026-09-17), and the community `egui_double_slider`

### egui::RangeSlider
Sources:
- E1 = https://raw.githubusercontent.com/emilk/egui/main/crates/egui/src/widgets/range_slider.rs
- E2 = https://raw.githubusercontent.com/emilk/egui/main/crates/egui/src/widgets/slider_core.rs
- It was added by PR #8580, "Add RangeSlider, a two-handled slider sharing Slider's core" (commit 14a010bda7, 2026-09-17: https://github.com/emilk/egui/pull/8580). It was touched again by #8555 (WidgetType replaced by accesskit::Role). The older feature request is https://github.com/emilk/egui/issues/2744, where emilk said a two-handle slider differs enough from Slider to be "its own widget type" because "the mouse/touch interaction is wildly different".
- As far as I can tell it is not in a released egui version yet (unverified).

- (a) Yes: `egui::RangeSlider::new(&mut low, &mut high, range)` (E1 l.20-60).
- (b) ONE CUSTOM-DRAWN WIDGET owning both handles. It shares `slider_core` with `Slider` for rail geometry, painting the rail, fill and handles, and the keyboard and AccessKit helpers.
  - One `allocate_response(.., Sense::DRAG)` covers the whole rail and takes all pointer input.
  - It then adds two EXTRA `ui.interact` rects, one per handle, each with `Sense::focusable_noninteractive()`. These exist ONLY to give each handle its own focus stop and its own AccessKit node. They do not take pointer input (E1 `range_slider_ui`: "Each handle is its own focus stop, so the keyboard and a screen reader can reach either end of the range").
  - The fill between the handles is `paint_fill` bounded at both ends.
  - There is optionally an editable number (DragValue) at each end of the rail.
- (c) Routing (`nearer_handle`, E1 near the end):
  - The NEARER handle by distance along the rail wins.
  - On an exact tie, which includes coincident handles, the SIDE OF THE PRESS decides: a press at a value below low grabs low, otherwise high. The doc comment says: "When the handles coincide, the side the pointer is on decides, or a collapsed range could only ever be opened in one direction."
  - The choice is made ONCE PER GESTURE and remembered in temp data, "so dragging one handle into the other does not hand the pointer over to its neighbor half way".
  - A press anywhere on the rail jumps the chosen handle to the press (`set(grabbed, value)` on every pointer frame).
  - Hover highlights the handle a press would grab. There is no z-order concept: both handles are painted low then high.
- (d) STOP: "The handles may meet but never cross" (E1 l.22). `bounds()` limits low to `..= high - min_separation` and high to `low + min_separation ..=` (E1 l.368-385). `min_separation` defaults to 0.0 (E1 l.110-117). `set()` re-imposes order after rounding. There are unit tests `handles_meet_but_never_cross` and `handles_keep_their_separation`. No push.
- (e) Accessibility: TWO ADJUSTABLE ELEMENTS, plus the container.
  - Each handle's AccessKit node gets `WidgetInfo::slider(enabled, value, label)` and `declare_accesskit_slider`, which sets min, max and step, and the actions SetValue, Increment and Decrement (the last two only when room remains) (E1; E2 `declare_accesskit_slider`).
  - IMPORTANT DETAIL: each handle REPORTS ITS MIN/MAX AS BOUNDED BY THE OTHER HANDLE. Low's max is `high - min_separation` and high's min is `low + min_separation` (`reported = self.bounds(handle, low, high, sorted_range)`).
  - DEFAULT NAMES: "low" and "high", or "<text> low" / "<text> high" when the slider has a `.text()` label (`handle_label`, E1 ~405-416).
  - The whole widget also gets `WidgetInfo::labeled(Role::Slider, ..)` and `labelled_by` its label.
  - Screen-reader SetValue outranks a step (`accesskit_set_value_request`).
  - The platform mapping goes through AccessKit's adapters. The claims that this becomes UIA RangeValue on Windows, NSAccessibility slider on macOS and AT-SPI Value on Linux are unverified; I did not read the accesskit adapters for this note.
- (f) Keyboard: each handle is a Tab stop. Arrow keys along the rail's axis step the focused handle: Left/Right when horizontal, Up/Down when vertical. The focus lock filter stops those arrows from moving focus (E2 `keyboard_steps`). I saw no Home/End/PageUp/PageDown in `keyboard_steps`.
- (g) Vertical is supported: `.vertical()` / `.orientation(SliderOrientation::Vertical)`. The numbers are placed high first on a vertical rail, whose top is the high end (E1 ~119-130, `add_contents`).

### egui_double_slider (hacknus, community)
Source:
- ED = https://raw.githubusercontent.com/hacknus/egui_double_slider/main/src/double_slider.rs

- (a) Third-party `DoubleSlider::new(&mut lower, &mut upper, range)`.
- (b) ONE custom-painted widget. It allocates a painter (`Sense::click_and_drag`) and adds three separate `ui.interact` regions: an in-between rect that drags the whole range, then a rect around the first handle, then a rect around the second handle, each with its own id (ED ~345, ~419, ~468-470, ~525).
- (c) Routing: each handle only responds to presses on its OWN rect. I saw no nearest-thumb logic and no track-click jump. The overlap winner is decided by egui's own hit test between the two `interact` rects. The second rect is registered later, and my assumption that it is on top is UNVERIFIED because I did not read egui's hit-test code.
- (d) PUSH by default: `push_by_dragging: true` (ED l.43, l.65). When one handle comes within `separation_distance` (default 1.0) of the other, the other is pushed. With push off, the dragged handle is stopped (ED ~489-498, ~544-553).
- (e) Accessibility: I found no `widget_info` or accesskit calls in ED (grep), so no slider semantics.
- (f) Keyboard: none. I found no key handling.
- (g) Vertical is supported (`orientation(SliderOrientation::Vertical)`, ED l.96-100).

## Slint
- (a) NO first-party range slider. The shared std-widgets bases in the repo are `slider-base.slint` (one handle), spinbox, combobox and the other bases. There is no range file in https://github.com/slint-ui/slint/tree/master/internal/compiler/widgets/common (listed via the GitHub API). A search of slint-ui/slint issues for "RangeSlider", "range slider" and "two handles slider" found nothing.
- The related request https://github.com/slint-ui/slint/issues/3546 asks for a customizable slider, not a two-handle one. Slint's answer for anything missing is the "Custom Controls" guide (https://docs.slint.dev/latest/docs/slint/guide/development/custom-controls/), i.e. build your own with TouchArea and FocusScope.
- (b)-(g): not applicable. I found no widely used community crate (unverified beyond the searches above).

## iced
- (a) NO first-party range slider. `widget/src` has only `slider.rs` and `vertical_slider.rs`, listed via the GitHub API from https://github.com/iced-rs/iced/tree/master/widget/src. iced_aw (https://github.com/iced-rs/iced_aw/tree/main/src/widget) has `slide_bar.rs` but no range slider. A GitHub repo search for "iced range slider" found nothing. The iced tracker has only https://github.com/iced-rs/iced/issues/366 (keyboard accessibility of the plain slider), which is closed.
- Note: iced ships vertical as a SEPARATE widget, `VerticalSlider`, rather than an axis property.
- (b)-(g): not applicable.

## Druid (linebender; superseded by xilem/masonry): first-party `RangeSlider`
Source:
- D1 = https://raw.githubusercontent.com/linebender/druid/master/druid/src/widget/slider.rs

- (a) Yes: `druid::widget::RangeSlider`, data `(f64, f64)` (D1 l.37, l.216-290).
- (b) ONE widget holding two private `SliderKnob` state structs (`left_knob`, `right_knob`), painted by the one widget (D1 ~65, ~286-400).
- (c) Routing (D1 `event` ~292-345):
  - The left knob gets the event first, and the right knob only if the left did not go active. So on OVERLAP THE LEFT KNOB WINS.
  - A press on the track off both knobs picks the nearer knob by value: `press_value - low < high - press_value` picks left, otherwise right (so an exact tie goes RIGHT). The chosen knob jumps to the press.
- (d) STOP: after each input `data.0 = data.0.min(data.1)` and `data.1 = data.1.max(data.0)`.
- (e) No accessibility; Druid had no accessibility layer (unverified beyond the absence of any accessibility code in D1).
- (f) I found no key handling in D1 (grep for KeyDown found none).
- (g) Vertical is supported (`.axis(Axis::Vertical)`, D1 l.268).

## Other desktop toolkits

### Dear ImGui `DragFloatRange2` / `DragIntRange2`: TWO STOCK WIDGETS SIDE BY SIDE, not stacked
Source:
- https://raw.githubusercontent.com/ocornut/imgui/master/imgui_widgets.cpp (`ImGui::DragFloatRange2`)

- (a) First-party, but it is not a slider over one track. It is TWO stock `DragScalar` number fields ("##min" and "##max") laid out side by side with `PushMultiItemsWidths(2, ..)`, followed by the label.
- (b) COMPOSITION of two stock single-value widgets, each on its OWN area. The constraint lives in the bounds passed to each: min's upper bound is `current_max`, and max's lower bound is `current_min`. A field whose bounds collapse becomes `ImGuiSliderFlags_ReadOnly`.
- (c) No routing is needed because the widgets do not overlap.
- (d) Each value STOPS at the other.
- (e) ImGui has no platform accessibility (general knowledge; not re-verified here).
- (f) Two separate items for ImGui's own navigation.
- (g) Not applicable.
- This is the one "stock widgets composed" design I found in this set, and it works precisely because the two widgets do NOT share a track.

### JavaFX ControlsFX `RangeSlider` (third-party; JavaFX itself has none)
Sources:
- C1 = https://raw.githubusercontent.com/controlsfx/controlsfx/master/controlsfx/src/main/java/impl/org/controlsfx/skin/RangeSliderSkin.java
- C2 = https://raw.githubusercontent.com/controlsfx/controlsfx/master/controlsfx/src/main/java/org/controlsfx/control/RangeSlider.java

- (a) Third-party `org.controlsfx.control.RangeSlider`, with lowValue and highValue.
- (b) TWO THUMB PARTS INSIDE ONE CONTROL'S SKIN. `lowThumb` and `highThumb` are `ThumbPane extends StackPane`, sitting in the skin next to a `track` StackPane, a draggable `rangeBar` and a JavaFX `NumberAxis`-style tickLine (C1 ~60-70, ~217-300, ~773). It does NOT stack two `javafx.scene.control.Slider`s.
- (c) Routing:
  - Each thumb has its own mouse handlers. highThumb is added to the children after lowThumb, so it is on top, and JavaFX picking gives an overlapping press to HIGH. This is inferred from the child order and I did not run it.
  - A TRACK press (C1 `trackPress` ~625-652) moves LOW only if the press is below lowValue, otherwise HIGH. It does NOT pick the nearest: a press just right of low, between the thumbs, moves high.
  - The rangeBar drags both thumbs.
- (d) STOP: `adjustLowValues`/`adjustHighValues` clamp low to [min, high] and high to [low, max] (C2 ~903-950). No crossing and no push.
- (e) Accessibility: none. I found no `AccessibleRole`/`queryAccessibleAttribute` in C1 or C2 (grep), so JavaFX's accessibility gets no slider semantics for either thumb (inferred).
- (f) Keyboard (C1 ~139-212):
  - The thumbs are NOT real focus nodes. The skin fakes focus with `setFocused()` on the ThumbPanes and intercepts TAB itself: Tab from low goes to high, Tab from high leaves the control, and Shift+Tab goes back.
  - Arrows (with RTL flip) step the pseudo-focused thumb along the axis.
  - Home and End are handled on KEY_RELEASED.
  - A similar request on MahApps (WPF): https://github.com/MahApps/MahApps.Metro/issues/4621, "RangeSlider: move the thumb that was clicked with the arrow keys" (not read in detail).
- (g) Vertical is supported (orientation; vertical track press uses `1 - position`).

### wxWidgets
- (a) NO two-thumb control. `wxSlider` has one thumb. `wxSL_SELRANGE` "Displays a highlighted selection range. Windows only", set with `SetSelection(start, end)`. This is the Win32 trackbar's TBM_SETSEL: a visual range with no second thumb (https://docs.wxwidgets.org/3.2/classwx_slider.html).
- (b)-(g): not applicable.

### Stacking two stock sliders over one track: the one documented instance I read (web, outside my assigned set)
- Mike Jolley, "Building a cross-browser compatible, multi-handle range slider" (https://mikejolley.com/2019/08/02/building-a-cross-browser-compatible-multi-handle-range-slider/). It stacks two `<input type=range>` elements. I read it through a summary fetch and not line by line. Problems it reports:
  - Hit testing: with pointer events left on, "only the first range slider can be clicked". In IE/Edge you cannot switch pointer events off for the track and back on for the thumb.
  - The fix was to TOGGLE Z-INDEX from JavaScript, raising whichever input's handle is nearest the mouse. In other words, a container doing nearest-thumb routing, which is kaya's planned shape.
  - The two engines needed different alignment hacks.
  - The fill between the thumbs needed per-engine tricks.
  - The native tick marks and popups had to be suppressed.
- CSS-Tricks covers the same pattern (https://css-tricks.com/multi-thumb-sliders-particular-two-thumb-case/). I did not read it.

## Cross-cutting summary (my reading of the above)
- BUILD: none of the assigned toolkits stacks two stock sliders over one track.
  - Flutter, egui (the new first-party one), Druid and the egui community widget each draw ONE control that owns both thumbs.
  - Qt Quick and ControlsFX template two thumb PARTS inside one control.
  - QxtSpanSlider and superqt are the closest thing to kaya's plan. They are ONE widget that asks the platform's QStyle to draw each handle natively. That gives native-looking pixels without two native controls, and superqt paid for it in style-sheet and theme breakage (#201, #58) and a macOS drag patch.
  - ImGui composes two stock widgets, but side by side, not over one track.
- ROUTING:
  - Nearest thumb: Qt Quick, egui, Druid, and Flutter by midpoint.
  - Overlap tie-breaks vary. Flutter defers to DRAG DIRECTION. egui uses the SIDE OF THE PRESS relative to the shared value. Qt Quick uses the HIGHER Z, meaning the last pressed. QxtSpanSlider tries upper first and then swaps on the first move downward. superqt and Druid use a fixed order (lower first), which is superqt's open bug #150: the upper handle cannot be grabbed when both sit at 0.
  - egui locks the choice for the whole gesture.
- STOP versus CROSS versus PUSH:
  - STOP is the default everywhere: Flutter (minThumbSeparation), Qt Quick, egui (min_separation, default 0), superqt (one step apart), Druid, ControlsFX.
  - CROSS: Qt Quick 6.12 `crossingEnabled` and QxtSpanSlider `FreeMovement` (the default there). Both swap the handles' roles.
  - PUSH: only egui_double_slider (default on).
- ACCESSIBILITY:
  - Two adjustable elements: Flutter (two child semantics nodes, NO default names, value as a percent) and egui (two AccessKit slider nodes named "low"/"high", each reporting min and max bounded by the other handle).
  - Qt Quick exposes ONE Slider-role element with no current value (inferred from source).
  - QxtSpanSlider and superqt expose QSlider's single element with an unrelated value (inferred).
  - ControlsFX, Druid and egui_double_slider expose nothing.
- KEYBOARD:
  - A Tab stop per thumb: Flutter, Qt Quick, egui, and ControlsFX (faked).
  - One stop with keys bound per handle: QxtSpanSlider.
  - None: superqt, Druid, egui_double_slider.
  - Home/End only in QxtSpanSlider and ControlsFX.
- VERTICAL: Qt Quick, egui, QxtSpanSlider, superqt, Druid and ControlsFX support it. Flutter does not.
