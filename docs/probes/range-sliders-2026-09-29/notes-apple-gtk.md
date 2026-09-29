# Range control research: UIKit/SwiftUI, AppKit, GTK 4/GNOME

Method: repos shallow-cloned into scratchpad/range/src (gone) and read; issue trackers via GitHub API / GitLab.
"read" = I read the source; "unverified" = not confirmed from source or primary doc.

## iOS: yonat/MultiSlider (master a5dbf58, 2025-08-09)
Source: https://github.com/yonat/MultiSlider/tree/master/Sources
- (a) third party; N thumbs (`value: [CGFloat]`), UIControl subclass.
- (b) ONE custom control owning all thumbs: thumbs are plain `UIImageView`s added to a `slideView`, positioned by Auto Layout constraints; one `UIPanGestureRecognizer` on a `panGestureView` covering the control (MultiSlider+Internal.swift `setup()`, `setupPanGesture()`, `addThumbView`). Not stacked UISliders.
- (c) routing: on pan `.began`, `closestThumb(point:)` (MultiSlider+Drag.swift) picks nearest thumb along the axis within `diagonalSize + thumbTouchExpansionRadius`, skipping `disabledThumbIndices`. Tie (two thumb centers equal): picks the upper thumb if the touch point is beyond the shared center in the "greater" direction, else the lower one — i.e. tie broken by which SIDE of the stacked thumbs you touched, not by drag direction. Also yields to a perpendicular pan (`shouldRecognizeSimultaneouslyWith` compares pan velocity axis to orientation).
- (d) STOP: `boundedDraggedThumbPosition` clamps to neighbour ± delta; `distanceBetweenThumbs` default -1 = half a thumb gap, 0 = may coincide, >0 = value gap. Never cross, never push.
- (e) accessibility WEAK: the whole control is ONE element, `accessibilityLabel = "slider"`, traits `[.allowsDirectInteraction]` (NOT `.adjustable`), `accessibilityValue = value.description` (e.g. "[0.2, 0.8]") set in `value` didSet — and that didSet returns early while dragging (`isSettingValue`), so value goes stale mid-drag; instead each drag step posts `UIAccessibility.post(.announcement, …)`. No accessibilityIncrement/Decrement: VoiceOver cannot adjust either thumb except by direct-interaction touch. Sources: MultiSlider+Internal.swift lines 18-21, MultiSlider.swift line 21, MultiSlider+Drag.swift line 95. A PR "patch accessibility improvements" (https://github.com/yonat/MultiSlider/pull/107) was closed UNMERGED.
- (f) keyboard: none (no UIKeyCommand / focus code found by grep).
- (g) vertical: yes, `orientation: NSLayoutConstraint.Axis` (default vertical in UIKit storyboard? — the enum is used throughout; default value unverified).

## iOS: TomThorpe/TTRangeSlider (master 2860afb, 2021-04-07)
Source: https://github.com/TomThorpe/TTRangeSlider/blob/master/Pod/Classes/TTRangeSlider.m
- (a) third party, two thumbs.
- (b) ONE custom-drawn UIControl: track and handles are `CALayer`s (lines 84-112); tracking via `beginTrackingWithTouch/continueTrackingWithTouch`. Not stacked.
- (c) routing: touch must hit a handle's frame inset by -30pt (`HANDLE_TOUCH_AREA_EXPANSION`), else the touch is refused (tap on track does nothing). Then nearest handle centre by Euclidean distance; ties go to the RIGHT handle, except when both are at `maxValue` with equal centres, then LEFT (so a pair jammed at the max end can be pulled apart). Lines 357-387. `gestureRecognizerShouldBegin` returns `!isTracking` so an enclosing scroll view does not steal the drag.
- (d) STOP: dragged handle clamps to the other (continueTracking lines 441-475); optional `minDistance`/`maxDistance` enforced in `refresh` by moving the dragged handle back.
- (e) accessibility: TWO `UIAccessibilityElement` subclasses in a `UIAccessibilityContainer` (`accessibilityElementCount/AtIndex`), each `UIAccessibilityTraitAdjustable`, `accessibilityFrame` = handle frame, increment/decrement by `step`. Default labels "Left Handle"/"Right Handle", hints "Minimum value in slider"/"Maximum value in slider" (lines 142-157, 805-860; comment "TODO Create a bundle that allows localization"). Added by PRs #41 (2016) and #60 (2017): https://github.com/TomThorpe/TTRangeSlider/pull/41, /pull/60. Code-reading note (not run): the a11y increment writes `selectedMinimum += step` through a setter that clamps only to minValue/maxValue, and `refresh` enforces separation only if `minDistance != -1`, so a VoiceOver swipe-up on the left handle can apparently carry it past the right handle (the touch path guards crossing, the a11y path does not). Unverified at runtime.
- (f) keyboard: none.
- (g) vertical: no (x-only arithmetic).
- MultiSlider (g) addendum: `orientation` defaults to `.vertical` (MultiSlider.swift line 229) — vertical is first-class.

## iOS: warchimede/RangeSlider = "WARangeSlider" (Ray Wenderlich tutorial lineage; master a622cf0, 2025-05-19)
Source: https://github.com/warchimede/RangeSlider/blob/master/Sources/WARangeSlider/RangeSlider.swift
- (a) third party.
- (b) ONE custom UIControl; track and two thumbs are `CALayer` subclasses drawn in `draw(in:)` (lines 4-80, 172-230).
- (c) routing: pure hit test, LOWER checked first (`if lowerThumbLayer.frame.contains … else if upper…`, lines 247-257); taps on the track do nothing. No nearest-thumb logic, no tie-break → the classic OVERLAP DEADLOCK: issue #1 (open since 2015) "When the lower slider is at the 0 position and the upper slider is then dragged on top of it, the slider is 'locked' – gestures seem to be picked up by the lower slider" https://github.com/warchimede/RangeSlider/issues/1 . Unmerged PR #28 "fix for stuck thumbs … when two thumbs are at the extreme … the most extreme thumb gets the touch (instead of the inner thumb that needs to move)" https://github.com/warchimede/RangeSlider/pull/28 . Issue #40: fixed half-thumb gap means thumb "stops at 22, can't pull it up to 23" and cannot overlap https://github.com/warchimede/RangeSlider/issues/40 .
- (d) STOP with a fixed pixel-derived gap `gapBetweenThumbs = 0.5*thumbWidth*(range)/bounds.width` (lines 117-119, 271-273).
- (e) accessibility: NONE (no accessibility API in file).
- (f) none. (g) no.

## iOS: WorldDownTown/RangeSeekSlider (master df4c893, 2019-04-01) — Swift port of TTRangeSlider
Source: https://github.com/WorldDownTown/RangeSeekSlider/blob/master/Sources/RangeSeekSlider.swift
- (b) ONE custom UIControl, `CALayer` handles (lines 230-234).
- (c) same as TTRangeSlider: -30pt expanded handle hit, nearest centre, tie → right, except both at max with same midX → left (lines 297-322).
- (d) STOP (`min(selectedValue, selectedMaxValue)` lines 336-347); `minDistance`/`maxDistance`.
- (e) TWO `UIAccessibilityElement`s, `.adjustable`, container protocol (lines 247-272, 367-391, 707-719). Default labels are EMPTY strings (doc comments lines 212-221) — i.e. both thumbs speak only their value unless the app sets labels. The a11y increment path `selectedMinValue += step` clamps only to minValue in didSet (line 53-58) — crossing via VoiceOver apparently possible (read, not run; unverified).
- (f) none. (g) no.

## iOS: BrianCorbin/SwiftRangeSlider (master 77123ae, 2017-08-17)
Source: https://github.com/BrianCorbin/SwiftRangeSlider/blob/master/SwiftRangeSlider/RangeSlider.swift
- (b) ONE custom UIControl, `RangeSliderKnob: CALayer`.
- (c) routing when BOTH knob frames contain the touch: if knobs are within 5% of range (`knobsAreClose`), pick by POSITION ON TRACK — if the pair is closer to the minimum, take the UPPER knob (the one that can move), else the LOWER; otherwise the previously selected knob (lines 214-220, 387-403). Z-order: a highlighted knob removes and re-adds itself to its superlayer so the active knob draws on top (RangeSliderKnob.swift lines 27-33). Optional `dragTrack`: touching the track between drags both.
- (d) STOP with `minimumDistance`.
- (e) accessibility: NONE (grep: no accessibility API).
- (f) none. (g) no.

## SwiftUI: spacenation/swiftui-sliders `RangeSlider` (master 0e7b1b6, 2025-08-01)
Source: https://github.com/spacenation/swiftui-sliders/blob/master/Sources/Sliders/RangeSlider/Styles/Horizontal/HorizontalRangeSliderStyle.swift
- (b) ONE SwiftUI view: `ZStack { track; lowerThumb; upperThumb }`, each thumb its own `DragGesture(minimumDistance: 0)` on a 44x44 interactive frame. Not stacked `Slider`s.
- (c) routing: SwiftUI hit testing — the UPPER thumb is later in the ZStack so it is on top. Overlap is avoided BY GEOMETRY: the lower thumb travels over `width - upperThumbWidth` and the upper over `[lowerThumbWidth, width]`, so at equal values the thumbs sit side by side, never on top of each other (the `availableDistance`/offset arguments in the file). Interactive frames (44pt) still overlap each other; upper wins there.
- (d) PUSH by default: `RangeSliderOptions.defaultOptions = .forceAdjacentValue` (RangeSliderOptions.swift) and `rangeFrom(updatedLowerBound:…forceAdjacent:)` moves the other bound along (Base/LinearRangeMath.swift lines 11-30); without the option, STOP. Also a `distance: ClosedRange` min/max gap.
- (e) accessibility: NONE — no `.accessibility*` modifier anywhere in Sources (grep). VoiceOver sees nothing adjustable.
- (f) none (no focus/key code). (g) vertical: yes, `VerticalRangeSliderStyle`.

## iOS: chicio/RangeUISlider (master 6bb4750, 2025-01-19) — brief
Source: https://github.com/chicio/RangeUISlider/tree/master/Source
- (b) ONE custom UIView; each knob is its own `UIView` (`Knob.swift`) with its OWN `UIPanGestureRecognizer` (Knob.swift line 80; RangeUISlider.swift `moveLeftKnob/moveRightKnob` ~line 701). Overlap routing = UIKit hit test on subviews (unverified which is on top; not read further).
- (e) accessibility: only `accessibilityIdentifier`s "LeftKnob"/"RightKnob" for UI tests (KnobsPropertiesFactory.swift lines 49-55); the knob label is made an accessibility element (KnobLabel.swift line 48) but no adjustable trait, no increment/decrement.

## Stacking two UISliders / two SwiftUI Sliders — what I found
- I found NO maintained library that stacks two `UISlider`s over one track. The GitHub repo search "range slider two UISlider" returned BleuLlama/RangeSliderTest, which is two UISliders placed one ABOVE the other (separate tracks: "The top widget is the MINIMUM, while the bottom widget is the MAXIMUM"), not overlaid: https://github.com/BleuLlama/RangeSliderTest . Every popular iOS range slider above (MultiSlider, TTRangeSlider, RangeSeekSlider, WARangeSlider, SwiftRangeSlider, CMRangeSlider, RangeUISlider, swiftui-sliders) is one custom control. CMRangeSlider (cmezak, 2010) uses UIImageViews + rect hit test with MIN checked first: https://github.com/cmezak/CMRangeSlider/blob/master/iPhone/RangeSlider.m lines 58-100.
- StackOverflow's canonical Q "How to make a range control in Cocoa touch? Is it possible to subclass a UISlider so that it displays two knobs" answers point to a custom-control tutorial, not stacking: https://stackoverflow.com/questions/13377600 ; "Double ranged and moveable slider component in iOS" answers list custom controls (iosrangeslider, CMRangeSlider, NMRangeSlider): https://stackoverflow.com/questions/7640273 .
- SO "Accessibility on custom UISlider" (two-thumb custom slider; VoiceOver swipe up/down did nothing): cause was plain UIAccessibilityElements with `.adjustable` but no `accessibilityIncrement/Decrement` override — VoiceOver plays the boundary "ding" when the value does not change: https://stackoverflow.com/questions/29464693 (answer 29484752). This is the pattern TTRangeSlider/RangeSeekSlider later adopted (per-thumb subclasses).
- SwiftUI two-`Slider`-in-ZStack: I did not find a primary source (issue/SO) documenting it; a web search surfaced only generic statements that the top view intercepts touches. UNVERIFIED as a documented failure — treat as expected behaviour of SwiftUI hit testing, not an observed bug report.

## Apple's own trim UIs
- iOS Photos trimmer: Apple's VoiceOver instructions: "Double-tap the screen to display the video controls, then select the beginning or end of the trim tool. Then swipe up to drag to the right, or swipe down to drag to the left." — i.e. TWO separately focusable, adjustable elements (start, end); VoiceOver announces the time as it moves. Source: Apple iPhone User Guide "Edit videos and voice memos with VoiceOver" (mirror, since support.apple.com rendered empty to curl): https://iphone.skydocu.com/en/accessibility/voiceover/edit-videos-and-voice-memos-with-voiceover/ ; search snippet from https://support.apple.com/guide/iphone/use-voiceover-in-apps-iphe4ee74be8/ios also says "Select Start or End (on the media scrubber), then swipe up or down to adjust the start or end time." Element labels "Start"/"End" per that snippet (not read on the page itself — unverified verbatim).
- User complaint: AppleVis forum "VoiceOver Trimming Accessibility Issues in iPhone Photos App" — swipe up/down moves the handle only "a few frames or seconds" per swipe, very slow for long videos (search snippet; page 403 to fetch, so unverified verbatim): https://www.applevis.com/forum/ios-ipados/submitted-feedback-voiceover-trimming-accessibility-issues-iphone-photos-app . Lesson for kaya: per-thumb adjustable elements work, but the a11y step size matters.
- UIVideoEditorController (iOS): "system interface for trimming video … intended to be used as-is and doesn't support subclassing. The view hierarchy for this class is private" (Apple docs JSON https://developer.apple.com/tutorials/data/documentation/uikit/uivideoeditorcontroller.json). Not a reusable control; its accessibility is undocumented.
- AVPlayerView `beginTrimming(completionHandler:)` (macOS): "Puts the player view into trimming mode … blocks until the user selects either the Trim or the Cancel button" (https://developer.apple.com/tutorials/data/documentation/avkit/avplayerview/begintrimming(completionhandler:).json). Whole-view modal mode, not a control; how its handles appear to VoiceOver on macOS is NOT documented — unverified.
- No first-party two-thumb control in UIKit, SwiftUI or AppKit: `UISlider` "A control for selecting a single value" (uikit/uislider.json), SwiftUI `Slider` "selecting a value" (swiftui/slider.json); NSSlider likewise single-valued (I did not find any range variant in AppKit docs; negative claim, from the absence in docs).

## AppKit: SMDoubleSlider (Snowmint, 2003-2008; mirror https://github.com/jjk/SMDoubleSlider, last push 2009)
Source: https://github.com/jjk/SMDoubleSlider/blob/master/Framework_code/SMDoubleSliderCell.m and SMDoubleSlider.m
- (a) third party, NSSlider + NSSliderCell subclasses.
- (b) a HYBRID worth noting: ONE native NSSliderCell TIME-SHARED between two knobs. It draws the lo knob by stuffing `_sm_loValue` into NSSliderCell's private `_value` ivar and calling the native `drawKnob:`, then draws the hi knob with the real value (`drawKnob`, lines 140-178). For a lo-knob drag it swaps `_value` with the lo value and lets `[super startTrackingAt:]`/`continueTracking:` do native mouse tracking, then clamps (lines 214-292). Depends on private ivars (`_value`, `_scFlags`, `_cFlags`) — would not survive modern AppKit (my inference; not tested).
- (c) routing: horizontal = nearest knob by gap to knob edges (line 231); vertical = which side of the lo knob's rect edge (lines 220-226). Tie (both knob rects equal): take lo only if lo > minValue — i.e. if jammed at the minimum, take the hi knob (lines 234-237).
- (d) STOP: lo clamped to hi and hi to lo during tracking (continueTracking lines 266-285). `lockedSliders` option exists (semantics not read; unverified).
- (e) accessibility: NO accessibility code. Value accessors (`doubleValue`, `stringValue`, … lines ~350-430) return the lo or hi value depending on `trackingLoKnob`, so NSSliderCell's built-in AX value would presumably report whichever knob is "current" — inference, unverified at runtime. One AX element at best.
- (f) keyboard: ONE focusable view; Tab inside the control moves lo→hi knob, then to the next key view; Shift-Tab hi→lo then previous (`insertTab:`/`insertBacktab:` in SMDoubleSlider.m); `becomeFirstResponder` picks lo when tabbing forward in, hi when backward. Focus ring drawn only around the focused knob (Read Me v2.0 changelog "Fixed problem with keyboard focus drawing ring around both knobs"). Arrow keys presumably NSSlider's native handling on the current knob (unverified). Docs: "SMDoubleSliderCell does not handle the tabbing … in a matrix or table column … only be able to adjust one of the knobs" (Docs/Tasks/Overview.html).
- (g) vertical: yes (isVertical branches).
- StackOverflow "What is correct way to create a NSSlider with two thumbs(knobs)" — no accepted native answer: https://stackoverflow.com/questions/24197240 .
- No maintained modern Swift AppKit range slider turned up in GitHub search ("range slider macos NSSlider" returned nothing). How Final Cut / Logic / Pixelmator / Music / Photos for Mac expose their ranges to VoiceOver: UNKNOWN — no documentation found, and I did not inspect them with Accessibility Inspector.

## GTK 4 (first party)
Sources: gtk main, https://github.com/GNOME/gtk/blob/main/gtk/gtkrange.c , gtkscale.c , gtkaccessiblerange.h (fetched 2026-09-29).
- (a) NO two-thumb widget. `GtkRange` visualizes ONE `GtkAdjustment`; it builds exactly one slider gizmo: `priv->slider_widget = gtk_gizmo_new ("slider", …)` parented to the trough gizmo (gtkrange.c line 583-584). GtkScale sets `GTK_ACCESSIBLE_ROLE_SLIDER` (gtkscale.c line 818); GtkRange implements `GtkAccessibleRange` whose only vfunc is `set_current_value(double)` (gtkaccessiblerange.h lines 21-41; gtkrange.c 474-477) and publishes VALUE_MIN/MAX/NOW (gtkrange.c 724-750). The accessible API is one-value-per-accessible, so a two-thumb GTK control must present TWO slider accessibles either way (two GtkScales, or a custom widget with two child accessibles). libadwaita: no range/two-handle widget in its widget list (negative claim from docs; https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/ — not exhaustively re-read).
- Issue tracker: GitLab API searches of GNOME/gtk issues for "two handles", "range slider", "double slider", "dual scale", "two sliders", "multiple handles" found NO request for a two-handle GtkScale (https://gitlab.gnome.org/api/v4/projects/GNOME%2Fgtk/issues?search=… ; results were unrelated). A web search surfaced a personal fork branch `wisperwind/gtk` "range-selector" (https://gitlab.gnome.org/wisperwind/gtk/-/blob/range-selector/gtk/gtkscale.h) — the project now 404s via API/WebFetch, so its content is UNVERIFIED; it never reached GTK main (gtkscale.c on main has one slider).
- Facts relevant to STACKING two GtkScales (read, not run): (c) a primary click outside the slider WARPS the slider there by default (`gtk-primary-button-warps-slider`, gtkrange.c 2030-2100; Shift inverts; middle-click the other behaviour) — so the TOP scale of a stack takes every click on its whole allocation, including clicks meant for the other thumb, unless the container intercepts (e.g. `can-target` false on the scales and a parent GtkGestureDrag/Click that routes). (f) GtkScale key bindings: arrows, Page_Up/Page_Down (Ctrl variants), Home/End (gtkscale.c 771-810 `add_slider_binding`); each GtkScale is its own focus stop, so two stacked scales give Tab between thumbs for free. (e) each is its own AT-SPI slider with its own name; Orca can adjust each (inferred from role + AccessibleRange; not tested with Orca). (g) both orientations native.

## GNOME Video Trimmer (YaLTeR; gitlab master 8b6cc9e, 2026-09-22)
Source: https://gitlab.gnome.org/YaLTeR/video-trimmer/-/blob/master/src/timeline.rs , timeline.blp , window.blp , application.rs
- (b) ONE custom `VtTimeline` widget (GTK 4, Rust): two child `Box`es with `can-target: false` — a "selection" box and a "position" (playhead) box (timeline.blp); one `GtkGestureDrag` on the whole widget (timeline.rs 134-155). There are NO thumb widgets: the in/out points are the EDGES of the selection box.
- (c) routing: on drag begin, if the pointer is within `TOLERANCE = 5.` px of the selection's END edge → drag End; else within 5 px of START → Start; else the drag scrubs the playhead (`on_drag_start`, lines 323-343). END is tested first, so at coincident edges the end wins. Cursor turns `col-resize` within tolerance (`on_motion`).
- (d) CROSS (swap): dragging Start past End flips `drag_type` to End and returns `(end, time)` — the handles exchange roles and the drag continues (lines 373-408). It refuses a value that would make start == end ("counts as an invalid region").
- (e) accessibility: the timeline has NO accessible role/value code (grep for accessib/update_property: none; it only `@implements gtk::Accessible` by default, line 453). Accessible access to in/out is via two `GtkEntry` text fields next to visible Labels "Start" and "End" (window.blp 170-200) — the labels are NOT linked by `mnemonic-widget`/`labelled-by` (grep: none), so the entries' accessible names are probably empty (unverified with Orca).
- (f) keyboard: `i` = set start at playhead, `o` = set end at playhead, `,`/`.` frame step (application.rs 175-176; window.rs 972-974; issue #66 "Keyboard shortcut for in and out marker" https://gitlab.gnome.org/YaLTeR/video-trimmer/-/work_items/66). No keyboard focus on the timeline itself.
- (g) horizontal only.
- Takeaway: the one GNOME trimming app avoided a two-thumb control entirely: scrub the playhead, then mark in/out, with text entries as the precise/accessible path.

## GIMP GimpHandleBar (Levels tool input/output range; GTK 3 in GIMP 3)
Source: https://github.com/GNOME/gimp/blob/master/app/widgets/gimphandlebar.c , app/tools/gimplevelstool.c
- (b) ONE custom-drawn GtkEventBox with up to THREE handles (`GtkAdjustment *slider_adj[3]`, `slider_pos[3]` in gimphandlebar.h): black point, gamma, white point, drawn as triangles. Each handle is BOUND to the GtkAdjustment of a GtkSpinButton ("low-input", "gamma", "high-input") in the Levels tool (gimplevelstool.c 473-548).
- (c) routing: on press, nearest handle by |x − pos|; exact tie goes to the handle for which the click is on its right (`fabs(dist) == min_dist && dist > 0`) (lines 212-255); the press also JUMPS the chosen handle to the click point.
- (d) the bar itself does not clamp handles against each other (it only sets the adjustment); ordering, if any, is enforced by the adjustments/config — not read, unverified.
- (e) accessibility: none in the bar (no ATK code). The accessible path is the three spin buttons beside it.
- (f) no key handling in the bar (no key_press); keyboard via the spin buttons. (g) `orientation` property exists (default horizontal).

## darktable GtkDarktableRangeSelect (collection filters: rating, date, exposure…; GTK 3)
Source: https://github.com/darktable-org/darktable/blob/master/src/dtgtk/range.c
- (b) ONE custom-drawn band widget; no thumbs — a rubber-band selection whose ends can be resized.
- (c) pointer within `SNAP_SIZE` of the min edge → HOVER_MIN (tested FIRST), else of the max edge → HOVER_MAX, else inside = start a new selection by press-drag (lines ~1566-1590, 1603-1650). Double-click selects all; right-click opens a popover with min/max text entries.
- (d) CROSS then normalise: on release, if max < min they are swapped (lines 1651-1665).
- (e) accessibility: none found (grep for accessib/atk: none). Precise/keyboard path is the optional min/max entries (`show_entries`) and the popover.
- (f) none on the band. (g) horizontal only.

## Other GNOME/GTK apps
- Pitivi (clip trimming in a GES timeline), Shotwell, Nautilus: NOT investigated in source — unknown. I found no GTK app that stacks two GtkScales (GitHub code searches for GtkScale+overlay range patterns returned nothing relevant). Negative result, not proof of absence.
- libadwaita: no range widget.

## Summary across my toolkits
- No first-party two-thumb control on UIKit, SwiftUI, AppKit, GTK 4 or libadwaita.
- Every third-party control I read is ONE control owning both thumbs (CALayers, UIImageViews, SwiftUI views, cairo drawing). None stacks two native sliders; the closest to "reuse the native slider" is SMDoubleSlider, which time-shares ONE NSSliderCell between two knobs via private ivars.
- Overlap handling is where naive ones break: WARangeSlider's first-hit-wins routing deadlocks when thumbs meet at an end (issue #1, open since 2015; unmerged PR #28). The robust rules seen: nearest thumb; on a tie pick the thumb that can move (TTRangeSlider/RangeSeekSlider: left when jammed at max; SMDoubleSlider: hi when jammed at min; SwiftRangeSlider: by which end the pair is nearer); MultiSlider breaks ties by which side of the shared centre the touch lands. swiftui-sliders avoids overlap by reserving a thumb-width so thumbs sit side by side.
- Thumb interaction: most STOP; swiftui-sliders PUSHES by default; Video Trimmer and darktable CROSS/swap.
- Accessibility done right = two adjustable elements, one per thumb (TTRangeSlider/RangeSeekSlider on iOS, and Apple's own Photos trimmer, whose start and end are separately adjustable by VoiceOver). But the libraries' default labels are poor ("Left Handle"/"Right Handle", or empty), and their a11y increment path skips the no-cross guard the touch path has. MultiSlider, WARangeSlider, SwiftRangeSlider, RangeUISlider, swiftui-sliders and SMDoubleSlider expose nothing adjustable per thumb. GNOME apps (Video Trimmer, GIMP, darktable) sidestep it: the drawn range is inaccessible and paired text/spin entries carry the accessible and precise path.
- For kaya's stacking plan the relevant native facts: GTK's GtkAccessibleRange is one value per accessible, so two GtkScales give two Orca sliders and two focus stops with arrow/Page/Home/End for free; but a GtkScale warps its slider on a primary click anywhere in its trough, so the top scale would steal clicks unless the container routes presses (`can-target` false + a parent gesture).
