# Layering: one view over another (design pass, 2026-11-15)

Status: PROPOSED 2026-11-15, rulings open (review page
claude.ai/artifact/BF7TWX5Ue3b9dHKfvSEmQb). Nothing is built. The maintainer,
2026-11-15: "do layering first". This plan is the design pass for
docs/deferred.md's GAP "kaya cannot float one view over another" (opened by
the maintainer's call-screen ruling of 2026-11-01, docs/capture-plan.md §12
item 7: "ideally we have the overlay with the self-view in the corner").
The rulings are §6, LY1 to LY14; each repeats its mechanism so it reads on
its own. Platform facts are CITED from documentation and toolkit sources
(listed in §1 with links); nothing was measured on a device pool for this
pass, and §5 step 0 names the three facts the build measures before it
builds on them.

## §0. The mechanism, from zero

**What kaya has.** Every kaya container lays its children out side by side:
a row puts them left to right, a column top to bottom, a grid in cells, a
wrapping row in lines. Two children of one container never occupy the same
pixels. The nearest thing to layering kaya has is a container's GROUND
(docs/styling-pass-plan.md Y2, Y3): a row or column may paint a gradient or
an image BEHIND its children. A ground is paint, not a widget: it takes no
tap, has no accessible name, and cannot be a video.

**What layering is.** A LAYERED container (the field's names: SwiftUI
`ZStack`, Compose `Box`, Flutter `Stack`, GTK `GtkOverlay`, a WinUI `Grid`
with every child in one cell, Qt's `QStackedLayout` in `StackAll` mode) is a
container whose children all share ONE rectangle, its BOX, and are drawn one
over the next. Three questions define any such container:

1. **What sizes the box.** Either the first child (the "base"; GTK's main
   child, SwiftUI's `.overlay` on a view), or the largest child (`ZStack`,
   Compose `Box`, Flutter's non-positioned children).
2. **Where each other child sits in the box.** An ALIGNMENT, one of nine
   positions (the four corners, the four edge midpoints, the centre), plus
   an INSET (the distance from the edge it is aligned to), and optionally a
   size relative to the box.
3. **Z-ORDER and HIT TESTING.** Z-order is which child is drawn on top
   where they overlap; every toolkit in the survey draws later children over
   earlier ones. HIT TESTING is the platform's search, at a pointer event,
   for the widget that receives it: the topmost widget whose hit region
   contains the point. What counts as a widget's hit region differs between
   toolkits, and that is where layering's semantics actually diverge (§2).

**The forcing case.** The chat app's call screen (guests/go/chat/call.go)
shows the peer's picture, a `surface` fed with the app's NV12 frames, and
the self-view, a video view previewing the capture. Today the self-view sits
in a column UNDER the peer at a third of its width (§12 item 7, 107x80). The
maintainer wants it OVER the bottom-trailing corner of the peer's picture,
which is a layered container whose base is the peer and whose second child
is the self-view, placed bottom-trailing with an inset.

**Why the platform's media views matter.** Four of kaya's five backends
draw a video as an ordinary composited layer (AVPlayerLayer,
AVCaptureVideoPreviewLayer and AVSampleBufferDisplayLayer on Apple, a
GtkPicture over a paintable on GTK, a WriteableBitmap or
MediaPlayerElement on WinUI). Android is different: a video view and the
camera preview are SurfaceViews. A SurfaceView's pixels are not in the
window at all. They live on a separate surface that the system compositor
(SurfaceFlinger) stacks BEHIND the app's window, and the SurfaceView
"punches a hole" (draws transparent pixels) in the window where it sits, so
the video shows through. Anything the window draws after the hole (a label
over the video) is composited over it correctly. Two SurfaceViews that
overlap, though, are two surfaces behind the same window, and their order
relative to each other is not defined unless one is marked as a media
overlay (§2.3).

## §1. What the toolkits do (the research)

| toolkit | spelling | what sizes the box | placement | z-order | hit testing |
|---|---|---|---|---|---|
| SwiftUI | `ZStack(alignment:)`; `.overlay(alignment:) { }` on a view | ZStack: the union of its children; `.overlay`: the modified view, "Use the overlay modifier when you want the modified view to dominate the layout" | one `Alignment` per stack or per overlay modifier (nine positions), `.padding` for an inset | "later subviews appear on top of earlier ones" | the frontmost view whose content shape contains the point; a Text, Image or Color is hit-testable and blocks views behind it; `.allowsHitTesting(false)` passes through; `.contentShape(Rectangle())` makes a view's empty area hit-testable |
| Compose | `Box { }` with `Modifier.align(Alignment)` per child | the largest child; `Modifier.matchParentSize()` "does not take part in defining the size of the Box" | nine `Alignment`s, padding for an inset | declaration order, `Modifier.zIndex` | only ELIGIBLE composables (those with a pointer-input modifier) are hit; "when there are multiple eligible composables on the same level of the tree, only the composable with the highest z-index is hit". An Image or Text with no handler is not eligible, so a tap over it reaches the button under it |
| Flutter | `Stack` with `Positioned` / `Align` | "sizes itself to contain all the non-positioned children" | `alignment` (nine), `Positioned(top, right, bottom, left)` | "paints its children in order with the first child being at the bottom" | front to back, the first child whose render box reports a hit wins; `IgnorePointer` passes through. Clip default `Clip.hardEdge` |
| GTK 4 | `GtkOverlay`, `add_overlay` | "An overlay's minimum and natural sizes are those of its main child"; overlays not measured unless `set_measure_overlay` | each overlay's `halign`/`valign` (start, center, end, fill), margins as the inset, `get-child-position` for anything else; `set_clip_overlay` | overlays over the main child, in the order added | `gtk_widget_pick`: the topmost widget whose allocation contains the point, with `can-target`; every widget is pickable over its whole allocation, so an overlay blocks over its box; `can-target = false` passes through but also for its descendants |
| WinUI 3 | a `Grid` with every child in one cell (or a `Canvas`) | the cell: the largest child, or the track it is given | `HorizontalAlignment`/`VerticalAlignment` (Stretch by default), `Margin` | "the last child is rendered on top ... the same as other built-in panels"; `Canvas.ZIndex` | the topmost element whose rendered content is hit-testable; a panel or border with a null `Background` is not hit in its empty area, a `Transparent` one is; `IsHitTestVisible = false` passes through |
| Qt | `QStackedLayout` with `StackAll` ("allows you to make use of the layout for overlay widgets"), or a child widget raised over a sibling | the largest | alignment per widget | raise order | the topmost widget under the point; `WA_TransparentForMouseEvents` passes through |
| Avalonia | `Panel` (children share one box) | the largest | `HorizontalAlignment`/`VerticalAlignment`, `Margin` | tree order, `ZIndex` | "the hit test returns the topmost control"; a null background is not hit in its empty area; `IsHitTestVisible="False"` passes through |

Sources: SwiftUI `ZStack`, `overlay(alignment:content:)`, `allowsHitTesting`,
`accessibilitySortPriority` (developer.apple.com/documentation/swiftui, read
through the JSON endpoint); Compose `BoxScope`
(developer.android.com/reference/kotlin/androidx/compose/foundation/layout/BoxScope),
"Understand gestures: event dispatching and hit-testing"
(developer.android.com/develop/ui/compose/touch-input/pointer-input/understand-gestures),
"Traversal order" (developer.android.com/develop/ui/compose/accessibility/traversal);
Flutter `Stack` (api.flutter.dev/flutter/widgets/Stack-class.html);
`GtkOverlay` (docs.gtk.org/gtk4/class.Overlay.html); WinUI "Layout panels"
(learn.microsoft.com/en-us/windows/apps/develop/ui/layout-panels) and
`UIElement.IsHitTestVisible`; Qt `QStackedLayout`
(doc.qt.io/qt-6/qstackedlayout.html); Avalonia "Hit testing"
(docs.avaloniaui.net/docs/graphics-animation/hit-testing); Android
`SurfaceView` (developer.android.com/reference/android/view/SurfaceView) and
CameraX `PreviewView.ImplementationMode`
(developer.android.com/reference/androidx/camera/view/PreviewView.ImplementationMode).
The WinUI null-against-Transparent rule is from the WPF/UWP lineage and
Avalonia's documentation of the same rule; Microsoft's current WinUI pages
do not state it, so the build reads it (§5 step 0).

What the survey settles: everyone draws later children on top; everyone has
nine positions plus a margin; the field splits on what sizes the box and,
more sharply, on hit testing: Compose passes a tap through any child without
a handler, while SwiftUI, GTK and WinUI block it with anything drawn. That
split is the reason layering needs a ruling at all (LY6).

## §2. What kaya has today, and what layering must fit

### §2.1 The layout model it joins

DESIGN.md, Layout: kaya rides the platform's native layout engines with a
small vocabulary (row, column, grid, spacer) and normalizes semantics, never
metrics. The rules a layered container must keep: a grower renders at its
track and a nested container adopts the box its parent hands it; a scroll
spans its parent's cross axis; `grow` along a scroll's own axis is refused at
the root; `hidden` collapses (no extent, no gap, gone from the accessibility
tree, state kept); a box of only hidden or vacant children is vacant
(docs/media-player-plan.md M16 (3)); leading and trailing, never left and
right. The container props are `spacing`, `align`, `inset` and `inset_x`,
`axis`, `wrap`, `filled`, `ground`, `activatable`; the per-child props are
`grow` and `fill`.

### §2.2 What the styling pass already covers (the album header)

Y3 (docs/styling-pass-plan.md) is an image GROUND on a row or column with
text allowed only inside an `overlay` fill; tools/scenes/grounds.steps'
artist header is exactly "the name on a panel at the foot of the picture".
The music app's album header, a title over the art, IS COVERED by Y3: the
art is the column's ground, the title sits in a filled `overlay` row inside
it, and the column's own layout places it. Layering adds nothing there and
the music app should not move to it. Layering is needed where the thing
underneath is a WIDGET (a video, a surface, a canvas, a button, a list) or
where the thing on top must sit at a corner independent of the base's own
layout: the call's self-view, a badge over an avatar, a loading veil over a
list, the editor's program monitor with a timecode or guides over the
picture.

### §2.3 The media views underneath (the fact most likely to bite)

| backend | the peer (`surface`) | the self-view (`video(capture)`) | a player's video view | another view drawn over it | a video drawn over another view |
|---|---|---|---|---|---|
| macOS, iOS | AVSampleBufferDisplayLayer | AVCaptureVideoPreviewLayer | AVPlayerLayer | yes, a CALayer in the tree (measured on macOS, docs/media-plan.md §1; iOS by the same Core Animation model, unmeasured) | yes, same |
| GTK | GdkMemoryTexture in a picture | GtkPicture over `gtk4paintablesink` | GtkPicture over a paintable | yes, an ordinary widget (no GtkGraphicsOffload in kaya) | yes, same |
| WinUI | WriteableBitmap | WriteableBitmap (docs/traps.md, the WinUI self-view colour) | MediaPlayerElement | yes, "drawn over" (measured, docs/media-plan.md §6) | yes: it is an opaque rectangle in the tree; nothing shows THROUGH it, which an opaque overlay does not need |
| Android | a Compose Image bitmap (KayaFarEnd.kt) | CameraX PreviewView in PERFORMANCE mode, a SurfaceView (KayaCapture.kt) | media3 PlayerSurface, SurfaceView type (KayaMedia.kt) | yes: "The view hierarchy will take care of correctly compositing with the Surface any siblings of the SurfaceView that would normally appear on top of it" (SurfaceView reference) | over WINDOW content, yes (its hole clears what the window drew under it); over ANOTHER SurfaceView, undefined unless the upper one calls `setZOrderMediaOverlay(true)` ("placed on top of another regular surface view in the window (but still behind the window itself)"); three video levels cannot be stacked at all |

The call screen itself is safe on every backend as built: on Android the
peer is a Compose bitmap (window content) and the self-view's SurfaceView
punches through it. What is not safe is a video over a video on Android:
the editor's program monitor with a picture-in-picture, or a self-view over
a peer shown through a player's view. docs/media-plan.md §3 already records
"no interleaving between kaya layers (the video is behind the whole window
or above all of it)". LY7 rules how kaya keeps the semantics uniform anyway.

A second Android fact: PreviewView's own documentation says of PERFORMANCE
mode, "Do not use this mode if the PreviewView needs to be animated". A
layered self-view does not animate under this plan (no drag-to-corner), so
this binds only a later follow-on (§6, Beyond these).

### §2.4 The reads it can build on

The harness reads geometry off the platform (`expect_video_box`,
`expect_gap`, `expect_breadth`, `expect_aligned`), pixels off the window
(`expect_video_ink`, `expect_ground`), and the accessibility tree
(`expect_ax`). `click` is NOT a pointer event on every lane (the SwiftUI arm
emits the button's activation directly), so it cannot read hit testing. A
real pointer route exists on all five: the Mac's `kayaPointerDown`
(`window.sendEvent` with a synthesized mouse-down, in the window, no host
cursor), iOS's resident XCUITest driver (`tap X Y`), Compose's
`kayaTouchTap` (`dispatchTouchEvent` on the decor view; `click_marker` and
`expect_press_takes` use it), GTK's tools/linux/dragdrive.py (`locate`), and
WinUI's `mouse_event` behind `foreground_guest`. No verb reads an
accessibility READING ORDER today.

## §3. The proposal

A new container kind, `layers`, whose first child is the BASE and whose
later children are OVERLAYS.

- **The box is the base's frame.** The base is laid out exactly as it would
  be if it stood in the layers container's place alone: the container's
  `grow`, `fill` and `max_width` act through it, a growing video base fills
  until either axis of its room is used up (docs/media-plan.md §3), and the
  BOX is wherever the base was drawn. A container base adopts the box, the
  nested-container rule.
- **Each overlay is placed in the box** by a new per-child prop `place`, one
  of nine positions (`top_leading`, `top`, `top_trailing`, `leading`,
  `center`, `trailing`, `bottom_leading`, `bottom`, `bottom_trailing`),
  mirrored in a right-to-left layout; `center` when unset, emitted by the
  core so no backend keeps its own default (the row `align` precedent,
  DESIGN.md). `fill = true` on an overlay spans the box on both axes, the
  veil. The container's `inset` (and `inset_x`) is the distance of every
  overlay from the box's edges; the base ignores it.
- **An overlay never moves or enlarges the box.** It is offered at most the
  box less the inset, takes its natural size inside that (capped by
  `max_width` and `max_height` where its kind takes them), and is clipped to
  the box.
- **Declaration order is z-order**, the base at the bottom. No z-index prop.
- **An overlay takes every pointer event inside its own laid-out box**,
  whether or not it has a handler; outside it, events reach what is below.
- **Assistive technology reads the base first, then the overlays in
  declaration order**, pinned on every platform.
- **Text over a picture follows Y3**: a text kind in an overlay over a base
  that is an image, video view, surface, canvas or image-grounded container
  sits inside a `filled` container, or the scene dies at the root naming it.

The lowering, per backend (a sketch for the build; §6 rules the semantics):

| backend | container | base | overlay placement | hits | reading order |
|---|---|---|---|---|---|
| SwiftUI (mac, iOS) | the base view with one `.overlay(alignment:)` per overlay, in order | the base's own view, sized as it would be alone | `.overlay(alignment: place)` with `.padding(inset)` inside, `.frame(maxWidth:maxHeight:)` to the box, `.clipped()` | `.contentShape(Rectangle())` on each overlay's frame | `.accessibilitySortPriority` descending by index under `.accessibilityElement(children: .contain)` |
| Compose | `Box` wrapping the base (the outer modifier carries the weight; an inner wrap-content Box so the box is the base's frame) | first child | each overlay in a `Box(Modifier.matchParentSize().padding(inset))` with `Modifier.align(place)` inside; `clipToBounds` | an empty `pointerInput` on each overlay's box, making it eligible | `isTraversalGroup` on the container, `traversalIndex = i` on each child |
| GTK | `GtkOverlay` | the main child | `halign`/`valign` from `place`, margins from the inset, `FILL` for `fill`; `set_clip_overlay(true)` | GTK's default (an overlay is picked over its whole allocation) | widget order (main child first, overlays as added); read by the scene |
| WinUI | a `Grid` with one cell | the first child, the cell sized to it | alignment and `Margin` per overlay, `Stretch` for `fill` | each overlay wrapped in a `Grid` with a `Transparent` background | child order; read by the scene |

## §4. The guards (invariant 3), each on a path a session walks into

- **`cargo build`**: the spec gains kind `layers` (29), prop `place` (78,
  `PropKind::Enum("place")`) and the `place` enum; the hash moves; a stale
  generator fails the build naming the fix (crates/kaya/build.rs); the pin
  tests (the kind table, PROPS against the "prop" enum) move with it.
- **The root, at declare time** (`check_prop`): `spacing`, `align`, `axis`,
  `wrap`, `filled`, `ground`, `activatable` on `layers` refused by name;
  `bleed` on anything but the base refused.
- **The root, at the end of the transaction** (the wrap-row grow
  precedent, whichever arrives last): `place` on a widget whose parent is not
  `layers`, or on the base; `grow` on any child of `layers` (the container
  carries it); `fill` on the base. Each sentence names the widget, its
  parent and the remedy. Unit tests for every refusal, live and template.
- **Text over a picture** (LY9): `bare_text_on_image` in crates/kaya/src/scene.rs
  and its template twin `check_skin_template` widen from image grounds to
  overlays over a picture base, so the scene dies naming the label; unit
  tests both zones.
- **check-verbs**: the interpreters' KIND_LAYERS and PLACE_* constants, the
  apply arm, the render and the step-verb arms for the three new verbs
  (§6 LY13) in BOTH swift/KayaSwiftUI.swift and KayaCompose.kt; plus a
  LAYERS clause holding each backend's three load-bearing sites, each with a
  watched negative: the Android overlay video lowered to its TextureView
  route (LY7), the hit opacity (SwiftUI `contentShape`, Compose
  `pointerInput`, WinUI `Transparent`), and the reading-order pins
  (SwiftUI sort priority, Compose `traversalIndex`).
- **check-sugar-surface**: rows `Layers` and `Place` in all nine bindings,
  the fake-name negatives the census already runs.
- **check-universal-props**: the new kind takes the a11y props on every
  backend (the gate walks the kind table, so the kind joins by construction).
- **check-targets** and **check-gtk.py**: every backend compiles the arm.
- **check-stubs**: the scene's legs are not wired on a backend while its arm
  still calls `depth_stub`.
- **The scene on every lane in every language** (tools/scenes/layers.steps,
  §6 LY13), which is the wall a broken arm walks into; and chatcall.steps'
  reads of the call screen (LY14).
- **Watched negatives for the scene's reads**, each perturbation's
  substitution count printed: an overlay placed at `top_leading` where the
  scene says `bottom_trailing`; the hit opacity cut on one backend (the tap
  over a label reaches the base button); the reading-order pin cut on
  Compose (TalkBack's geometric order puts a top overlay first); the Android
  overlay video left on SurfaceView in a video-over-video case.

## §5. The build, depth then breadth

0. **Measure first** (half a day, records under docs/measurements): (a) on
   the Android pool, through the lane's own run-leg route, a PlayerSurface
   video under a PreviewView self-view with both on SurfaceView, then the
   upper on TextureView (COMPATIBLE), read by the device's screencap
   (docs/media-plan.md §1's read route); (b) each platform's reading order of
   a ZStack, Box, GtkOverlay and one-cell Grid WITHOUT kaya's pins, so the
   pins are known to be needed or known to be belt and braces; (c) WinUI's
   hit test over a TextBlock overlay with and without a Transparent
   background.
1. **The root**: spec, generators, `check_prop` and end-of-transaction
   refusals, the widened Y3 walk, unit tests, the Rust sugar.
2. **Depth on the Mac**: the SwiftUI arm, `expect_placed`, `tap_at`,
   `expect_ax_order`, the `layers` scene with its Rust guest.
3. **Breadth**: iOS, GTK, WinUI, Compose; the eight other bindings and the
   C floor; check-verbs' and the census's rows; the RTL twin leg.
4. **The call screen** (LY14) and chatcall.steps; capture-plan §12 item 7
   amended.
5. **The review page**: captures of the layers scene and the call screen on
   every lane, each viewed before it is published.

## §6. The rulings

Each is the maintainer's. The mechanism is §0 to §3; the short version is
repeated so each ruling reads on its own.

### LY1. The shape: a container kind, not an overlay slot

The question: does kaya add a container whose children share one box, an
`overlay` slot any widget can carry (SwiftUI's `.overlay`, GTK's
`add_overlay` on a main child), or both?

- **(a) A container kind `layers`**: first child the base, later children
  the overlays. It uses kaya's existing parent and child machinery, both
  zones, every binding's container sugar.
- **(b) An overlay slot on any widget.** kaya's leaves have no children, so
  every node would grow a second child list, the wire a second "add child"
  relation, and every binding a second closure on every widget. What it
  expresses is exactly (a) with the base named differently.
- **(c) Both.** Two spellings of one semantics.

RECOMMEND (a). SwiftUI's own documentation says the `.overlay` modifier is
the way to let "the modified view dominate the layout", which is the base
rule in LY2; GTK's GtkOverlay is a container with a main child. The name:
`layers` (`overlay` is already a tint, `TintOverlay`, and `stack` already
means row and column in DESIGN.md and an entry stack in navigation).

### LY2. What sizes the box: the base, and the box is the base's frame

The mechanism: either the first child sizes the box and the rest float over
it (GtkOverlay, SwiftUI `.overlay`), or the largest child does (ZStack,
Compose Box, Flutter, WinUI's cell).

- **(a) The base.** It is laid out as if it stood alone in the container's
  place, so the container's `grow`, `fill` and `max_width` act through it;
  the box is the frame the base was drawn in. An overlay never moves or
  enlarges it: it is offered at most the box less the inset and clipped to
  the box.
- **(b) The largest child.** A badge a few points too big would grow the
  avatar's slot; a long caption would widen the call screen.

RECOMMEND (a). Every consumer named (self-view over peer, badge over
avatar, veil over content, timecode over the monitor) has a base that should
decide the layout. "The frame the base was drawn in" matters for a growing
video base: it fills until either axis of its room is used up and is centred
there, so the box is the picture, not the track, and a corner overlay sits on
the picture's corner rather than in a band beside it. The Compose and GTK
arms need a wrapper to get that (an inner wrap-content Box; a centred
GtkOverlay), and `expect_placed` reads against the base's frame so a track-
sized box fails.

### LY3. How an overlay is placed: nine positions, the container's inset, `fill` for the veil

- **Position**: a per-child enum prop `place`, nine values
  (`top_leading` ... `bottom_trailing`), leading and trailing mirrored in a
  right-to-left layout. Unset is `center`, and the core emits it at creation
  so no backend keeps its own default (SwiftUI and ZStack default to centre,
  Compose and Flutter to top-start, GTK and WinUI to fill).
- **Inset**: (a) the container's existing `inset`/`inset_x` is every
  overlay's distance from the box's edges, the base ignoring it; or (b) a new
  per-child margin.
- **Fill**: the existing `fill` prop, on an overlay, spans the box less the
  inset on both axes.

RECOMMEND the enum, (a) for the inset, and `fill` for the veil. (a) adds no
prop and covers every named consumer with one inset per container; a child
that needs its own breathing room is an overlay column with an `inset` of its
own. A per-child margin waits for a consumer with two overlays at different
distances. A negative inset (a badge straddling the avatar's edge) is
refused, as `inset` is today.

### LY4. A size relative to the box

The question: should an overlay say "a quarter of the box's width" (Compose
`fillMaxWidth(0.25f)`, SwiftUI `containerRelativeFrame` from macOS 14 and
iOS 17, above kaya's macOS 13 floor)?

- **(a) No new prop**: an overlay takes its natural size, capped by
  `max_width`/`max_height` where its kind takes them (the self-view's 107 pt
  tile is a column's `max_width` today).
- **(b) A `fraction` prop** on an overlay, 0 to 1, of the box's width.

RECOMMEND (a). FaceTime, Meet and Zoom keep a self-view tile of a fixed size
whatever the peer's size; no named consumer needs a fraction. Trigger to
revisit: an overlay whose right size is the base's and not its own.

### LY5. Z-order: declaration order, no z-index

Every toolkit in §1 draws later children over earlier ones. RECOMMEND that
order, the base at the bottom, and no z-index prop (Compose's `zIndex`,
WinUI's `Canvas.ZIndex`): an app that wants a different order declares the
children in that order (a `When` or a keyed `For` rebuilds them).

### LY6. Hits: an overlay takes every pointer event inside its own box

The mechanism: where an overlay sits over the base, which one receives a
tap? §1's split: Compose hands the tap to the topmost child WITH A HANDLER,
so a tap on a caption over a button presses the button; SwiftUI, GTK and
WinUI hand it to whatever is drawn on top (WinUI only where the drawing is,
not in a null-background panel's gaps).

- **(a) Opaque boxes**: an overlay takes every pointer event inside its own
  laid-out box, interactive or not; outside its box, events reach what is
  below. Compose adds an empty pointer input to each overlay's box, WinUI a
  Transparent background, SwiftUI a rectangular content shape; GTK already
  behaves so.
- **(b) Pass-through for what does not take a tap**: labels, images, icons,
  progress, video views and surfaces pass taps through; containers pass
  through their empty area. SwiftUI and GTK cannot switch a container off
  without switching off its children, so this needs a per-leaf walk on two
  backends and a custom `contains` on GTK's containers.
- **(c) (a) plus a per-child `passes_pointer` prop** for the badge over an
  activatable avatar.

RECOMMEND (a), with (c)'s prop left out until a consumer needs it (trigger:
a non-interactive overlay over an activatable base, the badge case). (a) is
what a veil needs (a loading veil that lets taps through is a defect), is one
sentence on every backend, and is what three of four backends already do.
`hidden` overlays take no events, as they take no space.

### LY7. Video over video on Android: the upper video draws in the window

The mechanism (§0, §2.3): an Android SurfaceView's video lives behind the
window. kaya views over it are fine; a SurfaceView over plain window content
is fine; a SurfaceView over ANOTHER SurfaceView has no defined order, and
three video levels cannot be stacked at all.

- **(a) An overlay video draws in the window**: on Android, a video view or
  self-view that is an OVERLAY (not the base) of a layers container lowers to
  its TextureView route: PreviewView `ImplementationMode.COMPATIBLE` ("Use a
  TextureView for the preview"), media3's texture surface type for a player.
  A TextureView is ordinary window content, so every ordering composes. The
  base keeps its SurfaceView. Cost: TextureView composites through the app's
  GPU pass (more power and latency, by PreviewView's own account) and cannot
  show DRM-protected (Widevine L1) video; neither applies to a self-view.
- **(b) `setZOrderMediaOverlay(true)` on the upper SurfaceView**: two video
  levels, exactly; a third is undefined. PreviewView creates its SurfaceView
  internally, so reaching the call is a fight with CameraX.
- **(c) Refuse** a video overlay over a video base at the root. The root
  does not know which platform it runs on, so (c) would refuse on five
  platforms what fails on one, which invariant 1 forbids.

RECOMMEND (a), measured first (§5 step 0 (a)): the semantics stays uniform
(any order, any depth) and the cost lands only on overlay videos on one
platform, which the call's self-view tolerates. The call screen as designed
(a Compose-bitmap peer) does not need it; the editor's monitor with a
picture-in-picture and a self-view over a player's peer would. A side
effect worth having: a TextureView is in the window, so the in-process
PixelCopy read sees an overlay self-view directly (docs/traps.md, the android
red leg's white self-view).

### LY8. Reading order: base first, then overlays in declaration order, pinned everywhere

The mechanism: a screen reader moves through a screen in a linear order.
Compose's TalkBack order is geometric by default ("left-to-right, then
top-to-bottom"), so a self-view at the top of the peer would be read before
the peer, and a badge at an avatar's top-trailing corner before the avatar;
VoiceOver's order for a ZStack is not documented (it is generally
declaration order, unconfirmed); AT-SPI (Orca) and UIA (Narrator) follow the
widget tree's child order.

- **(a) Declaration order on every platform**, pinned: Compose
  `isTraversalGroup` on the container and `traversalIndex = i` on each child;
  SwiftUI `accessibilitySortPriority` descending by index inside a
  `.contain` element; GTK and WinUI by child order, measured.
- **(b) Each platform's own order.** Uniform semantics fails on Compose.

RECOMMEND (a). The base is the content; overlays annotate it ("Maya", then
"You"; the avatar, then "3 unread"). The container is not an accessibility
group unless named, the universal-props rule. Covered content stays in the
tree: a veil is not modal (a modal is a sheet), and an app that wants the
content gone under a veil hides or disables it.

### LY9. Text over a picture: Y3's refusal reaches overlays

The mechanism: Y3 refuses text whose nearest ground is an image unless it
sits in a `filled` container, since text bare on a picture has no contrast
anyone can promise. An overlay over a picture base is the same shape with a
widget for the ground.

RECOMMEND the root refuse a text kind (label, rich label, text controls)
in an overlay whose base is an image, a video view, a surface, a canvas or
an image-grounded container, unless a `filled` container lies between them
(the `overlay` tint is the platform's panel over media), in both zones,
naming the label; buttons, icons, images and canvases stay legal bare, as in
Y3. A badge is a filled label and passes.

### LY10. Safe areas, scroll, hidden and grow

- **Safe areas**: overlays are placed in the box the base was given inside
  kaya's inset and the safe area, never in a bled extent; `bleed` is legal on
  the base only, so a full-bleed peer keeps its self-view and its buttons
  clear of the home indicator (A3's rule that interactive kinds never bleed).
- **Scroll**: a layers container scrolls as one box, overlays with it; a
  button floating over a scroll is a layers container whose base is the
  scroll. Nothing is pinned to the viewport.
- **Grow**: the container takes `grow` and `fill` in its parent like any
  child, under the scroll-axis refusal; its children take no `grow` (refused,
  naming the container as the place to put it).
- **Hidden**: a hidden overlay is not drawn, takes no events and is gone
  from the tree; a hidden base makes the container vacant (it has no box), the
  M16 (3) rule, and its overlays are not shown while it is hidden; an empty
  container is vacant.

RECOMMEND as written.

### LY11. Both zones

RECOMMEND `layers` and `place` in the live zone and in row templates: a
badge over an avatar belongs in a list row. The video view's and surface's
live-only rules are unchanged (a template still cannot hold a surface).

### LY12. The wire, the spec and the guest surface (invariants 2, 5, 7)

The spec (crates/kaya/src/spec.rs): `("layers", 29)` in the kind enum,
`("place", 78, PropKind::Enum("place"))` in PROPS, an EnumSpec `place` with
`top_leading` 1 to `bottom_trailing` 9 and `center` 5 (the keypad order,
which reads in a table). The sugar, construction tier, in every binding:

| binding | spelling | verdict |
|---|---|---|
| Rust | `tx.layers(\|tx\| { ... }).inset(12)`, `.place(Place::BottomTrailing)` | DO |
| Go | `tx.Layers(func() { ... })`, `.Place(kaya.PlaceBottomTrailing)` | DO |
| Python | `with kaya.layers(inset=12):`, `place=kaya.Place.BOTTOM_TRAILING` | DO |
| C# | `tx.Layers(() => { ... })`, `.Place(Place.BottomTrailing)` | DO |
| Java | `tx.layers(() -> { ... })`, `.place(Place.BOTTOM_TRAILING)` | DO |
| Swift | `tx.layers { ... }`, `.place(.bottomTrailing)` | DO |
| OCaml | `Tx.layers tx (fun () -> ...)`, `~place:Place.Bottom_trailing` | DO |
| Haskell | `layers tx $ do ...`, `place PlaceBottomTrailing` | DO |
| JS/TS | `tx.layers(() => { ... })`, `.place(Place.BottomTrailing)` | DO |
| C floor | the generated `KAYA_KIND_LAYERS`, `KAYA_PROP_PLACE`, `KAYA_PLACE_*` through kaya_wire.h; a C guest for the scene as the other C guests do | DO |

No language lacks anything this needs; no CAN'T or DEFER verdict. RECOMMEND
as written; the exact spellings follow each binding's existing container and
enum precedent and check-sugar-surface holds them.

### LY13. The scene and its reads

Three new verbs, each read off the platform:

- `expect_placed <overlay> "<place> <inset>"`: the overlay's frame against
  its base's frame, classified into one of the nine positions with the
  inset ±2 (or `fill`), the `expect_aligned` pattern; the base's frame, never
  the container's slot (LY2).
- `tap_at <target> <place>`: a real pointer event at that point of the
  target's frame through each lane's existing pointer route (§2.4); the
  scene then reads which handler answered with an ordinary `expect`.
- `expect_ax_order <target> <target> ...`: the targets reached in that order
  by the platform's own traversal: the AX children order on the Mac, the
  materialized element order on iOS, the merged semantics tree's traversal
  order on Compose, AT-SPI child order on GTK, the UIA control-view walk on
  WinUI.

tools/scenes/layers.steps, a guest in every language: an image base with a
filled caption at `bottom`, a filled badge at `top_trailing` inset 0, a
button at `bottom_trailing`; a second container with a button base and a
filled label overlay over its centre. Reads: `expect_placed` for each
overlay; `expect_video_ink`-style pixel reads at an overlay's centre proving
it is drawn on top; `tap_at` the overlay button (its handler answers), the
base button away from the overlay (the base answers), and the label over the
base button (nothing answers, LY6); the overlay hidden and the same tap (the
base answers); `expect_ax_order` base, badge, caption, button. A
`layersrtl` twin under KAYA_LOCALE=ar-EG reads `bottom_trailing` on the
left (the tasksrtl precedent). The Android leg adds a player under a
self-view (LY7). RECOMMEND as written.

### LY14. The first consumer: the call screen

RECOMMEND the call screen become a layers container whose base is the
peer's surface, taking `grow` so the peer fills the call's room until either
axis is used up (it took no grow only so the self-view had room below it),
with the self-view as an overlay at `bottom_trailing`, the container's inset
12, keeping its 107x80 4:3 cover tile (the column `max_width` around it
stays). chatcall.steps reads `expect_placed video@selfview "bottom_trailing
12"`, the self-view's ink at its centre (on top of the peer's), the peer's
ink away from the corner, and `expect_ax_order surface@peer video@selfview`.
capture-plan §12 item 7 is amended to record the overlay, the peer's grow,
and the reads; the GAP closes with the build. Alternative: keep the peer at
its natural 320x240 and only move the self-view over it, the smallest
change.

### Beyond these, for the maintainer

- **Dragging the self-view to another corner** (FaceTime's and Meet's
  gesture): not proposed. It needs the overlay's `place` to be the user's
  state with a drag gesture, and on Android an animated PreviewView, which
  PERFORMANCE mode must not be; under LY7 an overlay self-view is already on
  TextureView, so the route is open when a consumer asks.
- **A rounded self-view tile**: Y6's `shape` is image-only and Android
  clips a SurfaceView round only over an opaque ground (docs/media-plan.md
  §1); under LY7 the overlay self-view is a TextureView and clips normally.
  Not proposed until the review page asks for it.
- **A canvas overlay for the editor's guides** (title-safe lines over the
  program monitor): legal under this plan if the canvas draws a transparent
  ground; whether each backend's canvas is transparent where it draws
  nothing is unmeasured and belongs to the editor's own pass.

## §7. Measured, and to be measured

Nothing was measured for this pass; every platform claim above is cited from
the sources in §1 or from kaya's own records (docs/media-plan.md §1 and §3,
docs/capture-plan.md §3 and §11). §5 step 0 measures, before the build relies
on them: Android video over video on SurfaceView and on TextureView; each
platform's unpinned reading order of overlapping children; WinUI's hit test
over a TextBlock with and without a Transparent background.
