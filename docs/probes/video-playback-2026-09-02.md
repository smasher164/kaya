# Video in kaya — research for the video-editor milestone

Written 2026-09-02. RESEARCH ONLY: nothing in the kaya tree was edited.
Every external claim carries a URL. Repo claims carry a file and line.

The question on the table: the maintainer wants the next forcing app to
be a VIDEO EDITOR (timeline with draggable clips, sliders for trim, a
playhead, zoom, volume), says video PLAYBACK is a requirement of the
milestone, and asks whether kaya should also "own the rendering" of
video frames.

---
## Verdict up front

**Ship a platform-player `video` widget kind first. Treat owned rendering as
its own later milestone with its own forcing app. Do not put video through
the canvas — the tree already ruled that out on 2026-08-26.**

The short form of the argument:

- The two toolkits closest to kaya, from opposite architectures, agree.
  .NET MAUI wraps native controls and SHIPPED a MediaElement over
  ExoPlayer/AVPlayer/MediaPlayer. Avalonia draws its own widgets and has NO
  video, and its maintainer's answer is "native control embedding… a wrapper
  per each platform you need to target". Owning the rasterizer bought
  Avalonia nothing here.
- Owning rendering means owning AUDIO too, because A/V sync runs off the
  audio clock. kaya's audio architecture is designed (DESIGN.md:3139) and
  entirely unbuilt. Route (b) is quietly two milestones.
- The bandwidth math is not the blocker people expect — a naive CPU path is
  ~4.85 GB/s at 1080p60 against ~85 GB/s on a flagship phone — but it is 13x
  what a texture path spends, it is power and heat on a phone, and it walls
  hard at 4K (~19 GB/s). And tiny-skia cannot help: it is RGBA8888-only, so
  every frame must be converted before it can be touched.
- The four platform surfaces that WOULD make owned rendering feasible all
  exist (AVSampleBufferDisplayLayer, AndroidExternalSurface, GdkPaintable +
  dmabuf, SwapChainPanel), and kaya does NOT need to build a GPU compositor
  to use them — every backend already sits on a platform compositor. So
  owned rendering is not impossible. What it is, is a SECOND CONTENT MODEL:
  four lifecycles, a harness that can no longer read those pixels, and a
  standing rule that kaya may not draw ON the video (Microsoft says it
  outright: "Don't draw XAML elements on top of video when it's in embedded
  mode"). That is a milestone, not a slice.
- And the naive alternative — pushing frames through each platform's normal
  bitmap path — has the one hard measurement anybody published against it:
  WPF's `WriteableBitmap` costs 70-90 ms per 1080p frame (dotnet/wpf#6411).
  That is four frames' budget to show one.
- **Qt built the owned-frames design and retreated from it.**
  `QVideoSink`/`QVideoFrame` over four native backends is exactly the shape
  under discussion; Qt has made FFmpeg the default on every platform,
  deprecated the Windows Media Foundation backend at 6.10 and MediaCodec at
  6.8, and says "New features will only be implemented on the FFmpeg media
  backend."
- **No editor anywhere asks its UI toolkit to compose a timeline.** Shotcut
  and Kdenlive reach past Qt to MLT; Pitivi reaches past GTK to GES; Olive
  reaches past Qt to FFmpeg; Descript and Clipchamp wrote their own
  compositor over WebCodecs. The media engine has been a separate project
  every single time.

**The one thing to decide before any of it:** what a `video` scene may
assert. kaya's Apple pixel sampling (`drawHierarchy`,
`bitmapImageRepForCachingDisplay`) cannot see a hosted player's frames at
all — that is documented and certain — and whether the Compose harness's
`PixelCopy` can see a SurfaceView-hosted one is the one point this report
found sources on BOTH sides of (§1.0d), so it must be probed rather than
assumed. Either way, a pixel assertion over video is not the free thing it
is over the canvas, and the divergence would show up as a permanent five-lane
red the first time a scene tried it.

---
## §0 — What kaya has already ruled, and why it decides half the question

This section is repo-internal, and it is first because two of the four
questions below are already answered inside the tree; the research only
has to price the remaining ones.

**A `video` widget was already the recommended shape, and it is already
filed.** docs/deferred.md:1500-1507 carries a **Video widget** entry:
"unexamined — DESIGN has the surface-handle transport (~~the Canvas
zero-copy arm~~ the pixel-handoff arm …) but no media-playback story.
The wrap-native bet suggests a Video widget over each platform's native
player (AVPlayerView / MediaPlayerElement / Media3 / GStreamer) before
any frame-pushing pipeline. Trigger-gated on an artifact app." The
video editor IS that artifact app. So the platform-player route is the
tree's own standing recommendation, and the burden of proof sits on the
owned-rendering route, not the other way round.

**Video was explicitly ruled OUT of the canvas and INTO the image
widget.** docs/canvas-plan.md ruling 16 and §16 (2026-08-26): "The
zero-copy arm was never a second canvas. It is the IMAGE widget learning
a high-rate update path for content KAYA DID NOT DRAW: video frames, a
camera, an external engine's output." The split is stated as by WHERE
THE PIXELS COME FROM — canvas is "the app declares ops, the core
rasterizes"; image is "someone else produced the pixels and kaya
presents them". So "kaya owns the rendering" does NOT mean "video goes
through the canvas": that specific combination is already refused.

**The canvas rasterizer's own numbers say a CPU frame path cannot carry
1080p60.** docs/canvas-plan.md §15.2 measured, on an Apple M5 Pro (the
fastest hardware kaya targets), a full-frame raster of the canvas's
particle scene: 1920x1080 @1x = **14.93 ms**, 90% of a 16.6 ms frame;
1200x2400 (a phone at 3x) = **30.30 ms**, 183% of a frame. That is
tiny-skia drawing paths, not blitting a decoded video frame, so it is
not the video number — but it is the ceiling the same thread has to
live under, and it means a canvas that also had to composite video would
be over budget before the video arrived.

**GPU rendering for the canvas buffer is refused ON PRINCIPLE, twice
over.** docs/canvas-plan.md §1.4: driver-dependent antialiasing destroys
the cross-platform byte-identity the harness rests on, and "the linux
lane has no GPU. It is a docker container (tools/linux/Dockerfile), and
a rendering path that cannot run there cannot be one of five lanes'
rendering path." Both halves bear on video: the second is the harder
one, because a video decode path that needs a GPU (or a GStreamer plugin
set, or a Store codec package) has the same "cannot run on the linux
lane" problem.

**The interpreter drop-down policy already licenses hosting a platform
player view.** DESIGN.md:2880-2895 — "where SwiftUI/Compose cannot
express a semantic, the interpreter drops down per widget through the
platform's sanctioned interop (NSViewRepresentable / UIViewRepresentable
/ AndroidView) — the protocol never names a toolkit, observable
semantics stay uniform, intersection-first, and each drop-down is
recorded here with its conformance scene." Three drop-downs exist today
(KayaMacButton, KayaMacTextarea, KayaUITextView). A `video` kind hosting
AVPlayerLayer / a media3 Surface would be the fourth, fifth and sixth —
in the shape the document already sanctions, with a named conformance
scene.

**The blit primitive on each backend today, which is what a frame would
have to ride:**

| backend | canvas blit primitive | file |
| --- | --- | --- |
| SwiftUI | `CGImage` built per raster from a `CGDataProvider` over the core's premultiplied-RGBA bytes | swift/KayaSwiftUI.swift:305, :11117-11128 |
| Compose | `ImageBitmap` in a `mutableStateOf` on the scene model | android/…/KayaCompose.kt:349 |
| GTK4 | `GdkMemoryTexture` inside a custom `KayaCanvas` paintable | crates/kaya/src/gtk.rs:1157, :6049-6181 |
| WinUI 3 | a `WriteableBitmap` whose pixel buffer the core writes straight into, shown in an `Image` | crates/kaya/src/winui/mod.rs:119, :8857-8903 |

One structural note worth carrying into §2: **GTK's arm is already
paintable-shaped.** `KayaCanvas` takes any `GdkPaintable`
(gtk.rs:6118, :6181), so swapping a `GdkMemoryTexture` for a
`GdkDmabufTexture` or a decoder's paintable is a substitution inside one
widget rather than a new widget. The other three arms are bitmap-typed
and would each need a different primitive for a per-frame path.

**A `slider` kind already exists** (spec.rs:2356, kind 7), so the
editor's trim/zoom/volume sliders need no new kind — which matters when
weighing how much of the editor is actually new surface.

**Where the milestone sits.** Drag and drop is the current milestone
(docs/dnd-plan.md, design pass 2026-09-02) and the timeline's draggable
clips are its natural forcing app; video playback is a second,
independent axis. The two can be sequenced.

### §0.1 What this means for kaya

Two of the four questions are pre-answered by the tree: video does not
go through the canvas (ruling 16), and a native-player `video` kind is
the standing recommendation (deferred.md's Video widget entry). The live
questions are therefore narrower than they look: (a) can a native player
be hosted on all five backends with uniform observable semantics, (b)
does a video EDITOR need more than a player, and (c) if it does, what is
the cheapest thing that supplies the extra.

---
## §1 — The platform-player route

### §1.0 The closest precedent: .NET MAUI's MediaElement

Before the per-platform detail, the strongest single piece of evidence:
**the toolkit architecturally closest to kaya has already shipped this
exact widget, and its API surface is public.** MAUI shares kaya's
wrap-native bet, and `CommunityToolkit.Maui.MediaElement` is a `video`
kind over each platform's own player:

| Platform | MAUI's player |
| --- | --- |
| Android | ExoPlayer |
| iOS/macOS | AVPlayer |
| Windows | `Windows.Media.Playback.MediaPlayer` |
| Tizen | Tizen.Multimedia.Player |

<https://learn.microsoft.com/en-us/dotnet/communitytoolkit/maui/views/mediaelement>

**Its whole property/method/event surface** (same URL) is a ready-made
template for what a kaya `video` kind's props and occurrences would be:

- Properties: `Source`, `Aspect` (AspectFit / AspectFill / Fill),
  `CurrentState`, `Duration` (read-only), `Position` (read-only),
  `ShouldAutoPlay`, `ShouldLoopPlayback`, `ShouldKeepScreenOn`,
  `ShouldMute`, `ShouldShowPlaybackControls`, `Speed`, `Volume`,
  `MediaWidth`, `MediaHeight`, `MetadataTitle`/`MetadataArtist`/
  `MetadataArtworkUrl`.
- Methods: `Play`, `Pause`, `Stop`, `SeekTo(TimeSpan)`.
- Events: `MediaOpened`, `MediaEnded`, `MediaFailed`, `PositionChanged`,
  `SeekCompleted`.
- States: `None`, `Opening`, `Buffering`, `Playing`, `Paused`,
  `Stopped`, `Failed`.

Four things in that surface are worth carrying into kaya's design
verbatim, because they are shape decisions someone else already paid
for:

1. **`Position` is READ-ONLY and seeking is a METHOD.** "If you want to
   set the `Position` use the `SeekTo()` method." That is exactly kaya's
   own grammar — a mirror the app reads plus a command the app sends —
   rather than a writable prop.
2. **Platform transport controls are optional and the app is expected to
   draw its own.** MAUI ships `ShouldShowPlaybackControls` and a
   documented "Implement custom transport controls" recipe using its own
   Buttons and a `Slider` bound to `Volume`. An editor wants exactly
   this: no platform chrome, kaya's own scrubber. Note the honest
   caveat: "on iOS and Windows the controls are only shown for a brief
   period after interacting with the screen. There is no way of keeping
   the controls visible at all times" — i.e. the platform chrome is NOT
   uniform, which is another reason to turn it off.
3. **Android's view type is a per-widget choice with a stated cost.**
   "The platform default behavior is to use `SurfaceView`. Using Texture
   View adds support to allow transparencies and other effects… We do
   not recommend using TextureView unless you have a specific need for
   it. It has possible performance related issues if enabled and is
   recommended only for those that need transparencies and other
   advanced features." That is the SurfaceView z-order trap, priced by
   someone who shipped it.
4. **Platform setup leaks into the app package**: iOS/Mac Catalyst need
   `UIBackgroundModes` `audio` in Info.plist; Android needs
   `ResizeableActivity = true`, `LaunchMode.SingleTask`, and an opt-in
   foreground service for background playback. kaya's app-identity /
   packaging machinery would have to grow entries for these.

**And the two negative findings matter more than the positive ones:**

- **There is no Linux row.** MediaElement is "available on iOS,
  Android, Windows, macOS, and Tizen" (same URL). The four platforms
  kaya shares with MAUI are the four with a shipped precedent; kaya's
  fifth — GTK4 on Linux, in a container — is the one nobody in this
  class of toolkit has done.
- **Windows codec coverage is not a given.** "On Windows the supported
  formats are very much dependent on what codecs are installed on the
  user's machine", and: "If the user is using a Windows N edition, no
  video playback is supported by default. Windows N editions have no
  video playback formats installed by design." For iOS/macOS the docs
  concede "No official documentation on this exists" and link a
  StackOverflow answer. So **per-platform codec coverage is genuinely
  non-uniform and partly undocumented** — which collides head-on with
  invariant 6's byte-shared scenes if a scene ever asserts on decoded
  pixels.

### §1.0b The counter-precedent: Avalonia, a core-drawn toolkit, has no video

Avalonia is the other .NET cross-platform toolkit, and it is architecturally
the OPPOSITE of MAUI: it draws its own widgets with its own renderer, the way
kaya's canvas draws its own pixels. If owning rendering made video easy,
Avalonia would have video. It does not.

- "Avalonia doesn't have a built-in MediaPlayer control yet (it's going to
  change with new tools we are currently building)" — maxkatz6, Avalonia
  maintainer, <https://github.com/AvaloniaUI/Avalonia/discussions/17801>
- "You can use native control embedding, via NativeControlHost. But it would
  require writing a wrapper per each platform you need to target." — same
  maintainer, same URL. That sentence is kaya's own drop-down policy
  (DESIGN.md:2880) written by a peer project, for exactly this widget.
- The ecosystem answer is LibVLCSharp's `VideoView`
  (<https://github.com/videolan/libvlcsharp/blob/3.x/src/LibVLCSharp.Avalonia/README.md>),
  which is desktop-only — the community notes it does not work on Android and
  that `NativeControlHost` with different controls per platform is the way
  round it (<https://github.com/AvaloniaUI/Avalonia/discussions/10683>,
  <https://github.com/tomlm/Iciclecreek.Avalonia.Controls.Media>).

**What this means for kaya.** Two toolkits, opposite architectures, same
answer: video is a hosted native surface per platform. The one that wraps
native controls (MAUI) shipped it; the one that draws its own (Avalonia) still
has not, and when its maintainer describes the route it is native embedding
per platform. Owning the rasterizer bought Avalonia nothing here, which is the
single most direct piece of evidence against "kaya should own video rendering
because kaya already owns canvas rendering".

### §1.0c The harness problem nobody else has: a hosted player's pixels are not readable the way kaya reads pixels today

This subsection is the one finding in the report that comes from reading
kaya's own harness against the platform facts, and it should be settled
before an arm is written, because it decides what a `video` scene can
assert — and invariant 6 says a scene's assertions are byte-identical on
five platforms.

**How `expect_ink` reads pixels today, per backend:**

| backend | sampling call | captures a hosted video layer? |
| --- | --- | --- |
| Compose | `PixelCopy.request(activity.window, src, bitmap, …)` — KayaCompose.kt:4060 | **YES** |
| SwiftUI (iOS) | `view.drawHierarchy(afterScreenUpdates:)` inside a `UIGraphicsImageRenderer` — KayaSwiftUI.swift:4670-4676 | **NO** |
| SwiftUI (macOS) | `content.bitmapImageRepForCachingDisplay(in:)` — KayaSwiftUI.swift:10755 | **NO** |
| GTK4 / WinUI | (their own arms; both read the core's blit target) | n/a today |

- Android: `PixelCopy` is precisely the API that exists BECAUSE
  `View.draw(canvas)` cannot capture a SurfaceView — "SurfaceView and
  VideoView render their content directly onto a separate hardware
  surface managed by the window manager… calling `view.draw(canvas)`
  produces only a black area"; PixelCopy (API 24+) copies from the
  window's surface instead.
  <https://androiderrors.com/android-take-screenshot-of-surface-view-shows-black-screen/>,
  <https://medium.com/@mohamedtahadawoud/capturing-screenshots-of-surfaceview-and-videoview-in-jetpack-compose-f02277729d04>
  **kaya's Compose harness already uses PixelCopy on the window**, so the
  one Android trap that would have blocked a pixel observable is already
  avoided — by accident, but avoided.
- Apple: the two calls kaya uses are the two that are documented NOT to
  capture video. `renderInContext:` "doesn't render this kind of
  'special' layers", and even `drawViewHierarchyInRect:afterScreenUpdates:`
  gives "always a black image" over the video area.
  <https://www.appsloveworld.com/objective-c/100/16/ios-avplayer-getting-a-snapshot-of-the-current-frame-of-a-video>,
  <https://developer.apple.com/forums/thread/693299>

**The consequence, stated plainly.** If a `video` scene tries to assert a
pixel, the mac and iOS legs read black while the android leg reads the
frame — a divergence in the HARNESS, not in the feature, and one that
five-lane byte-comparison would surface as a permanent red. Three ways
out, in increasing cost:

1. **Assert semantics, not pixels.** `expect_position`,
   `expect_duration`, `expect_playback_state`, `expect_media_size`, an
   `ended` occurrence. These are byte-comparable on all five and are what
   a player widget is actually for. This is what the MAUI surface exposes
   too (§1.0), and it is almost certainly the right answer.
2. **Assert the DECODER's frame rather than the composited surface**,
   where a pixel check is genuinely wanted (e.g. "the right frame is
   showing after a seek"). Every platform has a route to the decoded
   frame that does not go through the compositor —
   `AVPlayerItemVideoOutput.copyPixelBuffer(forItemTime:)` on Apple,
   `MediaMetadataRetriever`/frame callbacks on Android, `MediaPlayer`'s
   frame-server mode on Windows, a GStreamer appsink tee on GTK. This is
   a stronger observable than a screen sample anyway: it reads what the
   decoder produced rather than what the compositor drew. It is also
   MORE work per backend than the whole rest of the widget.
3. **A new screen-capture route on Apple** (`CGWindowListCreateImage` /
   ScreenCaptureKit on macOS). Rejected on sight: macOS screen capture
   needs a TCC permission prompt, which no headless lane can answer.

**And the codec problem sits on top of it.** Even with route 2, the same
H.264 file decoded by VideoToolbox, MediaCodec, Media Foundation and
GStreamer will not produce byte-identical RGB — different chroma
upsampling, different YUV-to-RGB matrices, different rounding. The
canvas's ±1-per-channel tolerance (docs/canvas-plan.md §7.2, ruled
2026-08-26) was calibrated for one rasterizer's output crossing a display
profile; it is far too tight for four decoders. So even a
decoder-frame observable would need either a much wider tolerance or a
test clip engineered to be flat-colour (a solid-fill video, where every
decoder agrees in the interior for the same reason `expect_ink` samples
only "centres of flat-filled regions" today, docs/canvas-plan.md §7.2).

**Recommendation for the harness, if the platform-player route is
taken:** semantic observables only (route 1), plus a synthetic flat-colour
test clip so that ONE `expect_ink` per lane can prove the frames actually
reached the screen — the same division the canvas already uses, where the
hash proves the computation and `expect_ink` proves the blit
(docs/canvas-plan.md §7.4's "the blit deleted from one backend, watched
red on `expect_ink` and GREEN on the hash").

**The precedent for a semantic observable is already in the tree.** The
IMAGE widget — the other kind whose pixels kaya did not produce — is
asserted by its DECODED SIZE, never by its pixels:
`expect image#0 "64x64"` (tools/scenes/assets.steps:8),
`expect image#0 "2x2"` and `expect image#1 "0x0"` for deliberately
invalid bytes (tools/scenes/gallery.steps:8-9). A `video` kind asserting
`"1920x1080"` plus position/state/duration is the same shape one kind
over, and it is byte-comparable on five platforms without any decoder
agreeing with any other.

**One packaging note.** A test clip would live in `guests/assets/`,
which is 944 KB today (fonts 124 KB, market 788 KB) and is staged to
every lane AS A UNIT, with its listing frozen in
tools/scenes/assets.steps and enforced by tools/check-assets.py. A
synthetic flat-colour clip of a few seconds at a small resolution is
tens of kilobytes and fits that budget; a real 1080p clip does not
belong there. Adding any file reddens five lanes until the census line
is updated — which is the documented, intended behaviour of that gate.

### §1.0d ONE DISAGREEMENT IN THIS REPORT, AND IT MUST BE MEASURED

The Android research and the general Android literature disagree about
whether kaya's existing Compose sampling call can read a SurfaceView-hosted
video, and the repo's own doctrine says a disagreement like this is settled
by a probe, not by picking a side.

- **The claim that it CAN**: `PixelCopy` exists precisely because
  `View.draw(canvas)` cannot capture a SurfaceView, and it is the standard
  fix — "SurfaceView and VideoView render their content directly onto a
  separate hardware surface managed by the window manager… calling
  `view.draw(canvas)` produces only a black area", with PixelCopy given as
  the answer.
  <https://androiderrors.com/android-take-screenshot-of-surface-view-shows-black-screen/>
- **The claim that it CANNOT**: a SurfaceView "punches a hole" in the
  window's own surface and is composited by SurfaceFlinger as a separate
  layer, so a copy taken from the WINDOW may read the hole rather than the
  video. kaya's call is the window overload —
  `PixelCopy.request(activity.window, src, bitmap, …)`
  (KayaCompose.kt:4060) — not the SurfaceView overload.

Both readings are defensible because there are two PixelCopy overloads and
the literature usually shows the SurfaceView one. **The probe is ten minutes:
play a solid-colour clip in a SurfaceView on the emulator and run kaya's own
`kayaCanvasInk` path against it.** Until that is run, no plan should assume
either answer — and per invariant 3 the result belongs in docs/traps.md
whichever way it falls, because it decides whether the Android video leg can
assert a pixel at all.

### §1.1 Apple and Windows: the per-platform detail
Research date: 2026-09-02. Every claim carries a URL. Primary sources preferred.

STATUS: COMPLETE.

##### APPLE 1 — The three hosting options, and who owns the chrome

| Option | Framework | Availability | Built-in transport controls? | Can they be turned off? |
|---|---|---|---|---|
| SwiftUI `VideoPlayer` | AVKit | iOS 14+, macOS 11+, tvOS 14+, watchOS 7+, visionOS 1+ | YES, always | **NO** (no API) |
| `AVPlayerView` | AVKit / AppKit | macOS 10.9+ | yes by default | **YES** — `controlsStyle = .none` |
| `AVPlayerViewController` | AVKit / UIKit | iOS 8+, tvOS 9+, visionOS 1+, Mac Catalyst 13.1+ | yes by default | **YES** — `showsPlaybackControls = false` |
| `AVPlayerLayer` | AVFoundation | iOS 4+, macOS 10.7+, tvOS 9+, visionOS 1+ | **NONE, ever** | n/a — it is a bare `CALayer` |

- SwiftUI `VideoPlayer` abstract, verbatim: "A view that displays content from a player **and a native user interface to control playback**." Two initializers only: `init(player:)` and `init(player:videoOverlay:)`. The overlay draws *on top of* the system chrome; it does not replace it. https://developer.apple.com/documentation/avkit/videoplayer
- **`VideoPlayer` cannot hide its controls.** Confirmed by an Apple DTS engineer on the developer forums (Sept 2024): the answer was "use `AVPlayerViewController.showsPlaybackControls`", and when the asker pushed back that they wanted it on `VideoPlayer` itself, the engineer's advice was to file a Feedback Assistant enhancement request. https://developer.apple.com/forums/thread/763837
- `AVPlayerView.controlsStyle` takes `AVPlayerViewControlsStyle`, whose cases are `.none`, `.inline`, `.floating`, `.minimal`, `.default`. `.none` = "No controls displayed". https://developer.apple.com/documentation/avkit/avplayerview/controlsstyle-swift.property and https://developer.apple.com/documentation/avkit/avplayerview/controlsstyle-swift.enum
- `AVPlayerViewController.showsPlaybackControls` — "A Boolean value that indicates whether the player view controller shows playback controls." Note: AVKit docs state the framework **does not support subclassing `AVPlayerViewController`**; embed it as a child view controller instead. https://developer.apple.com/documentation/avkit/avplayerviewcontroller/showsplaybackcontrols
- `AVPlayerLayer` is `class AVPlayerLayer : CALayer`, abstract "An object that presents the visual contents of a player object." It has `player`, `videoGravity`, `videoRect`, `isReadyForDisplay`, `pixelBufferAttributes`, `displayedPixelBuffer()` (deprecated) and `displayedReadOnlyPixelBuffer()`. No chrome of any kind. The documented idiom is a view whose `layerClass` IS `AVPlayerLayer`. https://developer.apple.com/documentation/avfoundation/avplayerlayer

**Verdict for kaya:** the escape hatch that gives a host framework total control of chrome is either
(a) `AVPlayerLayer` inside an `NSView`/`UIView` whose `layerClass` is `AVPlayerLayer` (one code path, both platforms, zero chrome, no AVKit dependency), or
(b) `AVPlayerView(controlsStyle: .none)` on macOS + `AVPlayerViewController(showsPlaybackControls: false)` on iOS (two code paths, but you inherit AirPlay/PiP routing and Now Playing plumbing for free).
`VideoPlayer` (SwiftUI) is unusable for a framework that draws its own transport, on any OS version to date.

##### APPLE 2 — The app-controllable `AVPlayer` surface

All from https://developer.apple.com/documentation/avfoundation/avplayer (iOS 4+/macOS 10.7+ unless noted).

- **Transport:** `func play()`, `func pause()`, `var rate: Float`, `var defaultRate: Float` (iOS 16+/macOS 13+ — "A default rate at which to begin playback"; this is the one to set so `play()` resumes at your chosen speed rather than 1.0). https://developer.apple.com/documentation/avfoundation/avplayer/defaultrate
- **Seek, four spellings:** `seek(to:)`, `seek(to:completionHandler:)`, `seek(to:toleranceBefore:toleranceAfter:)`, `seek(to:toleranceBefore:toleranceAfter:completionHandler:)`, plus two `Date`-based forms for live streams. **Frame-accurate seeking = pass `.zero` for both tolerances** (documented: "the seek is achieved as efficiently as possible … pass `kCMTimeZero` for both to request sample accurate seeking, which may incur additional decoding delay"). https://developer.apple.com/documentation/avfoundation/avplayer/seek(to:tolerancebefore:toleranceafter:)
- **Audio:** `var volume: Float` (0.0–1.0), `var isMuted: Bool`. Both are per-player, independent of system volume. https://developer.apple.com/documentation/avfoundation/avplayer/volume
- **Position:** `func currentTime() -> CMTime` (a snapshot), `addPeriodicTimeObserver(forInterval:queue:using:)` (returns an opaque token; you MUST hold the token and call `removeTimeObserver(_:)`), `addBoundaryTimeObserver(forTimes:queue:using:)`. https://developer.apple.com/documentation/avfoundation/avplayer/addperiodictimeobserver(forinterval:queue:using:)
- **State:** `var timeControlStatus` (`.paused` / `.waitingToPlayAtSpecifiedRate` / `.playing`) — this is the property to mirror, NOT `rate == 0`, because a stalled player has rate 0 but status `.waitingToPlayAtSpecifiedRate`; `var reasonForWaitingToPlay`; `var status`; `var error`. https://developer.apple.com/documentation/avfoundation/avplayer/timecontrolstatus
- **End of playback:** `var actionAtItemEnd` (`.advance` / `.pause` / `.none`) and the notification `AVPlayerItem.didPlayToEndTimeNotification` (Obj-C `AVPlayerItemDidPlayToEndTimeNotification`), posted by the **item**, not the player. Siblings worth wiring: `failedToPlayToEndTimeNotification`, `playbackStalledNotification`, `timeJumpedNotification`. https://developer.apple.com/documentation/avfoundation/avplayeritem/didplaytoendtimenotification
- **Duration:** on the **item** (`AVPlayerItem.duration`) or the asset. Since iOS 16/macOS 13 the synchronous `AVAsset.duration` is deprecated in favour of the async `try await asset.load(.duration)`; the whole `AVAsset` surface moved to async property loading and `AVURLAsset` is the concrete class to construct. https://developer.apple.com/documentation/avfoundation/avasset/load(_:) and https://developer.apple.com/documentation/avfoundation/loading-media-data-asynchronously
- **Looping:** two mechanisms. (1) `AVPlayerLooper` over an `AVQueuePlayer` — the supported, gapless one; it internally enqueues copies of the item. (2) hand-rolled: observe `didPlayToEndTimeNotification` and `seek(to: .zero)` — simpler, but has a visible hitch at the wrap. https://developer.apple.com/documentation/avfoundation/avplayerlooper (iOS 10+, macOS 10.12+)

###### APPLE 2b — Frame extraction

Two mechanisms, for two different jobs:

**(a) Live frames during playback — `AVPlayerItemVideoOutput`** (iOS 6+, macOS 10.8+). https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput
- You attach it to the `AVPlayerItem` (`item.add(output)`), then PULL: `hasNewPixelBuffer(forItemTime:)` then `copyPixelBuffer(forItemTime:itemTimeForDisplay:)` returning a `CVPixelBuffer?`. https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput/copypixelbuffer(foritemtime:itemtimefordisplay:)
- **`copyPixelBuffer(forItemTime:itemTimeForDisplay:)` is now DEPRECATED**, replaced by `pixelBufferAndDisplayTime(forItemTime:)` which returns a `CVReadOnlyPixelBuffer` (the read-only pixel-buffer type is new in the 2025/26 SDKs; the deprecated call still works). https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput/pixelbufferanddisplaytime(foritemtime:)
- It is a **pull** model driven off `CADisplayLink` (iOS) / `CVDisplayLink` or `NSView.displayLink(target:selector:)` (macOS); the "when is data coming" callback is `AVPlayerItemOutputPullDelegate.outputMediaDataWillChange(_:)`, armed with `requestNotificationOfMediaDataChange(withAdvanceInterval:)`. https://developer.apple.com/documentation/avfoundation/avplayeritemoutputpulldelegate
- Cost: attaching a video output forces the pipeline to hand you CPU/IOSurface-backed buffers each frame; this is the standard route for "render the video into my own Metal/CoreImage surface".
- Cheaper alternative if you only need the CURRENTLY DISPLAYED frame and are already using `AVPlayerLayer`: `AVPlayerLayer.displayedReadOnlyPixelBuffer()` (and the deprecated `displayedPixelBuffer()`). https://developer.apple.com/documentation/avfoundation/avplayerlayer

**(b) Poster / thumbnail / first frame — `AVAssetImageGenerator`** (iOS 4+, macOS 10.7+). https://developer.apple.com/documentation/avfoundation/avassetimagegenerator
- Modern API: `func image(at: CMTime) async throws -> (image: CGImage, actualTime: CMTime)` and `func images(for: [CMTime]) -> AVAssetImageGenerator.Images` (an AsyncSequence). `copyCGImage(at:actualTime:)` is deprecated.
- **Two properties are traps for a poster frame:** `requestedTimeToleranceBefore` / `requestedTimeToleranceAfter` default to `.positiveInfinity`, so "give me frame at t=0" can return a frame seconds away; set both to `.zero` for the exact frame. And `appliesPreferredTrackTransform` defaults to **false**, so a portrait video shot on a phone comes back sideways unless you set it true. https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/appliespreferredtracktransform

##### APPLE 3 — Hardware decode and codec coverage

**What AVPlayer gets for free.** AVFoundation sits on VideoToolbox, which sits on the platform's hardware decoders; an app that uses `AVPlayer` never calls VideoToolbox and never chooses a decoder — the framework picks hardware when hardware exists for that codec and falls back to Apple's own software decoders where Apple ships one. The runtime probe for "is there silicon for this" is `VTIsHardwareDecodeSupported(_:)`, which "returns a Boolean value that indicates whether the current system supports hardware decode for the specified codec." https://developer.apple.com/documentation/videotoolbox/vtishardwaredecodesupported(_:)

**Codec coverage:**
- **H.264/AVC** — universal. Hardware decode on every Mac and every iOS device kaya could target.
- **HEVC/H.265** — hardware decode from A9/iPhone 6s and from Intel 6th-gen Skylake Macs (macOS 10.13 High Sierra was the release that put HEVC into AVFoundation systemwide); universal on Apple silicon. Apple's HEVC/HLS guidance: https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices
- **ProRes** — decode is available on macOS broadly (it is a QuickTime codec, `kCMVideoCodecType_AppleProRes422` and friends in CoreMedia); hardware ProRes accelerators shipped with M1 Pro/Max and A15 Bionic-era Pro iPhones. Constants: https://developer.apple.com/documentation/coremedia/kcmvideocodectype_appleprores422
- **AV1** — `kCMVideoCodecType_AV1` exists in CoreMedia (https://developer.apple.com/documentation/coremedia/kcmvideocodectype_av1). **Hardware AV1 decode is A17 Pro (iPhone 15 Pro) and M3 and later**, plus M4 iPad Pro; developers confirmed `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) == true` on iPhone 15 Pro in Oct 2023 (https://developer.apple.com/forums/thread/722933). There is an `AV1DecoderSW.bundle` on macOS but it was **not enabled** when probed — `VTDecompressionSessionCreate` returned `kVTCouldNotFindVideoDecoderErr` on non-AV1 hardware (same thread). Third-party summary of the hardware matrix: https://bitmovin.com/blog/apple-av1-support/ . So: **on pre-M3 Macs and pre-A17-Pro phones, AV1 does not play at all** — there is no software fallback you can rely on.
- **VP9** — **NOT available to AVPlayer.** `VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)` returns false on iOS devices and `VTDecompressionSessionCreate` fails with -12906 (could not find decoder); VP9 hardware decode on Apple silicon Macs is reachable only by Safari/WebKit, which holds an entitlement ordinary apps do not. https://developer.apple.com/forums/thread/664770 and https://github.com/iina/iina/issues/3241
- **Not supported at all by AVFoundation:** VP8, Theora/Ogg, and — the big one for a general-purpose `video` widget — **Matroska (.mkv) and WebM containers**. `AVURLAsset.audiovisualTypes()` is the authoritative runtime list and returns UTIs like `com.apple.quicktime-movie`, `public.mpeg-4`, `public.avi`, `public.3gpp`, `public.3gpp2` plus audio types; no Matroska/WebM UTI is in it. https://developer.apple.com/documentation/avfoundation/avurlasset/audiovisualtypes()
- Practical container set: **.mov, .mp4, .m4v, .3gp** (+ HLS `.m3u8` over http/https). Anything else needs a third-party demuxer.

**The design consequence for kaya:** `AVURLAsset.audiovisualTypes()` / `AVURLAsset.isPlayableExtendedMIMEType(_:)` are the honest capability query for a `video` widget — the widget should be able to answer "can this platform play this file" rather than silently showing a black rectangle. https://developer.apple.com/documentation/avfoundation/avurlasset/isplayableextendedmimetype(_:)

##### APPLE 4 — Embedding in an arbitrary SwiftUI hierarchy

**Yes, and it is the normal thing to do.** `NSViewRepresentable` / `UIViewRepresentable` wrap an AppKit/UIKit view; SwiftUI hosts it as a real subview of the hosting view, so it obeys the parent's frame, participates in z-order (`.zIndex`, ZStack ordering) and is clipped by ancestor clips. https://developer.apple.com/documentation/swiftui/nsviewrepresentable and https://developer.apple.com/documentation/swiftui/uiviewrepresentable
`AVPlayerViewController` needs `UIViewControllerRepresentable` (it is a view controller, and AVKit documents that subclassing it is unsupported — embed it as a child). https://developer.apple.com/documentation/swiftui/uiviewcontrollerrepresentable

**Known limits worth designing around:**
1. **Rounded-corner clipping of a layer-backed representable is unreliable.** `.clipShape(RoundedRectangle(...))` over a `UIViewRepresentable` hosting an `AVPlayerLayer` is reported not to clip; the working spellings are `.mask(RoundedRectangle(...))`, or setting `cornerRadius` + `masksToBounds` on the AVPlayerLayer itself. Reported at https://developer.apple.com/forums/thread/707915 and https://chris-mash.medium.com/avplayer-swiftui-b87af6d0553 . (Mechanism: SwiftUI's clip is applied to the host view's layer; a sublayer with its own `masksToBounds == false` and a non-integral corner is the case that leaks.)
2. **`ScrollView` clips its content by default** — that is normally what you want, but it also means a video that overflows the scroll bounds is cut, not overdrawn. https://developer.apple.com/forums/thread/653827
3. **`.drawingGroup()` must not be applied above a video.** It flattens the subtree into a single offscreen Metal-rendered image (documented as "Composites this view's contents into an offscreen image before final display"); a live `AVPlayerLayer` beneath it will not composite correctly. https://developer.apple.com/documentation/swiftui/view/drawinggroup(opaque:colormode:)
4. **Cost of the representable**: `updateNSView`/`updateUIView` is called on every SwiftUI invalidation. Constructing an `AVPlayer` in `makeUIView` and never in `update` is the rule; the documented SwiftUI idiom on the `VideoPlayer` page itself is `@State` + `.task` so the player is created exactly once. https://developer.apple.com/documentation/avkit/videoplayer
5. **`AVPlayerLayer` in a `layerClass` override is the cheapest hosting** — one layer, no extra view, no AVKit. Apple's own documented pattern. https://developer.apple.com/documentation/avfoundation/avplayerlayer

##### APPLE 5 — The traps

**5a. iOS silent switch / audio session.** The default `AVAudioSession` category is `soloAmbient`, which IS silenced by the Ring/Silent switch and by screen lock. Apple's own table (Audio Session Programming Guide, Table B-1) lists "Silenced by the Ring/Silent switch and by screen locking": **Ambient = Yes, Solo Ambient (default) = Yes, Playback = No, Record = No, Play and Record = No.** https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioSessionCategoriesandModes/AudioSessionCategoriesandModes.html
So a video widget on iOS that does nothing plays **silently whenever the ringer switch is on** — the single most-reported "my video has no sound" bug. The fix is one line at startup: `try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)` then `setActive(true)`. https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback and https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/movieplayback
- Choosing the category is a POLICY decision a GUI framework should not make silently: `.playback` also **interrupts other apps' audio** by default (add `.mixWithOthers` not to), and continues over screen lock. `.ambient` is the "my sound is decorative" answer. For kaya this is a widget prop / app-level setting, not a hard-coded default.
- macOS has no `AVAudioSession` at all — the whole class is iOS/tvOS/watchOS/visionOS. This is a legitimate spelling divergence, not a semantic one.

**5b. Background/foreground.** `AVPlayer.audiovisualBackgroundPlaybackPolicy` (`.automatic` / `.pauses` / `.continuesIfPossible`) is the documented knob; **video** (as opposed to audio) is suspended when the app backgrounds unless the app declares the `audio` `UIBackgroundModes` key AND detaches the video output. https://developer.apple.com/documentation/avfoundation/avplayer/audiovisualbackgroundplaybackpolicy

**5c. Now Playing.** `MPNowPlayingInfoCenter` is available on **macOS 10.12.2+** as well as iOS 5+, and `MPNowPlayingInfoCenter.playbackState` is macOS-only. https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter
The AVKit views do it for you and can be told not to: `AVPlayerView.updatesNowPlayingInfoCenter` (macOS, defaults true) and `AVPlayerViewController.updatesNowPlayingInfoCenter`. **If kaya hosts a bare `AVPlayerLayer`, nothing populates Now Playing** — the media keys and Control Center will not drive the video. That is a real feature difference between the two hosting choices. https://developer.apple.com/documentation/avkit/avplayerview/updatesnowplayinginfocenter

**5d. Deallocation and KVO.** Two distinct crashes:
- "An instance of `AVPlayer`/`AVPlayerItem` was deallocated while key value observers were still registered with it" — an `NSInternalInconsistencyException`, not a soft failure. Any KVO on `status`, `timeControlStatus`, `currentItem`, `rate` must be torn down before the player goes.
- `removeTimeObserver(_:)` **must be called on the same `AVPlayer` that vended the token**; passing a token from another player throws. https://developer.apple.com/forums/thread/738066
For a framework this means the player, its observers and its observation tokens are one owned unit with a deterministic teardown — exactly the kind of thing a `video` widget's destroy path has to get right, because the failure mode is a hard crash rather than a leak.
- Also: **you must retain the `AVPlayer`.** A player held only by an `AVPlayerLayer`/`AVPlayerViewController` local goes away and the video simply stops.

**5e. Sandboxed / picked files.** On macOS with App Sandbox and on iOS with `UIDocumentPicker`, the URL from the picker is **security-scoped**: you must call `url.startAccessingSecurityScopedResource()` before constructing the `AVURLAsset` and keep the scope open for as long as the asset lives, then `stopAccessingSecurityScopedResource()`. https://developer.apple.com/documentation/foundation/nsurl/startaccessingsecurityscopedresource()
The measured failure: creating the `AVURLAsset` and then stopping access (or letting a scoped bookmark lapse) leaves `isPlayable`/`isReadable` false and the player just shows black with no error — the "stop it at the wrong place and further access is impeded" report at https://developer.apple.com/forums/thread/124687 . **This matters directly for kaya, whose file picker yields a picked file**: the scope has to outlive the widget, not the picker callback, and the calls are reference-counted (balance them).

**5f. Can AVPlayer play from a raw fd or an in-memory buffer? NO.**
- There is no `AVAsset` initializer taking a file descriptor or a `Data`. `AVURLAsset(url:)` is the only file route, and `AVAsset(url:)`/`AVURLAsset` require a URL the framework can open itself.
- **The one supported workaround is `AVAssetResourceLoaderDelegate`**: build the `AVURLAsset` with a URL bearing a **custom scheme** (the delegate is never consulted for `http`/`https`/`file` — documented behaviour), implement `resourceLoader(_:shouldWaitForLoadingOfRequestedResource:)`, and answer `AVAssetResourceLoadingRequest.dataRequest` out of your buffer or your fd. https://developer.apple.com/documentation/avfoundation/avassetresourceloaderdelegate and https://developer.apple.com/documentation/avfoundation/avassetresourceloadingrequest . Practitioner write-up with the custom-scheme rule stated plainly: https://jaredsinclair.com/2016/09/03/implementing-avassetresourceload.html
- For a framework, the pragmatic escape from an fd is: write to a temp file, or (POSIX-only) hand AVFoundation a path via `/dev/fd/N`. Neither is portable to the other four backends, which is an argument for kaya's `video` widget taking a PATH or a URL, not a stream.

---

#### WINDOWS (WinUI 3 / Windows App SDK)

##### WINUI 6 — Is `MediaPlayerElement` really shipped and supported?

**Yes, since Windows App SDK 1.2 (November 2022), and it is supported in every release since.**

- The history is real: WinUI 3 shipped WITHOUT `MediaPlayerElement`. Issue microsoft/microsoft-ui-xaml#5172 ("WinUI MediaPlayerElement", opened 11 June 2021) reports the control absent from WinUI UWP, WinUI Desktop and Project Reunion 0.5.7 and 0.8.0. https://github.com/microsoft/microsoft-ui-xaml/issues/5172 ; the same complaint at https://github.com/microsoft/microsoft-ui-xaml/issues/5150 . During that window the community answer was a hand-rolled prototype (https://github.com/asklar/WinAppSDK-MediaPlayer) or frame-server mode.
- Windows App SDK 1.2 shipped it: "WinUI apps can play audio and video with the **MediaPlayerElement** and **MediaTransportControls** media playback controls." https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/release-notes-archive/stable-channel-1.2 and the announcement https://blogs.windows.com/windowsdeveloper/2022/11/16/whats-new-in-windows-app-sdk-1-2/
- The API reference confirms the version range: `Microsoft.UI.Xaml.Controls.MediaPlayerElement` carries monikers **windows-app-sdk-1.2 … 2.0**. It is `class MediaPlayerElement : Control`. https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.mediaplayerelement
- Current guidance article (updated 2026-06) documents it as THE way to play media in a Windows app: https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/media-playback

**The three shapes an app can take, and when each is right:**

| Shape | What it is | Chrome | Use when |
|---|---|---|---|
| `MediaPlayerElement` | XAML `Control`; its template hosts a `MediaPlayerPresenter` (a `FrameworkElement`) which renders the player's video | `AreTransportControlsEnabled` (**default false**) turns the built-in `MediaTransportControls` on/off | almost always — including "host framework draws its own chrome": leave it false |
| `MediaPlayer` + `GetSurface(Compositor)` + `SetSurfaceSize` | a `MediaPlayerSurface` / `ICompositionSurface` you paint onto your own `SpriteVisual` | none | you are compositing outside XAML (Win2D/Composition islands) |
| `MediaPlayer` frame-server mode | `IsVideoFrameServerEnabled = true`, `VideoFrameAvailable`, `CopyFrameToVideoSurface(IDirect3DSurface)` | none | you need each frame's pixels |

**For kaya specifically:** `MediaPlayerElement` with `AreTransportControlsEnabled="false"` is the analogue of `AVPlayerView(controlsStyle: .none)` — a native player surface with no system chrome. `SetMediaPlayer(MediaPlayer)` lets kaya own the `MediaPlayer` object and hand it to the element, so the widget's control surface is the `MediaPlayer`, not the XAML control. https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.mediaplayerelement.setmediaplayer

**Namespace trap:** the element is `Microsoft.UI.Xaml.Controls.MediaPlayerElement` (WinUI), but `MediaPlayerElement.MediaPlayer` is of type **`Windows.Media.Playback.MediaPlayer`** and the source type is **`Windows.Media.Core.MediaSource`** — WinRT types, not WinUI ones. A WinUI 3 backend therefore needs both projections.

**Unpackaged-app trap, stated by Microsoft in bold:** "Setting `MediaPlayerElement.Source` to a relative URI (ms-appx/ms-resource) only works in an app packaged with a Windows Application Packaging Project. If your app does not use a Windows Application Packaging Project, the recommended workaround is to convert the relative `ms-appx:///` URI to a fully resolved `file:///` URI." https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/media-playback — **this bites kaya directly**, because its Windows lane ships loose exes, not MSIX.

**Known bug worth knowing:** microsoft/microsoft-ui-xaml#7702 — in Windows App SDK 1.2 **preview 1** most transport-control buttons crashed the app (`0xc0000409`, "No such interface supported" out of `mediaextensionsntadapter.cpp`) on Windows 10 19042. Closed. https://github.com/microsoft/microsoft-ui-xaml/issues/7702 . If kaya never enables the transport controls, that whole class is out of reach anyway.

##### WINUI 7 — The `MediaPlayer` API surface

`Windows.Media.Playback.MediaPlayer`, Windows 10 10240+, `ThreadingModel.Both` + `MarshalingType.Agile` (so it can be driven off the UI thread; the XAML element cannot). https://learn.microsoft.com/en-us/uwp/api/windows.media.playback.mediaplayer

**On the player itself:**
- `Play()`, `Pause()`, `StepForwardOneFrame()`, `StepBackwardOneFrame()` (the latter documented as moving back .042s = one frame at 24fps **regardless of the content's real frame rate** — a sharp edge if kaya exposes frame stepping).
- `Volume` (double), `IsMuted`, `IsMutedChanged`, `VolumeChanged`, `AudioBalance`, `AudioCategory`, `AudioDevice`.
- **`IsLoopingEnabled`** — looping is one boolean here, where Apple needs `AVPlayerLooper`/`AVQueuePlayer`. https://learn.microsoft.com/en-us/uwp/api/windows.media.playback.mediaplayer.isloopingenabled
- `Source` (an `IMediaPlaybackSource`: `MediaSource`, `MediaPlaybackItem`, or `MediaPlaybackList`), `AutoPlay`, `RealTimePlayback` (low latency, "more resource intensive and less power-efficient").
- `SystemMediaTransportControls` and `CommandManager` — the Windows analogue of `MPNowPlayingInfoCenter`; `MediaPlayerElement` is documented as **automatically integrated** with SMTC (hardware media keys work with no code).
- Events: `MediaOpened`, `MediaEnded`, `MediaFailed`, `SourceChanged`.
- `Close()` / `Dispose()` — `MediaPlayer` is `IClosable`. Not closing it leaks a decode pipeline.

**On `PlaybackSession` (`MediaPlaybackSession`, Windows 10 14393+)** — this is where the modern properties live; the same-named properties directly on `MediaPlayer` are all marked "may be altered or unavailable after Windows 10, version 1607". https://learn.microsoft.com/en-us/uwp/api/windows.media.playback.mediaplaybacksession
- `Position` (get **and set** — seeking is an assignment, not a call), `NaturalDuration`, `NaturalVideoWidth`/`Height`, `PlaybackRate`, `PlaybackState`, `CanSeek`, `CanPause`, `IsProtected`, `BufferingProgress`, `DownloadProgress`, `PlaybackRotation`, `NormalizedSourceRect` (pan/zoom within the video).
- `IsSupportedPlaybackRateRange(double, double)` — ask before setting a rate.
- `GetSeekableRanges()`, `GetBufferedRanges()`, `GetPlayedRanges()`.
- Events: `PositionChanged`, `PlaybackStateChanged`, `NaturalDurationChanged`, `NaturalVideoSizeChanged`, `SeekCompleted`, `BufferingStarted/Ended`, `PlaybackRateChanged`.
- `MediaPlaybackState`: `None`, `Opening`, `Buffering`, `Playing`, `Paused`.

**End of playback:** `MediaPlayer.MediaEnded` — a plain event, versus Apple's `NSNotification` on the *item*.

**Poster:** `MediaPlayerElement.PosterSource` (an `ImageSource`), shown when there is no valid source, while media is loading, while casting, or when the media is audio-only. https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/media-playback — note this is a *supplied* image, not a frame extracted from the video; Windows has no `AVAssetImageGenerator` equivalent on this API. (Frame-server mode or `Windows.Storage.FileProperties.StorageItemThumbnail` are the two ways to get a real first frame.)

**Sources — and the big divergence from Apple:** `MediaSource.CreateFromUri`, `CreateFromStorageFile`, **`CreateFromStream(IRandomAccessStream, String contentType)`**, `CreateFromStreamReference`, `CreateFromMediaStreamSource`, `CreateFromMseStreamSource`, `CreateFromAdaptiveMediaSource`, `CreateFromMediaBinder`, `CreateFromDownloadOperation`. https://learn.microsoft.com/en-us/uwp/api/windows.media.core.mediasource
**Windows CAN play from an in-memory stream directly; Apple cannot.** If kaya's `video` widget were ever to accept bytes rather than a path, Windows needs no workaround, Apple needs `AVAssetResourceLoaderDelegate`, and that asymmetry is exactly the kind of thing that forces a uniform-semantics ruling. Taking a **path** keeps all five backends level.

###### Frame server mode — what it is, what it costs

`MediaPlayer.IsVideoFrameServerEnabled` (get **and set**, Windows 10 1703 / build 15063+). Apple's `AVPlayerItemVideoOutput` analogue, but with one hard difference stated in Microsoft's own Remarks:

> "When frame server mode is enabled, **the media player does not render video content.** Instead, your app should register for the `VideoFrameAvailable` event and call `CopyFrameToVideoSurface` when the event is raised to get the video frame data."

https://learn.microsoft.com/en-us/uwp/api/windows.media.playback.mediaplayer.isvideoframeserverenabled

So it is **either/or**: you get the frames OR the player draws itself, never both. (`AVPlayerItemVideoOutput` is additive — the layer keeps rendering while you also pull.) A kaya `video` widget that wanted "show it AND give me the pixels" would have to blit every frame itself on Windows.

Companions: `CopyFrameToVideoSurface(IDirect3DSurface)` / `(IDirect3DSurface, Rect)`, `CopyFrameToStereoscopicVideoSurfaces`, `RenderSubtitlesToSurface` (1709+), `VideoFrameAvailable`, `SubtitleFrameChanged`.

**Documented pain, from microsoft/microsoft-ui-xaml#6610 ("MediaPlayer in frame server mode quite limited and has some bugs so cannot be used as a full replacement for MediaPlayerElement", opened Jan 2022, assigned to the WinAppSDK 1.3 milestone, no fix comment):** https://github.com/microsoft/microsoft-ui-xaml/issues/6610
1. `RenderSubtitlesToSurface` does not work (crash with `CanvasRenderTarget`, `InvalidArgumentException` with Microsoft's own documented approach).
2. `NaturalVideoSizeChanged` does not reliably fire when the size properties become available.
3. `CopyFrameToVideoSurface`'s scaling/positioning rule is undocumented — it scales uniformly rather than stretching, which makes pixel-exact rendering guesswork.
4. HDR gaps: `InvalidArgumentException` on 16-bit float surfaces for some videos, `NormalizedSourceRect` stretches in Y, washed-out colour with no colour-management knob, and no API to detect that the content is HDR at all.
5. `VideoFrameAvailable` keeps firing while paused if `CopyFrameToVideoSurface` has not been called recently.

**Recommendation for kaya:** treat frame-server mode as the "current frame extraction" answer only, and only if the feature is actually asked for. `MediaPlayerElement` for display.

##### WINUI 8 — Codec coverage on Windows 11 in 2026

Primary source, Microsoft's own "Supported codecs" table (page date 2026-05-12): https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/supported-codecs — "D" = decoder, "E" = encoder, and these are **the codecs included with Windows**.

Video codecs, in-box:

| Codec | In-box on Windows? | Notes |
|---|---|---|
| H.264 | **D/E**, everywhere (fMP4, MP4, MPEG-2 PS/TS, 3GPP, AVCHD, AVI, MKV) | the safe baseline |
| H.265 / HEVC | D (MP4 D/E, fMP4, MKV) **but starred** | "H.265 and AV1 are available with the install of **the corresponding optional codec pack**", plus "Where H.265 support is indicated, it is not necessarily supported by all devices" |
| AV1 | D (fMP4, MP4, MKV) **but starred** | same optional-codec-pack footnote |
| **VP9** | **D/E in-box** (fMP4, MP4, MKV) | no extension needed — the exact opposite of Apple |
| **VP8** | **D/E in-box** (MP4, MKV) | ditto |
| MPEG-4 Part 2, H.263, VC-1, WMV7/8/9, DV, Motion JPEG | D (some D/E) | legacy |
| MPEG-1 / MPEG-2 | starred | "available with install of the optional Windows DVD Player app" |

**Containers in-box include MKV** — Windows demuxes Matroska where Apple does not. There is no WebM column, but VP8/VP9-in-MKV is listed.

**The store packages:**
- **HEVC Video Extensions** — a paid **$0.99** Store listing; the free listing is "HEVC Video Extensions from Device Manufacturer" (product 9N4WGH0Z6VHQ), which Microsoft makes visible only on machines whose OEM licensed it, so it is **not guaranteed to be installable on a given PC** (a self-built desktop or a VM typically sees only the paid one). Microsoft charges because HEVC is patent-licensed. https://www.windowslatest.com/2025/07/16/can-you-get-hevc-codec-for-free-on-windows-11/ and https://learn.microsoft.com/en-us/answers/questions/1182851/hevc-video-extensions
- **AV1 Video Extension** — free from the Store, and it carries a software decoder, so AV1 plays on machines without AV1 silicon (hardware decode on Intel 11th gen+, NVIDIA RTX 30/40+, AMD RX 6000+). https://apps.microsoft.com/detail/9MVZQVXJBQ9V
- **AC-3 was REMOVED from Windows in 11 24H2** — "Beginning with Windows 11, version 24H2, the AC-3 codec is no longer included with Windows. However, many device manufacturers will pre-install an AC-3 codec." (from the same supported-codecs page). An MKV with AC-3 audio can therefore play video with no sound on a clean 24H2 install.

**Hardware decode.** Media Foundation decoders use **DXVA 2.0** when the GPU offers it and fall back to software otherwise; Microsoft states it explicitly for H.264: "The maximum guaranteed resolution for DXVA acceleration is 1920 × 1088 pixels; at higher resolutions, **decoding is done with DXVA, if it is supported by the underlying hardware, otherwise, decoding is done with software.**" The decoder advertises `MF_SA_D3D_AWARE` and honours `CODECAPI_AVDecVideoAcceleration_H264`. https://learn.microsoft.com/en-us/windows/win32/medfound/h-264-video-decoder
The app never asks for any of this — `MediaPlayer` picks the pipeline. The runtime capability query is `Windows.Media.Core.CodecQuery` ("Query for codecs installed on a device"): https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/codec-query

##### WINUI 9 — Embedding traps: airspace, z-order, clipping

**There is no airspace problem for `MediaPlayerElement`, and this is a structural difference from WPF.**
- WPF's airspace rule, in Microsoft's own words: "each HWND that comprises one of the technologies of an interoperation application has its own region (also called 'airspace'). **Each pixel within the window belongs to exactly one HWND** … all layers or other windows that attempt to render above that pixel … must be part of the same render-level technology"; and specifically "if you try to use transparency/alpha blending between different technologies … pixels in that WPF box are semi-transparent, they would have to be owned jointly by both DirectX and WPF, which is not possible. So this is another violation and cannot be built." https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/technology-regions-overview
- In WinUI 3, `MediaPlayerElement`'s video is drawn by `MediaPlayerPresenter`, declared `class MediaPlayerPresenter : FrameworkElement` — an ordinary XAML element inside the ordinary XAML visual tree, composited by the same Windows.UI.Composition/DirectComposition pass as everything else in the window. https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.mediaplayerpresenter So it takes part in normal XAML z-order (`Canvas.ZIndex`, panel child order), normal clipping (`UIElement.Clip`, `ScrollViewer`, `Grid` cell bounds), `Opacity`, and `RenderTransform`. It is not a child HWND.
- **The one reported compositing anomaly**: microsoft/microsoft-ui-xaml#9648 — an Acrylic brush over a `MediaPlayerElement` renders as a solid tint plus texture rather than blurring the video behind it (WinAppSDK 1.5). Closed with no technical explanation on the thread. https://github.com/microsoft/microsoft-ui-xaml/issues/9648 Practical reading: video pixels are not available to the backdrop-sampling brushes. Anything that samples what is *behind* it (Acrylic, Mica, `BackdropBrush`) should not be layered over a video; ordinary opaque or alpha-blended XAML on top is fine.
- **The real airspace offender in WinUI 3 is `SwapChainPanel` and `WebView2`, not `MediaPlayerElement`.** SwapChainPanel has its own reported geometry bugs — wrong position at non-100% display scaling (https://github.com/microsoft/microsoft-ui-xaml/issues/5888) and distortion when scaled small (https://github.com/microsoft/microsoft-ui-xaml/issues/6919). A "SwapChainPanel + Media Foundation" video widget would inherit those; `MediaPlayerElement` does not.
- **Inside a `ScrollViewer`**: no documented special case; it is a `Control` and clips like any other. Worth a kaya lane assertion rather than a claim (see the open questions at the end).
- **`Stretch`** (`None` / `Uniform` / `UniformToFill` / `Fill`) is the layout knob, the direct analogue of `AVLayerVideoGravity`. https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/media-playback

##### WINUI 9b — Other Windows traps a framework must handle

- **Keeping the screen awake is the app's job.** `DisplayRequest.RequestActive()` while playing, `RequestRelease()` on pause/stop/error; Microsoft's sample keys this off `PlaybackSession.PlaybackStateChanged` and checks `NaturalVideoHeight != 0` so audio-only files don't hold the display on. Windows auto-deactivates the app's requests when it goes off screen. Same doc as above. macOS/iOS have separate mechanisms (AVKit does it for you there; a bare `AVPlayerLayer` does not).
- **Internet capability**: a packaged app needs the `internetClient` capability declared to open a media URL.
- **`MediaPlayer` must be `Close()`d.** It is `IClosable`/`IDisposable`; a widget destroy path that just drops the reference leaks the pipeline and can keep audio focus.
- **Every `MediaPlayerElement` touch is UI-thread only** even though `MediaPlayer` is agile — `dispatcherQueue.TryEnqueue(...)`, exactly as Microsoft's own `DisplayRequest` sample does.

---

#### HEADLESS / CI: what an automated lane actually gets

##### macOS
- **A logged-in GUI session gets full hardware decode.** AVFoundation/VideoToolbox use the same decoders any app does; nothing about being driven by a test harness changes that. kaya's mac lane already requires a logged-in GUI session (`tools/validate-mac.py`), so it is in the good case.
- **Over plain SSH with no GUI session, expect failures that are not about video at all.** Apple's forums document `.app` bundles failing at runtime under a non-GUI ssh session with NSXPCSharedListener endpoint errors, and the guidance is to stick to daemon-safe frameworks outside a GUI login context. https://developer.apple.com/forums/thread/749314 AVKit/AppKit are not daemon-safe.
- **AV1 will not decode on a pre-M3 mac runner at all** (no working software fallback; `VTDecompressionSessionCreate` fails with `kVTCouldNotFindVideoDecoderErr`) — https://developer.apple.com/forums/thread/722933 . A CI fixture must be H.264 if it is to be codec-portable across mac hardware generations.
- The honest runtime probe from inside the harness is `VTIsHardwareDecodeSupported(_:)` plus `AVURLAsset.audiovisualTypes()`; both are cheap and give a lane a real answer instead of a guess. https://developer.apple.com/documentation/videotoolbox/vtishardwaredecodesupported(_:)

##### iOS Simulator
- H.264 in MP4 plays in the Simulator; **HEVC in the Simulator has a documented history of NOT rendering** while the same stream plays on device (reports across iOS 11 → iOS 14 simulators: https://developer.apple.com/forums/thread/92184 , https://developer.apple.com/forums/thread/712230 ), and there are reports of video simply not working in specific simulator runtimes (https://developer.apple.com/forums/thread/727288).
- Modern Apple-silicon simulators share the host's decoders, so today's behaviour is probably better than those reports — but **this is the single item in this document I would insist on measuring rather than believing**, since kaya's iOS lane is a simulator pool.
- Practical rule: make the CI fixture **H.264 Baseline/Main in an MP4**, small, short, and the same file on all five platforms.

##### Windows (a VM with no discrete GPU — kaya's lane)
- **Software decode is documented and automatic.** Microsoft, for the H.264 decoder: "decoding is done with DXVA, if it is supported by the underlying hardware, **otherwise, decoding is done with software**." https://learn.microsoft.com/en-us/windows/win32/medfound/h-264-video-decoder So a UTM/Hyper-V Windows 11 guest with no GPU passthrough still decodes H.264. VP8/VP9 are likewise in-box.
- **HEVC and AV1 will NOT be present on a clean VM** unless the Store extension is installed — HEVC's free "from Device Manufacturer" listing is gated to OEM machines, so a VM sees only the paid $0.99 one. A CI fixture must not be HEVC or AV1.
- **`MediaPlayerElement` needs the XAML compositor, which needs D3D**; Windows falls back to WARP (software rasterizer) with no GPU, so a WinUI 3 app renders in a VM — kaya's Windows lane already proves this by rendering everything else.
- **Media Foundation is not present on all SKUs**: the H.264 decoder page lists "Minimum supported server: **None supported**", and the supported-codecs page notes AMR-NB is unavailable on Server SKUs. A Windows Server CI image (or Server Core) is the wrong runner for a video lane; Windows 11 desktop is the right one.
- **Audio has no device in a headless VM.** `MediaPlayer.Volume`/`IsMuted` still behave, and `PlaybackSession.PlaybackState` still advances, but any assertion that depends on real audio output will be flaky. Assert on position/state, never on sound.

##### What a kaya scene can actually observe (synthesis, not sourced)
kaya's harness already has `expect_ink` (pixel sampling with a ±1-per-channel tolerance) and byte-compared verdicts. That makes a **deterministic fixture video** the natural observable: e.g. 3 seconds of solid colour changing at exact second boundaries, H.264/MP4, a few KB. Then a scene can assert, identically on all five backends:
- `expect_ink` after `seek(to: 1.5s)` + a settle → proves decode, colour pipeline, and geometry in one shot, and would catch a channel swap the way `check-canvas-blit` does for the canvas.
- a `duration` readback (Apple `AVPlayerItem.duration` / async `asset.load(.duration)`; Windows `PlaybackSession.NaturalDuration`) → proves the demuxer opened it.
- a `position` readback after a seek → proves seeking; **use tolerance `.zero` on Apple or the frame you land on is not the frame you asked for**.
- a playback-state readback (`AVPlayer.timeControlStatus` / `MediaPlaybackSession.PlaybackState`) rather than "is rate 0", because both platforms have a distinct buffering/waiting state.
Note the two APIs' end-of-media differ in shape (Apple: a notification on the *item*; Windows: `MediaPlayer.MediaEnded`) but not in semantics, so one `on_ended` handler is spellable uniformly.

---

#### CROSS-PLATFORM SUMMARY FOR A `video` WIDGET (Apple + Windows halves)

| Concern | Apple (mac + iOS) | Windows (WinUI 3) |
|---|---|---|
| Host view, no chrome | `AVPlayerLayer` in a `layerClass` view (uniform, zero chrome), or `AVPlayerView(.none)` / `AVPlayerViewController(showsPlaybackControls:false)` | `MediaPlayerElement` with `AreTransportControlsEnabled=false` |
| SwiftUI-native option | `VideoPlayer` — **rejected**, cannot hide controls | n/a |
| Control object | `AVPlayer` | `MediaPlayer` (+ `PlaybackSession`) |
| Seek | `seek(to:toleranceBefore:.zero,toleranceAfter:.zero)` | `PlaybackSession.Position = ...` |
| Rate | `rate` / `defaultRate` | `PlaybackSession.PlaybackRate` (+ `IsSupportedPlaybackRateRange`) |
| Duration | `AVPlayerItem.duration` / `await asset.load(.duration)` | `PlaybackSession.NaturalDuration` |
| Position updates | `addPeriodicTimeObserver` (token must be removed on the same player) | `PlaybackSession.PositionChanged` |
| Ended | `AVPlayerItem.didPlayToEndTimeNotification` | `MediaPlayer.MediaEnded` |
| Loop | `AVPlayerLooper` + `AVQueuePlayer` (or seek-to-zero) | `MediaPlayer.IsLoopingEnabled` (one bool) |
| Volume / mute | `AVPlayer.volume`, `.isMuted` | `MediaPlayer.Volume`, `.IsMuted` |
| Poster / first frame | `AVAssetImageGenerator.image(at:)` (set both tolerances to `.zero`, `appliesPreferredTrackTransform = true`) | `PosterSource` is a *supplied* image; a real first frame needs frame-server mode or `StorageItemThumbnail` |
| Live frames | `AVPlayerItemVideoOutput` — **additive**, player keeps drawing | frame-server mode — **exclusive**, player stops drawing |
| In-memory source | impossible directly; `AVAssetResourceLoaderDelegate` + custom URL scheme | `MediaSource.CreateFromStream` — supported outright |
| Safe CI codec | H.264 / MP4 | H.264 / MP4 |
| VP9 | unavailable to apps (Safari only) | **in-box** |
| MKV / WebM | unsupported | **MKV in-box** |
| HEVC | in-box | needs a Store extension (paid on non-OEM machines) |
| AV1 | needs M3 / A17 Pro silicon, no software fallback | free Store extension, includes software decode |
| Screen-stays-awake | AVKit does it; a bare `AVPlayerLayer` does not | app must drive `DisplayRequest` |
| Now Playing / media keys | AVKit views do it (`updatesNowPlayingInfoCenter`); `AVPlayerLayer` does not | `MediaPlayerElement` is auto-integrated with SMTC |
| Silent-switch trap | **iOS only**: must set `AVAudioSession.playback` or video is mute | none |
| z-order / clipping | normal (representable views) but rounded clip needs `.mask` not `.clipShape` | normal XAML; only backdrop brushes (Acrylic/Mica) fail over video |

##### Consequences worth a ruling before anything is built
1. **Codec floor.** The intersection of "plays with no extra install on every target" is essentially **H.264 in MP4/MOV, AAC audio**. Everything else diverges: VP9/VP8/MKV are Windows-and-Linux-only, HEVC is Apple-free/Windows-paid, AV1 is Apple-silicon-gated/Windows-free-extension. A `video` widget should state its floor and expose a per-platform capability query rather than pretend uniformity.
2. **Chrome.** Both platforms let the host draw its own transport, but only by refusing the system player view (`AVPlayerLayer` / `AreTransportControlsEnabled=false`). Taking that route means kaya also inherits the responsibilities AVKit/MediaPlayerElement were quietly discharging: Now Playing on Apple, `DisplayRequest` on Windows, PiP on neither.
3. **The source is a path, not a stream.** Windows would allow bytes; Apple would need a resource-loader shim per platform. Uniform semantics argues for a path/URL.
4. **Frame extraction is not one feature.** "Poster frame" and "every frame during playback" have different APIs, different costs, and on Windows the second one *turns off* the first.

---

#### CONFIDENCE AND OPEN QUESTIONS

Things stated above that are **documented by a primary source** (Apple Developer docs, Microsoft Learn, or an official repo issue): everything with a `developer.apple.com/documentation`, `learn.microsoft.com`, or `github.com/microsoft` URL.

Things resting on **forum reports / practitioner sources**, and therefore worth measuring on kaya's own lanes before they become design constraints:
1. **iOS Simulator HEVC (and AV1) decode.** The negative reports are from Intel-era simulators (2017–2022). Apple-silicon simulators may behave differently. → Probe with `VTIsHardwareDecodeSupported` inside the iOS lane and record the answer.
2. **Whether `MediaPlayerElement` clips correctly inside a `ScrollViewer` in WinUI 3.** Structurally it must (it is a `FrameworkElement`), and no issue reports otherwise, but I found no explicit statement or test. → One lane assertion settles it.
3. **The rounded-corner clipping failure of a representable hosting `AVPlayerLayer`.** Reported on the Apple forums and in a widely-cited write-up; the `.mask` workaround is community knowledge, not Apple's. The safer spelling regardless is `cornerRadius` + `masksToBounds` on the layer itself.
4. **`AVPlayerLayer.displayedReadOnlyPixelBuffer()` / `AVPlayerItemVideoOutput.pixelBufferAndDisplayTime(forItemTime:)`** are the new (2025/26 SDK) replacements for the deprecated `copyPixelBuffer`. I did not find their exact availability floor; the deprecated forms remain available and are the portable choice for an older deployment target.
5. **AC-3 removal in Windows 11 24H2** is stated on Microsoft's supported-codecs page for AUDIO; I did not verify the practical effect on an MKV/AC-3 file end to end.
6. **Whether a Windows VM without a GPU actually plays a 1080p H.264 file at real time** — the software path is documented, the throughput is not. A CI fixture should be small (e.g. 320×240) so this never matters.

Things I could NOT establish (search budget exhausted before I reached them):
- Whether any Apple API exists to hide `VideoPlayer`'s controls in the macOS 26 / iOS 26 SDKs specifically (the DTS answer is from Sept 2024 and there is no such modifier in the current `VideoPlayer` reference page, which lists only two initializers — so the answer is almost certainly still no).
- Picture-in-Picture on Windows (`MediaPlayerElement` has `IsFullWindow` but PiP is a separate `CompactOverlay` window-presenter story).

### §1.2 Android and Linux: the per-platform detail
Research date: 2026-09-02. Every claim carries a URL. Primary sources preferred.

---

#### PART A — ANDROID

##### A1. State of androidx.media3 in 2026

**ExoPlayer is still the recommended player, and it lives inside media3.** The
standalone `com.google.android.exoplayer:exoplayer` (ExoPlayer 2.x) line is
retired; `androidx.media3:media3-exoplayer` is the shipping artifact.
- Media3 release page: https://developer.android.com/jetpack/androidx/releases/media3
- ExoPlayer 2.x repo (archived/redirecting to androidx/media): https://github.com/google/ExoPlayer

**Current stable: 1.11.0, released 2026-08-05.** All media3 artifacts share one
version number.
(source: https://developer.android.com/jetpack/androidx/releases/media3)

Artifacts relevant to a `video` widget:
```
androidx.media3:media3-exoplayer:1.11.0            # the player
androidx.media3:media3-ui-compose:1.11.0           # PlayerSurface, state holders
androidx.media3:media3-ui-compose-material3:1.11.0 # Player, MiniController, ProgressSlider
androidx.media3:media3-ui:1.11.0                   # legacy View-based PlayerView
androidx.media3:media3-common:1.11.0
```

###### The Compose story (this is the important part for kaya)

`media3-ui-compose` first shipped in **1.6.0** and has grown every release since.
As of 1.11.0 it ships, per the official getting-started guide
(https://developer.android.com/media/media3/ui/compose):

- `PlayerSurface` — the drawing surface composable. Connects to a `Player`.
  **Carries no controls.** This is exactly the primitive kaya wants.
- `ContentFrame` — container that sizes/letterboxes the content.
- `rememberPresentationState(player)` -> `PresentationState` with
  `coverSurface` (bool: show a placeholder because no frame is ready yet),
  `videoSizeDp`, `keepContentOnReset`.
- State holders: `rememberPlayPauseButtonState`, `CurrentMediaItemState`,
  `PlaylistState`, `ErrorState`, `PlaybackSpeedState`, etc.

`media3-ui-compose-material3` (the opinionated layer) ships `Player`,
`MiniController`, `ProgressSlider`, `PlayPauseButton`, `SeekBackButton`,
`PositionAndDurationText`, `ErrorText`, `PlayerDefaults`,
`PlaybackSpeedControl`/`PlaybackSpeedToggleButton`.
The full `Player` composable and `ProgressSlider` arrived in **1.10.0**
(2026-03; https://android-developers.googleblog.com/2026/03/media3-110-is-out.html);
1.11.0 added `MiniController`, `ErrorState`/`ErrorText`, `PlayerPool` /
`rememberPooledPlayer` (pre-loading for sliding-window/feed UIs), and
`FocusRequester` support.
(source: https://developer.android.com/jetpack/androidx/releases/media3)

**Verdict for kaya:** do NOT wrap the View-based `PlayerView` in an
`AndroidView`. `PlayerSurface` from `media3-ui-compose` is the native-Compose
route, it is control-free (kaya draws its own controls or exposes none), and it
is where Google's investment is. `PlayerView` is not formally deprecated but new
features are Compose-only.

`PlayerSurface`'s actual signature (release branch source,
https://github.com/androidx/media/blob/release/libraries/ui_compose/src/main/java/androidx/media3/ui/compose/PlayerSurface.kt):

```kotlin
@Composable
fun PlayerSurface(
    player: Player?,
    modifier: Modifier = Modifier,
    surfaceType: @SurfaceType Int = SURFACE_TYPE_SURFACE_VIEW,   // default!
)
// SURFACE_TYPE_SURFACE_VIEW = 1 ; SURFACE_TYPE_TEXTURE_VIEW = 2
```
Internally it is still an `AndroidView` wrapping a real `SurfaceView`/`TextureView`
(with a `SurfaceSyncGroup` workaround on API 34), plus a `Player.Listener` for
size changes and `DisposableEffect`/`LaunchedEffect` lifecycle. So kaya's Compose
backend gets a composable, but the thing on screen is the platform view.

---

##### A2. SurfaceView vs TextureView vs SurfaceTexture

The authoritative page is **Surface types**,
https://developer.android.com/media/media3/ui/surface .

**Official recommendation: prefer SurfaceView; use TextureView only if SurfaceView
does not meet your needs.** Reasons given for SurfaceView:
- significantly **lower power consumption** on many devices
- **more accurate frame timing** -> smoother playback
- **higher-quality HDR** output on capable devices
- **secure output** for DRM content (TextureView cannot do secure)
- full-resolution rendering on Android TV where the UI layer is upscaled

The only case the page gives for TextureView is smooth animation/scrolling of the
video surface **prior to API 24** — "SurfaceView rendering wasn't properly
synchronized with view animations until Android 7.0 (API level 24). On earlier
releases ... the view's contents appearing to lag slightly behind where it should
be displayed, and the view turning black when animated." So: `SDK_INT < 24 ->
TextureView, else SurfaceView`. kaya's minSdk is almost certainly >= 24, so this
carve-out is dead and SurfaceView is simply correct.

###### The mechanism (why the z-order trap exists)

AOSP graphics architecture, https://source.android.com/docs/core/graphics/arch-sv-glsv :
"A SurfaceView is a component that you can use to embed an additional composite
layer within your view hierarchy." When it becomes visible the framework asks
SurfaceFlinger for a **new surface**, which "directly composes buffers to the
screen"; **"the SurfaceView's contents are transparent"** inside the app's own
view layer — i.e. the view punches a hole and SurfaceFlinger fills it from a
separate layer. "By default, the framework places the newly created surface
behind the app UI surface", and "you can override the default Z-ordering to put
the new surface on top."

The framework's own words (AOSP `core/java/android/view/SurfaceView.java`,
https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/main/core/java/android/view/SurfaceView.java ):

> "Provides a dedicated drawing surface embedded inside of a view hierarchy. ...
> **The surface is Z ordered so that it is behind the window holding its
> SurfaceView; the SurfaceView punches a hole in its window to allow its surface
> to be displayed.** The view hierarchy will take care of correctly compositing
> with the Surface any siblings of the SurfaceView that would normally appear on
> top of it. **The transparent region that makes the surface visible is based on
> the layout positions in the view hierarchy.**"

Read that carefully, because it is more nuanced than the folklore:

- **Siblings drawn ON TOP of the video DO work.** The hole is computed from
  layout, so an overlay above the SurfaceView simply is not part of the
  transparent region and paints normally. kaya CAN put controls, a caption or a
  badge over a video. Good.
- **The video itself is not drawn by the app's renderer**, so anything that
  changes *how the SurfaceView's own pixels are drawn* — a rounded-corner clip,
  `Modifier.graphicsLayer` scale/rotate/alpha, a fade animation, a blur — applies
  to the hole rather than to the composited buffer, and either does nothing or
  produces artifacts. This is why "rounded corners on video" is a known-hard
  Android problem (workaround survey:
  https://medium.com/@fabrantes/rounded-video-corners-on-android-3467841cc1b ),
  and a Compose report of exactly it: `AndroidExternalSurface` **flickers when
  clipping is applied via `Modifier.graphicsLayer`**, which is what every
  `clip`/`RoundedCornerShape` goes through; clipping inside the draw scope
  (`canvas.clip*`) does not flicker —
  https://slack-chats.kotlinlang.org/t/18826802/hey-everyone-i-have-a-question-regarding-how-graphicslayer-w
- The two z-order knobs are whole-layer switches, verbatim:
  `setZOrderMediaOverlay(boolean)` — "Control whether the surface view's surface
  is placed on top of another regular surface view in the window (but still
  behind the window itself). This is typically used to place overlays on top of
  an underlying media surface view."
  `setZOrderOnTop(boolean)` — "Control whether the surface view's surface is
  placed on top of its window. Normally it is placed behind the window ...
  **By setting this, you cause it to be placed above the window. This means that
  none of the contents of the window this SurfaceView is in will be visible on
  top of its surface.**" So `setZOrderOnTop(true)` is a sledgehammer: it hides
  every dialog, popup and overlay in that window behind the video. Neither knob
  can express "above widget A, below widget B".
- **Two SurfaceViews in one window cannot be freely ordered** either — only the
  media-overlay bit distinguishes them.

###### Has modern Android fixed it?

Partly, and only the *synchronization* half, not the compositing model:
- **API 24+**: SurfaceView position updates are synchronized with view animations,
  which removed the lag/black-frame class (per the Surface types page above).
- **Android 14 (API 34)**: `SurfaceView.setSurfaceLifecycle(int)` — "Controls the
  lifecycle of the Surface owned by this SurfaceView."
  `SURFACE_LIFECYCLE_DEFAULT` = `SURFACE_LIFECYCLE_FOLLOWS_VISIBILITY` ("The
  Surface is created when the SurfaceView becomes visible, and is destroyed when
  the SurfaceView is no longer visible"); `SURFACE_LIFECYCLE_FOLLOWS_ATTACHMENT`
  ("The Surface is created when the SurfaceView first becomes attached, but is
  not destroyed until this SurfaceView has been detached from the current
  window") — AOSP source as above.
  This matters directly for **scrolling lists**: "The lifecycle of a SurfaceView's
  surface is tied to view visibility, whereas a TextureView's surface lifecycle is
  tied to window attachment and detachment. Therefore, in scrolling UIs that use
  SurfaceView, starting playback can take longer because the output surface becomes
  available slightly later." Before 14 the workaround was translating recycled
  views off-screen. (https://developer.android.com/media/media3/ui/surface)
- **API 34 + Compose**: media3 documents a real interop defect — "One of the common
  problems for SDK_INT == 34 is a stretched/cropped/leaked Surface that does not
  match the parent container (AspectRatioFrameLayout) correctly", with
  `PlayerView.setEnableComposeSurfaceSyncWorkaround()` as the escape hatch (which
  "causes issues with XML-based shared transitions"). `PlayerSurface` carries the
  `SurfaceSyncGroup` fix internally, which is another argument for using it rather
  than hand-wrapping.
- **It does NOT fix**: arbitrary z-interleaving, rounded-corner clipping, or
  `graphicsLayer` transforms. Those are inherent to a separate SurfaceFlinger layer.

###### Compose 1.7+ `AndroidExternalSurface` / `AndroidEmbeddedExternalSurface`

Both exist in `androidx.compose.foundation` and are the Compose-native way to get
a raw `Surface`:
- `AndroidExternalSurface` — "Provides a dedicated drawing Surface as a separate
  layer positioned by default behind the window". Params include `isOpaque`,
  `isSecure` ("Prevent it from appearing in screenshots or from being viewed on
  non-secure displays"), `surfaceSize`, `zOrder`, `onInit`.
  `AndroidExternalSurfaceZOrder` = **Behind** / **MediaOverlay** / **OnTop** —
  the SurfaceView z-order knobs, renamed.
  "Graphics composition is handled by the system compositor which can bypass the
  GPU and provide better performance and power usage."
- `AndroidEmbeddedExternalSurface` — "positions its surface as a regular element
  inside the composable hierarchy ... graphics composition is handled like any
  other UI widget, using the GPU. This can lead to increased power and memory
  bandwidth usage." Useful "if the surface needs to be 'sandwiched' between two
  other widgets, or if it must participate in visual effects driven by a
  `Modifier.graphicsLayer{}`." (It is TextureView-backed, which is why it can.)
  https://composables.com/docs/androidx.compose.foundation/foundation/composable-functions/AndroidExternalSurface
  https://composables.com/docs/androidx.compose.foundation/foundation/composable-functions/AndroidEmbeddedExternalSurface

**But media3 explicitly says do not use them with ExoPlayer**: "These proxy classes
provide an API surface that limits access of the underlying views. Those views are
needed by the Player to handle a full lifecycle of the surface (creation and size
updates)." (https://developer.android.com/media/media3/ui/surface). So the two
Compose primitives are for *your own* renderer (Camera2, GL, a Rust rasterizer),
not for hosting ExoPlayer. **`PlayerSurface` is the supported path.**

**Design consequence for kaya:** the `video` kind maps to a
SurfaceView-shaped hole. It cannot honour arbitrary kaya z-order, corner radius,
opacity or transform on Android. That is a real divergence to state uniformly
(the same trap exists on every platform that hands you a native player layer;
the Apple agent should be asked whether AVPlayerLayer has the same property —
it does not, AVPlayerLayer is a CALayer, so Android is the odd one out).
The escape hatch, if kaya wants clipping/transform parity, is
`SURFACE_TYPE_TEXTURE_VIEW`, paying power/HDR/DRM/frame-timing for it.

---

##### A3. The Player API surface (what kaya's `video` kind can expose)

All of these are on `androidx.media3.common.Player` (the interface) unless noted;
`ExoPlayer` implements it. Reference:
https://developer.android.com/reference/androidx/media3/common/Player

| kaya prop/verb | media3 call |
|---|---|
| play / pause | `play()` / `pause()`, or `setPlayWhenReady(Boolean)` + `getPlayWhenReady()`; `isPlaying()` is the derived "actually advancing" signal |
| source | `setMediaItem(MediaItem)` then `prepare()`; `release()` on teardown |
| seek | `seekTo(positionMs)`, `seekTo(mediaItemIndex, positionMs)` |
| position / duration | `getCurrentPosition()`, `getDuration()`, `getBufferedPosition()` (all ms; duration is `C.TIME_UNSET` until known) |
| speed | `setPlaybackSpeed(float)` / `setPlaybackParameters(PlaybackParameters)` (speed + pitch) |
| volume | `setVolume(float 0..1)` / `getVolume()`; `mute()` / `unmute()` added in **1.9.0** (https://android-developers.googleblog.com/2025/12/media3-190-whats-new.html) |
| loop | `setRepeatMode(REPEAT_MODE_OFF=0 / REPEAT_MODE_ONE=1 / REPEAT_MODE_ALL=2)` |
| events | `Player.Listener`: `onPlaybackStateChanged(STATE_IDLE=1/BUFFERING=2/READY=3/ENDED=4)`, `onIsPlayingChanged`, `onVideoSizeChanged(VideoSize)`, `onPlayerError(PlaybackException)`, `onMediaMetadataChanged` |
| poster/artwork | `MediaItem.Builder().setMediaMetadata(MediaMetadata.Builder().setArtworkUri(...))`; in Compose, `rememberPresentationState(player).coverSurface` tells you when to draw a placeholder because no frame is on the surface yet |

###### Seek precision — this is a real semantic divergence risk

`ExoPlayer.setSeekParameters(SeekParameters)` (ExoPlayer, not Player).
Source javadoc, https://github.com/androidx/media/blob/release/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/SeekParameters.java :
"Parameters that apply to seeking. The predefined EXACT, CLOSEST_SYNC,
PREVIOUS_SYNC and NEXT_SYNC parameters are suitable for most use cases."
- `EXACT` — "Parameters for exact seeking." (frame-accurate; slower — it decodes
  from the preceding sync frame forward)
- `CLOSEST_SYNC` / `PREVIOUS_SYNC` / `NEXT_SYNC` — keyframe-only, fast
- `DEFAULT` — the default (which is EXACT)
- The general constructor takes `toleranceBeforeUs` / `toleranceAfterUs`:
  "the maximum time that the actual position seeked to may precede / exceed the
  requested seek position, in microseconds."

Caveat from the tracker: seek parameters are **not honoured for HLS** —
https://github.com/androidx/media/issues/2209 and
https://github.com/google/ExoPlayer/issues/2882 . If kaya promises "seek is exact"
uniformly, HLS on Android is the counterexample. Recommend kaya's `seek` be
documented as "best effort, exact where the container allows" across all five
backends rather than promising frame accuracy.

---

##### A4. Codec coverage on Android, and the emulator question

###### What the platform guarantees

Platform table: https://developer.android.com/media/platform/supported-formats
- **H.264 AVC**: Baseline required since Android 3.0; Main profile required since 6.0.
- **VP8**: required since 2.3.3. **VP9**: required since 4.4.
- **H.265 HEVC**: required (Main Profile L3 handheld / L4.1 TV) since Android 5.0.
- **AV1**: decoder from Android 10; **mandatory (decode) from Android 14**.
- **APV**: mandatory from Android 16.
- Containers: MP4/M4A, fMP4, WebM, Matroska, MPEG-TS/PS, Ogg, WAV, FLV, plus
  HLS / DASH / SmoothStreaming / RTSP through ExoPlayer
  (https://developer.android.com/media/media3/exoplayer/supported-formats).

CDD confirmation (Android 16, §5.3 Video Decoding, handheld MUST list includes
H.264 AVC [H-0-1], H.265 HEVC [H-0-2], VP8, VP9, AV1 [H-0-6]):
https://source.android.com/docs/compatibility/16/android-16-cdd
Android 15 CDD: https://source.android.com/docs/compatibility/15/android-15-cdd

**Practical read: on any Android 7+ device, H.264-in-MP4 and VP9-in-WebM decode
without any extra dependency.** That is what kaya's test asset should be.

###### What ExoPlayer adds in software

`androidx.media3` ships optional decoder modules that **must be built manually
with the NDK** and are not on Maven as prebuilt .so:
`decoder_av1`, `decoder_vp9`, `decoder_flac`, `decoder_opus`, `decoder_ffmpeg`,
`decoder_midi`, `decoder_iamf`, `decoder_mpegh`
(https://developer.android.com/media/media3/exoplayer/supported-formats).
The AV1 module now wraps **dav1d**, not libgav1 — `Libdav1dVideoRenderer`, built
via meson/ninja/nasm against VideoLAN's dav1d, NDK r27 tested, Windows build
unsupported (https://github.com/androidx/media/tree/release/libraries/decoder_av1).

**Recommendation for kaya: do NOT ship any decoder extension.** Manual NDK builds
of dav1d/ffmpeg would be a new toolchain in the android lane for zero benefit
given the platform mandates above.

###### The emulator (this project's CI lane)

Emulator system images ("goldfish") ship codec2 components named
`c2.goldfish.h264.decoder`, `c2.goldfish.vp8.decoder`, `c2.goldfish.vp9.decoder`,
`c2.goldfish.hevc.decoder` that **offload decoding to the host** through the
goldfish pipe, alongside the ordinary AOSP software decoders (`c2.android.*`).
Sources: https://android.googlesource.com/device/generic/goldfish/ (goldfish
codec2 components) and the emulator release notes
https://developer.android.com/studio/releases/emulator — emulator 29.0.6 (2019)
"Upgraded ffmpeg version to 3.4.5 for video encoding and decoding"; 30.0.26
"Switched back to software decode for libvpx ... hardware decode of libvpx can
be re-enabled via the environment variable `ANDROID_EMU_MEDIA_DECODER_CUDA_VPX=1`".

**So yes, video decodes on the emulator.** But two measured traps:

1. **`c2.goldfish.hevc.decoder` is broken on AVDs.**
   https://github.com/androidx/media/issues/2461 — on API 33 (arm64 and x86_64)
   and API 35/36 (x86_64), after looping a video 2-3 times playback dies:
   "Playback failed" on 13, video freezes while audio continues on 15/16.
   **Virtual devices only, not physical hardware.** kaya's android lane loops
   scenes; an HEVC asset would be a flake generator. **Use H.264 for the test
   asset**, not HEVC.
2. `c2.android.avc.decoder` init failures on emulators have been reported around
   pause/resume (https://github.com/google/ExoPlayer/issues/10576,
   https://github.com/google/ExoPlayer/issues/9644). The standard mitigation is
   `DefaultRenderersFactory.setEnableDecoderFallback(true)`, which lets ExoPlayer
   fall back to a second decoder when the first fails to initialise.

Also note the android lane runs on an **arm64 emulator on Apple silicon**, where
the goldfish decoders are the host-offload path — likely fine, but the HEVC bug
above was reproduced on arm64 API 33 specifically.

---

##### A5. Frame extraction / thumbnails

Three routes, in order of preference:

1. **media3 `FrameExtractor`** — the modern, supported one.
   `androidx.media3:media3-inspector` (module split to `media3-inspector-frame`
   in 1.10), class `androidx.media3.inspector.frame.FrameExtractor`. It replaced
   `androidx.media3.transformer.ExperimentalFrameExtractor`, which was **removed
   in 1.10.0**. API: `FrameExtractor.Builder(context, mediaItem).build()`
   (AutoCloseable), then `getFrame(positionMs): ListenableFuture<Frame>` or
   `getThumbnail(): ListenableFuture<Frame>`; `Frame` carries a `Bitmap` and
   `presentationTimeUs`. Instances must be used from a single application thread.
   Supports HDR, video effects and custom decoder selection.
   https://developer.android.com/media/media3/inspector/extract-frames
   https://developer.android.com/media/media3/inspector
   https://android-developers.googleblog.com/2025/12/media3-190-whats-new.html
2. **`android.media.MediaMetadataRetriever`** — the platform's own.
   `getFrameAtTime(timeUs, option)` with `OPTION_PREVIOUS_SYNC` / `OPTION_NEXT_SYNC`
   / `OPTION_CLOSEST_SYNC` (fast, keyframe) vs `OPTION_CLOSEST` (accurate, slow);
   `getScaledFrameAtTime(timeUs, option, w, h)`; `getFrameAtIndex` /
   `getFramesAtIndex` (API 28+).
   https://developer.android.com/reference/android/media/MediaMetadataRetriever
   media3 also offers `androidx.media3.inspector.MetadataRetriever` and
   `MediaExtractorCompat` as replacements (1.9.0).
3. **`ImageReader` + `MediaCodec`** — decode into an `ImageReader` surface and
   read `Image` planes. Full control, most work.

**Can ExoPlayer hand you the pixels of the *currently playing* frame? No, not
directly.** `Player.setVideoFrameMetadataListener` gives you frame *metadata*
(presentation time, release time, format) at render time, not pixels
(https://github.com/androidx/media/issues/... and the SimpleExoPlayer javadoc,
https://javadoc.io/static/com.google.android.exoplayer/exoplayer-core/2.9.3/com/google/android/exoplayer2/SimpleExoPlayer.html).
The long-standing tracker threads on this
(https://github.com/google/ExoPlayer/issues/418,
https://github.com/google/ExoPlayer/issues/2451,
https://github.com/google/ExoPlayer/issues/8975) conclude the same thing: with a
**SurfaceView** the buffers go straight to SurfaceFlinger and the app never sees
them; with a **TextureView** you can call `TextureView.getBitmap()`; otherwise
you extend `MediaCodecVideoRenderer` and intercept `processOutputBuffer`.

**Consequence for kaya's harness.** kaya's Compose harness asserts pixels
(`expect_ink`) by sampling the rendered surface. A SurfaceView-hosted video is a
*hole in that surface* — the harness's own raster will read the hole, not the
video. **Any pixel assertion over a `video` widget on Android needs either
TextureView output or a screenshot taken at the SurfaceFlinger level
(`adb shell screencap`, or UiAutomation.takeScreenshot which does include
SurfaceView content).** This is exactly the class of thing that makes a scene
green while showing nothing. Flag it early.

---

##### A6. Android traps

- **Audio focus.** ExoPlayer will manage it for you:
  `ExoPlayer.Builder(...).setAudioAttributes(attrs, /* handleAudioFocus= */ true)`
  makes the player request and abandon focus as playback starts/stops, and
  duck/pause on focus loss. It **throws `IllegalArgumentException` unless the
  usage is `USAGE_MEDIA` or `USAGE_GAME`** (the usages that request permanent
  focus). https://developer.android.com/media/optimize/audio-focus and
  https://medium.com/google-exoplayer/easy-audio-focus-with-exoplayer-a2dcbbe4640e
  For kaya: set this once in the backend, do not expose it as a widget prop.
  Note https://github.com/androidx/media/issues/724 — ExoPlayer requests focus
  even for a video with no audio track, which for a silent decorative video in a
  GUI toolkit is wrong behaviour (it will pause the user's music). If kaya's
  `video` kind is meant for UI decoration as well as media, consider defaulting
  `handleAudioFocus=false` + `volume=0` for a muted/looping video and only
  requesting focus when the app asks for sound.
- **Foreground service.** Only needed for playback that continues when the app is
  backgrounded. Android 14+ requires `android:foregroundServiceType="mediaPlayback"`
  plus the `FOREGROUND_SERVICE_MEDIA_PLAYBACK` permission and the matching
  `ServiceCompat.startForeground(..., FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)`.
  https://developer.android.com/develop/background-work/services/fgs/service-types
  https://developer.android.com/about/versions/14/changes/fgs-types-required
  **kaya should not do this.** An in-window video widget stops when the window
  goes away; background playback is an app concern (media3-session /
  `MediaSessionService`), not a widget concern. State it as an explicit non-goal.
- **DRM**: out of scope, but note SurfaceView is the *only* surface type that
  supports secure output, so choosing TextureView forecloses it permanently.
- **The hole in a scrolling list.** Two separate problems:
  (a) *lifecycle*: pre-Android-14, a SurfaceView's surface is destroyed on
  visibility change, so a recycled row restarts playback late. Android 14's
  `setSurfaceLifecycle(SURFACE_LIFECYCLE_FOLLOWS_ATTACHMENT)` fixes it; before
  that, translate off-screen instead of hiding.
  (b) *clipping*: the video is composited by SurfaceFlinger against the window,
  so it does **not** clip to the scroll viewport's rounded corners, and during a
  fling the hole and the buffer can desync. media3's 1.11 `PlayerPool` /
  `rememberPooledPlayer` exists precisely because feed-of-videos is hard
  (https://developer.android.com/jetpack/androidx/releases/media3).
  If kaya has `scroll` + `video` in one scene, this is the failure to expect.

---

#### PART B — LINUX / GTK4

##### B7. GtkVideo / GtkMediaFile / GtkMediaStream / GtkMediaControls

###### GtkVideo — read the class description before designing anything

https://docs.gtk.org/gtk4/class.Video.html — "Shows a `GtkMediaStream` with media
controls." And the warning that decides kaya's architecture:

> "The controls are available separately as `GtkMediaControls`. If you just want
> to display a video without controls, you can treat it like any other paintable
> and for example put it into a `GtkPicture`.
> GtkVideo aims to cover use cases such as previews, embedded animations, etc.
> It supports autoplay, looping, and simple media controls. It does not have
> support for video overlays, multichannel audio, device selection, or input.
> **If you are writing a full-fledged video player, you may want to use the
> `GdkPaintable` API and a media framework such as Gstreamer directly.**"

Constructors: `gtk_video_new()`, `new_for_media_stream()`, `new_for_file()`,
`new_for_filename()`, `new_for_resource()`.
Properties: `autoplay`, `loop`, `media-stream`, `file`, and **`graphics-offload`
(since 4.14)**.

**Can it play with no controls? Yes — but not by a GtkVideo property.** There is
no `show-controls` property on GtkVideo; the controls overlay is baked in. The
documented way to get a bare video is to skip GtkVideo entirely and put the
`GtkMediaStream` (which *is* a `GdkPaintable`) into a `GtkPicture`. That is
almost certainly what kaya wants, since kaya draws its own controls or none:

```c
GtkMediaStream *s = gtk_media_file_new_for_filename(path);   /* is a GdkPaintable */
GtkWidget *w = gtk_picture_new_for_paintable(GDK_PAINTABLE(s));
gtk_media_stream_set_loop(s, TRUE);
gtk_media_stream_play(s);
```

###### GtkMediaStream — the whole app-facing control surface

https://docs.gtk.org/gtk4/class.MediaStream.html — "the integration point for
media playback inside GTK", and **it implements `GdkPaintable`**.

Consumer API (this maps 1:1 onto a kaya `video` kind):
- properties: `playing`, `ended`, `error`, `has-audio`, `has-video`, `muted`,
  `volume`, `loop`, `prepared`, `seekable`, `seeking`, `timestamp`, `duration`
- methods: `play()`, `pause()`, `set_playing()`, `seek(timestamp)`,
  `is_seekable()`, `get_timestamp()`, `get_duration()`, `get_ended()`,
  `set_volume()`, `set_muted()`, `set_loop()`, `realize()`/`unrealize()`
- Timestamps are **microseconds** (`gint64`), unlike media3's milliseconds.
- "ended" is a **property**, so the app watches `notify::ended` rather than a
  dedicated signal — same for `timestamp` (which is why a progress readout is a
  `notify::timestamp` handler).
- No `set_playback_speed` / rate control at all. **This is a parity hole**: media3
  has `setPlaybackSpeed`, AVPlayer has `rate`, MediaPlayerElement has
  `PlaybackRate` — GtkMediaStream has none. If kaya wants a `speed` prop it either
  drops GtkMediaFile for a hand-driven GStreamer pipeline (see B11) or declares
  the carve-out.
- Implementation-only API (for a GtkMediaStream subclass, which is the route a
  Rust-driven player takes): `stream_prepared()`, `stream_unprepared()`,
  `stream_ended()`, `update(timestamp)`, `seek_success()`, `seek_failed()`,
  `gerror()`; virtual methods `play`, `pause`, `seek`, `update_audio`, `realize`,
  `unrealize`.

###### GtkMediaFile

https://docs.gtk.org/gtk4/class.MediaFile.html — "Implements the `GtkMediaStream`
interface for files. This provides a simple way to play back video files with
GTK." and, crucially:

> "GTK provides a GIO extension point for `GtkMediaFile` implementations to allow
> for external implementations using various media frameworks. GTK itself
> includes an implementation using GStreamer."

Constructors: `new`, `new_for_file`, `new_for_filename`, `new_for_resource`,
`new_for_input_stream`; plus `set_file/filename/resource/input_stream`, `clear`.

**So yes, GtkVideo's backend is pluggable** — through the GIO extension point
`gtk-media-file`, selected by priority or overridden by `GTK_MEDIA`. kaya could in
principle register its own `GtkMediaFile` subclass; the far simpler route for a
Rust host is to subclass `GtkMediaStream` directly and feed it frames (B11).

###### GtkMediaControls
https://docs.gtk.org/gtk4/class.MediaControls.html — "Shows controls for video
playback", `gtk_media_controls_new(stream)`, `media-stream` property. "Usually,
GtkMediaControls is used as part of GtkVideo." It is a separate widget, so kaya
can attach it deliberately or never.

---

##### B8. The GStreamer dependency, and what happens in a minimal container

###### Backend selection

`GTK_MEDIA` (https://docs.gtk.org/gtk4/running.html):

> "Specifies what backend to load for `GtkMediaFile`. The possible values depend
> on what options GTK was built with, and can include 'gstreamer' and 'none'.
> **If set to 'none', media playback will be unavailable.** The special value
> 'help' can be used to obtain a list of all supported media backends."

Note the current doc lists only **gstreamer** and **none** — `ffmpeg` is gone.

###### `gtk4-media-ffmpeg` is REMOVED

GNOME/gtk MR **!6872 "Drop ffmpeg support"**, opened by Matthias Clasen
2024-02-10, closing issue #5581:
> "The experimental ffmpeg media backend hasn't been building for a year, and
> nobody showed up with a patch to make it build again."
https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/6872
It landed for **GTK 4.14** (packagers' notes for 4.14.1 record the backend as
removed upstream, e.g.
https://git.openembedded.org/openembedded-core/commit/?id=9d6923da5564d45bbf80fd722184e87b4a2be867).
**GStreamer is the only media backend GTK4 ships today.**

###### What the app sees when the module is missing — GOOD NEWS, it is not silent

GTK ships a fallback no-op implementation, `GtkNoMediaFile`
(`gtk/gtknomediafile.c`), registered so the extension point is never empty. When
an app tries to play with no real backend present it reports, through
`gtk_media_stream_error()` with domain `G_IO_ERROR` / code
`G_IO_ERROR_NOT_SUPPORTED`:

> **"GTK could not find a media module. Check your installation."**

https://gitlab.gnome.org/GNOME/gtk/-/raw/main/gtk/gtknomediafile.c
The selection code in `gtk/gtkmediafile.c` registers the GIO extension point,
honours `GTK_MEDIA` (warning "Media extension \"%s\" from GTK_MEDIA environment
variable not found." for a bad name, printing the list for `help`), and
`g_error()`s outright — "GTK was run without any GtkMediaFile extension being
present. This must not happen." — if not even the no-media stub is registered.
https://gitlab.gnome.org/GNOME/gtk/-/raw/main/gtk/gtkmediafile.c

**Practical consequence for kaya's container lane:** the failure is *observable*.
`gtk_media_stream_get_error()` is non-NULL and the `error` property notifies. So
kaya's GTK backend can turn "no media module" into a real kaya-level error rather
than a black rectangle — and the harness can assert on it. **Wire that from day
one**, because a silent black rectangle is exactly the false-green class this
project keeps finding.

###### Which pieces the container actually needs

The module is packaged separately from GTK itself. Debian/Ubuntu
`libgtk-4-media-gstreamer` (https://packages.debian.org/sid/libgtk-4-media-gstreamer,
https://packages.ubuntu.com/noble/libgtk-4-media-gstreamer) — "GStreamer media
backend for the GTK graphical user interface library" — depends on
`libgstreamer1.0-0`, `libgstreamer-plugins-base1.0-0`,
`libgstreamer-plugins-bad1.0-0`, `libgstreamer-gl1.0-0`, `libgtk-4-1`,
`libglib2.0-0`, `libgraphene-1.0-0`. Note those are the *shared libraries*, not
the plugin sets: **the package lists no Depends/Recommends on
`gstreamer1.0-plugins-good` / `-bad` / `-ugly` / `-libav` at all.** A container
that installs the media module still has no codecs unless the plugin packages are
installed explicitly. Minimum realistic set for H.264-in-MP4:
`gstreamer1.0-plugins-base` (playback, videoconvert, typefind),
`gstreamer1.0-plugins-good` (qtdemux/isomp4, matroska),
plus a decoder — `gstreamer1.0-libav` (`avdec_h264`) or
`gstreamer1.0-plugins-bad`'s `openh264dec`. For VP8/VP9 (WebM),
`gstreamer1.0-plugins-good` carries the libvpx elements, so a **VP9/WebM asset
needs strictly fewer packages and no patent-encumbered decoder** than H.264.

The GTK backend itself drives GStreamer's high-level play API — `gst_player_new()`
handed a `GtkGstPaintable` as the `GstPlayerVideoRenderer` (i.e. playbin under the
hood, rendering into a GTK paintable), and it forwards GStreamer errors verbatim
via `gtk_media_stream_gerror()`. It does **not** special-case
missing-plugin messages, so a missing decoder arrives as a generic GStreamer error
string rather than a "install this codec" hint.
https://raw.githubusercontent.com/GNOME/gtk/gtk-4-18/modules/media/gtkgstmediafile.c

**Recommendation:** kaya's linux container should install the media module + the
plugin sets it needs and the lane should assert playback actually advanced
(`timestamp` moved, `ended` fired) rather than merely that the widget exists.
Also worth an explicit `GTK_MEDIA=none` negative leg: it makes the "no media
module" error path a *watched* branch instead of a believed one.

---

##### B9. Codec coverage on Linux

Unlike Android there is **no mandate**. What decodes depends entirely on which
GStreamer plugin packages the machine (or container) has. The relevant split,
from GStreamer's own plugin docs:

| codec | element | plugin module | typical package |
|---|---|---|---|
| H.264 | `avdec_h264` | gst-libav | `gstreamer1.0-libav` / `gstreamer1-libav` |
| H.264 | `openh264dec` | gst-plugins-**bad** | `gstreamer1.0-plugins-bad` / Fedora's `gstreamer1-plugin-openh264` |
| H.265 | `avdec_h265` | gst-libav | `gstreamer1.0-libav` |
| VP8 / VP9 | `vp8dec` / `vp9dec` (libvpx) | gst-plugins-**good** | `gstreamer1.0-plugins-good` |
| AV1 | `dav1ddec` | gst-plugins-**rs** (Rust) | `gstreamer1.0-plugins-rs` / `gst-plugin-dav1d` |
| AV1 | `av1dec` (libaom) | gst-plugins-bad | `gstreamer1.0-plugins-bad` |
| MP4/MOV demux | `qtdemux` | gst-plugins-good | `gstreamer1.0-plugins-good` |
| WebM/MKV demux | `matroskademux` | gst-plugins-good | `gstreamer1.0-plugins-good` |

- openh264: https://gstreamer.freedesktop.org/documentation/openh264/index.html
  ("GStreamer Bad Plug-ins": `openh264dec`, `openh264enc`)
- gst-libav: https://gstreamer.freedesktop.org/documentation/libav/index.html
  (`avdec_h264`, `avdec_h265`, `avdec_vp9`, ... — "GStreamer FFMPEG Plug-ins")
- dav1d improvements in 1.26: https://gstreamer.freedesktop.org/releases/1.26/

**Licensing reality that bites a distro-portable toolkit:** Debian/Ubuntu ship
`gstreamer1.0-libav` (so `avdec_h264`/`avdec_h265` are one apt away). Fedora
ships only `ffmpeg-free` and directs users to RPM Fusion for the restricted
codecs — RPM Fusion's own multimedia howto says its `@multimedia` group is what
"allows the application using the gstreamer framework and other multimedia
software, to play others restricted codecs", and notes "Fedora or EPEL
ffmpeg-free works most of the time, but one will experience version mismatch"
(https://rpmfusion.org/Howto/Multimedia). Fedora's H.264 route is Cisco's
openh264 (`openh264dec`, from gst-plugins-bad). Net: **H.264 and HEVC are
conditionally present on Linux and you cannot assume them.** Practical rule:
**VP8/VP9-in-WebM is the only video that decodes out of the box on essentially
every desktop Linux install**, because libvpx is in plugins-good and unencumbered.
For kaya's test asset, use **VP9/WebM** (or VP8, for maximum reach); it also
avoids the emulator HEVC bug on the Android side and is decodable by every
platform kaya targets.

###### Hardware decode

Two generations, and the older one is now dead:
- **`gstreamer-vaapi`** (`vaapih264dec`, `vaapipostproc`, ...) — **deprecated**.
  GStreamer 1.26 release notes: "gstreamer-vaapi has been deprecated and is no
  longer actively maintained. Users who rely on gstreamer-vaapi are encouraged
  to migrate to the `va` plugin's elements at the earliest opportunity."
  (`vaapi*enc` encoders demoted to rank None so they are no longer autoplugged.)
  https://gstreamer.freedesktop.org/releases/1.26/
- **`va` plugin** (in gst-plugins-**bad**) — the replacement.
  `vah264dec`, `vah265dec`, `vavp8dec`, `vavp9dec`, `vaav1dec`, `vampeg2dec`,
  `vajpegdec`, plus `vapostproc`, `vadeinterlace`, `vacompositor` and AV1/H.264/
  H.265/JPEG encoders including low-power variants. All classed "Hardware".
  https://gstreamer.freedesktop.org/documentation/va/index.html
  On Intel/AMD this is what playbin autoplugs when `libva` + the driver
  (`intel-media-va-driver`, `mesa-va-drivers`) are present. NVIDIA goes through
  `nvcodec` (`nvh264dec` etc.) instead.

**In kaya's container lane there is no VA-API** (no /dev/dri, or no driver), so
everything is software decode. That is fine for a small test clip and is one more
reason to keep the asset small and cheap (VP9, a few hundred KB, short).

---

##### B10. Embedding — GtkVideo is a NORMAL WIDGET (the good news)

This is the sharpest contrast with Android and it is worth stating plainly in
kaya's design doc.

A `GtkMediaStream` **is a `GdkPaintable`**
(https://docs.gtk.org/gtk4/class.MediaStream.html), and a `GdkPaintable` is
"an interface for content that can be painted ... can be painted anywhere at any
size without requiring any sort of layout"; it is drawn by snapshotting into a
`GtkSnapshot`, i.e. it becomes **`GskRenderNode`s in the app's own render tree**
(https://docs.gtk.org/gdk4/iface.Paintable.html). GtkVideo/GtkPicture are
ordinary widgets that snapshot the paintable.

Therefore, on GTK4, a video:
- clips normally (scroll viewports, rounded corners via `GskRoundedClipNode`),
- z-orders normally (overlays, popovers and menus draw over it),
- transforms and animates normally (`GskTransformNode`, opacity),
- scrolls without tearing away from the widget that owns it.

There is **no hole, no separate compositor layer, no `setZOrderOnTop` analogue.**
Everything goes through `GskRenderer` — `GSK_RENDERER` selects among
`ngl`/`opengl`/`gl`, `vulkan`, `cairo`, `broadway`
(https://docs.gtk.org/gtk4/running.html).

###### The one place a hole reappears: graphics offload

`GtkGraphicsOffload` (**GTK 4.14+**, https://docs.gtk.org/gtk4/class.GraphicsOffload.html):
"Bypasses gsk rendering by passing the content of its child directly to the
compositor." It is an optimization for video and VM displays that "reduce[s]
overhead and battery consumption", and it is **opt-in** — GtkVideo exposes it as
the `graphics-offload` property (also 4.14).

The caveats read exactly like the Android SurfaceView list, which is the point:
- **Linux/Wayland only** (it is implemented with Wayland subsurfaces).
- Content should be a **dmabuf texture** (`GdkDmabufTextureBuilder`;
  `GdkDmabufTexture` is "A `GdkTexture` representing a DMA buffer", since 4.14,
  "can only be created on Linux" — https://docs.gtk.org/gdk4/class.DmabufTexture.html).
- **Offload is silently declined** when there is clipping or rounded corners,
  an unsupported dmabuf format, translucent content with an alpha channel,
  transforms beyond translation/scale, or filters like opacity or grayscale.
- "Graphics offload is most efficient if there are no controls drawn on top of
  the video content."
- `GDK_DEBUG=offload` prints "Information about subsurfaces and graphics offload
  (Wayland-only)", and there is a debug flag to "Force graphics offload for all
  textures, even when slower ... to debug offloading in the absence of dmabufs."
  https://docs.gtk.org/gtk4/running.html
- `black-background` property added in 4.16.

**Design rule for kaya:** leave `graphics-offload` **off** by default. Offload
gives up exactly the properties (clipping, rounded corners, opacity, transform)
that make GTK's video widget behave like every other kaya widget, and it degrades
silently rather than erroring — a "why is my rounded video square on Wayland
only" bug with no error anywhere. Expose it, if at all, as an explicit opt-in
performance hint, and note that kaya's own X11 lane cannot exercise it at all.
Also: `GDK_DISABLE=dmabuf` exists, which is a cheap way for the lane to pin the
non-offloaded path.

---

##### B11. The alternative Rust-native route: gstreamer-rs + gtk4paintablesink

**This is the route kaya should seriously consider**, because kaya's host is Rust
and `GtkMediaFile` has no speed control, no track selection, and no pipeline
access.

`gtk4paintablesink` is a GStreamer **video sink written in Rust** that hands you a
`gdk::Paintable`:
https://gstreamer.freedesktop.org/documentation/gtk4/index.html
> "a `gst_video::VideoSink` along with a `gdk::Paintable` that's capable of
> rendering the sink's frames."

- **Where it lives / maintained?** `gst-plugins-rs`, the official GStreamer Rust
  plugins repository (`video/gtk4`, crate `gst-plugin-gtk4`), hosted on
  freedesktop GitLab and released on GStreamer's own cadence. GStreamer **1.26**
  release notes list "Many GTK4 paintable sink improvements" and "GTK4 paintable
  sink colorimetry support and other improvements" in the bug-fix releases —
  i.e. actively maintained, not a side project.
  https://gstreamer.freedesktop.org/releases/1.26/
  Mirror: https://github.com/GStreamer/gst-plugins-rs (`video/gtk4/README.md`)
- **Zero copy / dmabuf?** Yes, both:
  - GL textures when built with `waylandegl` / `x11glx` / `x11egl` features;
  - "DMABuf rendering is available on Linux with **GTK 4.14+** and the `dmabuf`
    feature enabled" — which is precisely the input `GtkGraphicsOffload` wants.
  - Minimum GTK: 4.4 on Linux without GL, 4.6 on Windows/macOS and Linux with GL.
  - Properties: `paintable`, `window-width`/`window-height`, `use-scaling-filter`,
    `scaling-filter`, plus paintable-side `background-color`,
    `force-aspect-ratio`, `orientation`.
- **Does it let a Rust host drive playback itself?** Yes — that is the whole
  point. kaya's Rust core builds a `playbin3`/`uridecodebin3` pipeline through
  the `gstreamer` crate (gstreamer-rs, https://gitlab.freedesktop.org/gstreamer/gstreamer-rs),
  sets `video-sink` to `gtk4paintablesink`, reads its `paintable` property and
  puts it in a `GtkPicture`. Then kaya owns: play/pause (`set_state`), seek
  (`seek_simple` with `SeekFlags::FLUSH | ACCURATE` vs `KEY_UNIT` — the exact
  analogue of media3's `SeekParameters`), **rate** (`seek` with a rate != 1.0,
  which is the speed control GtkMediaStream lacks), volume/mute (playbin
  properties), position/duration (`query_position`/`query_duration`), EOS and
  error via the bus, and track selection.
- It also runs on **Windows and macOS** (GL by default there), which is a bonus
  but irrelevant given the other backends.

**Tradeoff.** `GtkMediaFile` is 5 lines, is in GTK proper, needs one extra distro
package, and gives kaya less than the other four platforms offer.
`gstreamer-rs` + `gtk4paintablesink` is maybe 200 lines of Rust, adds
`gstreamer`/`gstreamer-video` crates and the `gst-plugin-gtk4` .so to the linux
lane's dependency set, and gives kaya full parity with media3/AVPlayer/MediaPlayerElement.
**If the `video` kind is to have `speed` and honest `seek` semantics, this is the
only GTK route that gets there.** A middle path also exists: implement kaya's own
`GtkMediaStream` subclass over that pipeline, so GtkVideo/GtkMediaControls still
work if an app wants them.

---

#### PART C — SYNTHESIS FOR THE `video` KIND (my slice's view)

##### C1. The two platforms are architecturally OPPOSITE, and that is the design's hardest fact

| | Android (Compose/media3) | Linux (GTK4) |
|---|---|---|
| what the widget is | a **hole**: SurfaceView composited by SurfaceFlinger in its own layer | a **paintable**: GskRenderNodes in the app's own render tree |
| clip to rounded corners | no (unless TextureView) | yes |
| siblings painted ON TOP of the video | yes (the hole follows layout) | yes |
| video painted on top of chosen siblings | no — only the whole-window `setZOrderOnTop` | yes |
| two videos ordered relative to each other | no — only the media-overlay bit | yes |
| transform / opacity / animation | no (unless TextureView) | yes |
| app can read the pixels | no (unless TextureView) | yes (it is a texture GTK drew) |
| the "hole" mode | the default and the recommended one | **opt-in** (`GtkGraphicsOffload`, Wayland only) |

GTK's `GtkGraphicsOffload` is precisely Android's SurfaceView, offered as an
opt-in optimization with the same caveat list. That symmetry is the cleanest way
to state the rule uniformly:

> **Proposed uniform semantics:** a kaya `video` widget participates in layout,
> clipping and z-order like any other widget. Where a platform's hardware video
> path cannot honour that, the platform uses the composited path and the
> divergence is stated: **on Android the default surface (`SurfaceView`) is not
> clipped, rounded, faded or transformed, and cannot be ordered above a chosen
> sibling — though siblings drawn over it work normally.** kaya may offer
> `video(..., composited: bool)` — false meaning "behave like a widget"
> (TextureView on Android, no offload on GTK) and true meaning "cheapest power"
> (SurfaceView, GtkGraphicsOffload).

That single prop maps onto both platforms' real knobs and does not invent
anything. It is also the honest way to expose the fact that the cheap path costs
you clipping.

##### C2. The property/verb surface that exists on BOTH

Safe to promise uniformly:
`source`, `play`/`pause` (or `playing: bool`), `seek(position)`, `position`,
`duration`, `volume`, `muted`, `loop`, `autoplay`, `ended` event,
`video size` / natural aspect ratio, `error`.

Watch out:
- **units**: GTK is microseconds, media3 is milliseconds. Pick one at the kaya
  wire (microseconds is the safer, lossless choice) and convert per backend.
- **`speed` / playback rate**: media3 has it (`setPlaybackSpeed`);
  **`GtkMediaStream` does not**. Either drop `speed` from v1, or take the
  gstreamer-rs route on Linux (B11) where a rate-seek gives it.
- **seek exactness**: media3 defaults to EXACT and can be told to keyframe-seek;
  GStreamer's `ACCURATE` vs `KEY_UNIT` seek flags are the same distinction; but
  media3 ignores seek parameters for HLS. Document "best effort", do not promise
  frame accuracy.
- **`ended`**: GTK is a *property* (`notify::ended`, `gtk_media_stream_get_ended`),
  media3 is a *state* (`onPlaybackStateChanged(STATE_ENDED)`). Same semantics,
  different shape — fine.
- **`error`**: GTK gives you a `GError` on the stream (including the very useful
  "GTK could not find a media module"); media3 gives `PlaybackException`. Both
  should reach kaya as one error observable. **Make it observable in the scene**,
  because both platforms' failure mode is otherwise a blank rectangle.

##### C3. CI / harness implications (the part most likely to burn a matrix)

1. **Pick one asset and one codec for every lane: VP9 (or VP8) in WebM.**
   - Android: VP9 required since 4.4, decodes on the emulator via goldfish/software.
   - Linux: libvpx lives in gst-plugins-**good**, no patent-encumbered package,
     present in every container base that has GStreamer at all.
   - Avoids the emulator's broken `c2.goldfish.hevc.decoder`
     (https://github.com/androidx/media/issues/2461) entirely.
   - Keep it a few hundred KB and a few seconds; software decode only.
   - The asset goes under `guests/assets/` as its own family with a README saying
     how it was generated (per check-assets), and the assets.steps census moves.
2. **A pixel assertion over a video on Android will read the hole, not the video**
   unless the surface is a TextureView or the capture is taken at the system
   level. If kaya wants `expect_ink` over a `video`, either force
   `SURFACE_TYPE_TEXTURE_VIEW` in the harness build, or capture via
   `UiAutomation.takeScreenshot()`/`adb shell screencap` which do include
   SurfaceView layers. Decide this BEFORE writing the scene.
3. **Assert progress, not presence.** The observable that catches "no codec /
   no media module / decoder init failed" on both platforms is *the position
   advanced past N ms and `ended` eventually fired*, not "the widget exists".
   A `expect_video_progress`-shaped verb is the one that cannot be satisfied by a
   black rectangle.
4. **A `GTK_MEDIA=none` negative leg** makes GTK's "could not find a media module"
   error path a watched branch. Cheap, and it is the exact shape of guard this
   project asks for (a diagnostic nobody has seen print is a guess).
5. **Android emulator flake risk**: enable
   `DefaultRenderersFactory.setEnableDecoderFallback(true)`
   (https://github.com/google/ExoPlayer/issues/10576) and expect the first frame
   to arrive late — `rememberPresentationState(...).coverSurface` is the signal
   for "no frame yet", and the harness should wait on it rather than on a timer.
6. **Duration is unknown at first.** media3 returns `C.TIME_UNSET`; GTK's
   `duration` is 0 until `prepared`. Any scene reading duration must wait for
   the prepared/READY transition.

##### C4. New dependencies each platform adds

- **Android**: `androidx.media3:media3-exoplayer:1.11.0` +
  `androidx.media3:media3-ui-compose:1.11.0`. That is all — no NDK decoder
  extensions, no material3 module (kaya draws its own controls, if any),
  no media3-session, no foreground service. Two Maven coordinates.
- **Linux**: GTK's `libgtk-4-media-gstreamer` module plus GStreamer core +
  plugins-base + plugins-good (and libav or openh264 only if H.264 is wanted).
  If kaya takes the gstreamer-rs route instead: the `gstreamer` /
  `gstreamer-video` crates in the Rust core (behind the linux cfg) plus
  `gst-plugin-gtk4`'s `libgstgtk4.so`.

##### C5. Open questions worth putting to the maintainer

1. **Is `video` a widget kind or a canvas source?** kaya already has a canvas that
   the core rasterizes ("kaya rasterizes, backends blit"). A native player view is
   the exact opposite: the platform decodes and composites and kaya never sees
   the pixels. That is a genuine architectural exception to the canvas rule and
   needs a ruling, not a default. (The GTK side *could* be made to obey the rule
   — dav1d/libvpx decoding into kaya's own raster — but Android's cannot, at any
   acceptable power cost.)
2. **Does `video` need `speed`?** If yes, GTK's simple route is out (B11 required).
3. **Composited vs widget-like** (C1) — one prop, or one uniform choice?
4. **Pixel assertions over video**: does the harness need them at all, or is
   "position advanced + ended fired + natural size reported" enough? The answer
   decides whether Android must use TextureView in the harness.

### §1.3 What this means for kaya

A `video` kind over the four native players is buildable on all five
backends today, and the surface it can expose uniformly is roughly MAUI's:
source, autoplay, loop, muted, volume, speed, aspect; play/pause/stop/seek;
position, duration, state, natural size; ended, failed, seek_completed. That
is a real widget, and it is enough for a media-bin preview and for a
cut-between-players timeline.

Five things about it are NOT uniform, and each is a ruling rather than a
detail:

1. **The codec floor.** The intersection of what every target decodes with no
   extra install is essentially H.264 in MP4 with AAC. Apple cannot play VP9,
   WebM or MKV at all; Windows plays VP9 and MKV in-box but needs a paid
   Store extension for HEVC and AV1; Android mandates H.264, VP8, VP9, HEVC
   and AV1; GStreamer depends on which plugin sets are installed. The one
   codec an iPhone records by default — HEVC — is the one Windows cannot open
   without a purchase kaya cannot make for the user.
2. **Chrome ownership.** SwiftUI's `VideoPlayer` cannot hide its controls at
   all, so the Apple arm must be `AVPlayerLayer` (or `AVPlayerView`/
   `AVPlayerViewController` with controls disabled, which keeps AirPlay,
   Picture-in-Picture and Now Playing for free). Turning platform chrome off
   also turns off what it was wired to — lock-screen metadata, keep-awake —
   so those become explicit props or they are silently lost.
3. **Current-frame access diverges semantically.** Apple's
   `AVPlayerItemVideoOutput` is ADDITIVE (the player keeps drawing while you
   pull frames); Windows' frame-server mode is EXCLUSIVE — Microsoft's own
   remarks say "the media player does not render video content." Under
   invariant 1 that means v1 exposes poster/thumbnail extraction against a
   FILE and does not expose "the frame playing right now" at all.
4. **How the video composites is a per-platform spectrum, not a constant.**
   Android's SurfaceView punches a hole (cheap, low power, but no rounded
   corners, no alpha, no transform on the video itself); GTK is a normal
   widget unless `GtkGraphicsOffload` is opted into (Wayland only, silently
   declined by clipping or rounding); WinUI's MediaPlayerElement is a normal
   XAML element but SwapChainPanel is not. A single `composited` prop that
   maps to each platform's real knob, with its cost stated, is the honest
   spelling.
5. **The Linux lane has no precedent and no packages.** MAUI has no Linux
   row; kaya's container installs `libgtk-4-dev` and no GStreamer at all.

The good news is that the two hardest-sounding worries are not real. GTK's
video widget behaves like an ordinary widget (it clips, scrolls and z-orders
normally, because GTK snapshots a paintable into its own render nodes), and
WinUI 3 has no airspace problem — `MediaPlayerElement` shipped in Windows App
SDK 1.2 and `MediaPlayerPresenter` is a plain `FrameworkElement` in the XAML
tree, unlike WPF's per-HWND regions.

---

## §2 — The owned-rendering route

### §2.1 The decoders, the licensing, and the patent-free path
Research date: 2026-09-02. Every claim carries a URL. Primary sources preferred.

##### Crate maintenance snapshot (observed 2026-09-02, crates.io JSON API)

| crate | latest | last release | downloads | repo |
|---|---|---|---|---|
| `ffmpeg-next` | **9.0.0** | **2026-08-05** | 6,766,861 | https://github.com/zmwangx/rust-ffmpeg |
| `rsmpeg` | **0.18.0+ffmpeg.8.0** | **2025-08-24** | 168,571 | https://github.com/larksuite/rsmpeg |
| `gstreamer` (gstreamer-rs) | **0.25.3** | **2026-06-29** | 10,029,512 | https://gitlab.freedesktop.org/gstreamer/gstreamer-rs |
| `windows` (windows-rs) | **0.62.2** | **2025-10-06** | 312,237,949 | https://github.com/microsoft/windows-rs |
| `objc2-video-toolbox` | **0.3.2** | **2025-10-04** | 49,981 | https://github.com/madsmtm/objc2 |
| `ndk` (rust-mobile) | **0.9.0** | **2024-04-26** | 50,881,460 | https://github.com/rust-mobile/ndk |
| `cros-codecs` | **0.0.6** | **2025-06-18** | 1,992,353 | https://github.com/chromeos/cros-codecs |
| `rav1d` | **1.1.0** | **2025-05-07** | 32,940 | https://github.com/memorysafety/rav1d |
| `dav1d` (dav1d-rs) | **0.11.1** | **2025-11-25** | 1,238,301 | https://github.com/rust-av/dav1d-rs |

Sources: https://crates.io/api/v1/crates/ffmpeg-next , /rsmpeg , /gstreamer , /windows , /objc2-video-toolbox , /ndk , /cros-codecs , /rav1d , /dav1d

##### A1. Apple — VideoToolbox vs AVAssetReader

**Apple's own framing.** The VideoToolbox landing page abstract is "Work directly with hardware-accelerated video
encoding and decoding capabilities", and the overview reads:

> "VideoToolbox is a low-level framework that provides direct access to hardware encoders and decoders. It
> provides services for video compression and decompression, and for conversion between raster image formats
> stored in CoreVideo pixel buffers. These services are provided in the form of session objects (compression,
> decompression, and pixel transfer), which are vended as Core Foundation (CF) types. **Apps that don't need
> direct access to hardware encoders and decoders shouldn't need to use VideoToolbox directly.**"

Platform floors listed there: iOS/iPadOS 6.0, macOS 10.8, tvOS 10.2, Mac Catalyst 13.0, visionOS 1.0.
Source: https://developer.apple.com/documentation/videotoolbox (JSON: https://developer.apple.com/tutorials/data/documentation/videotoolbox.json)

**It is a C API, not Objective-C.** The types are Core Foundation types (`VTDecompressionSessionRef`,
`CMSampleBufferRef`, `CVImageBufferRef`) and the entry points are plain C functions with a C function-pointer
output callback — `VTDecompressionSessionCreate(allocator:formatDescription:decoderSpecification:imageBufferAttributes:outputCallback:decompressionSessionOut:)`
and `VTDecompressionSessionDecodeFrame(_:sampleBuffer:flags:frameRefcon:infoFlagsOut:)`.
Sources: https://developer.apple.com/documentation/videotoolbox/1536134-vtdecompressionsessioncreate ,
https://developer.apple.com/documentation/videotoolbox/1536071-vtdecompressionsessiondecodefram
The decompression output callback hands back a **`CVImageBufferRef`** (a `CVPixelBuffer`), and by asking for
`kCVPixelBufferIOSurfacePropertiesKey` in `imageBufferAttributes` you get IOSurface-backed buffers that can be
handed to Metal/CoreImage with no copy.

**The two levels, and which is right for kaya.**
- `AVAssetReader` + `AVAssetReaderTrackOutput` is the *file* level: it demuxes, feeds the decoder, and vends
  decoded `CVPixelBuffer`s in the pixel format you asked for in the output settings. Apple's own description:
  "If you want only to read media data from one or more tracks and potentially convert that data to a different
  format, use the AVAssetReaderTrackOutput class."
  https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput
- `VTDecompressionSession` is the *sample* level: you already have a `CMSampleBuffer` (you demuxed it yourself,
  or it came off a network socket) and you want it decoded.

For "give me decoded frames of a file as fast as possible" the right level is **AVAssetReader**: it is the
supported route, it handles the demux, and (WWDC20 session 10090, "Decode ProRes with AVFoundation and
VideoToolbox") it "reads samples from the source file, optimizing them for the RPC that will happen in the
Video Toolbox, and it decodes the video data in the sandbox process, providing the decoded CVPixelBuffers in
the requested output format." https://developer.apple.com/videos/play/wwdc2020/10090/
VTDecompressionSession is the right level only when kaya wants to own the container parsing (which it would
have to if it wants ONE demuxer across five platforms).

**Rust crates (objc2 family, madsmtm).** All observed 2026-09-02 on crates.io:
- `objc2-video-toolbox` 0.3.2, released **2025-10-04**, 49,981 downloads. https://crates.io/crates/objc2-video-toolbox
- `objc2-core-video` (CVPixelBuffer/CVImageBuffer) and `objc2-core-media` (CMSampleBuffer) are siblings in the
  same generated family; `objc2-av-foundation` covers AVAssetReader. Repo: https://github.com/madsmtm/objc2
The whole family is auto-generated from Apple's own headers/metadata and released in lockstep, so maintenance
state is "actively generated" rather than "hand-maintained per framework" — but note the version numbers are
0.3.x, i.e. pre-1.0 and API-unstable.
The older hand-written `core-video-sys` / `core-foundation-sys` route still exists but the objc2 family has
displaced it for new work.

##### A2. Android — AMediaCodec / AMediaExtractor

**API floor.** The NDK media APIs (`AMediaCodec`, `AMediaExtractor`, `AMediaFormat`) were introduced in
**API 21 (Android 5.0 Lollipop)**; the headers carry `__INTRODUCED_IN(21)` on the core entry points.
`AImageReader` (`media/NdkImage.h`, `media/NdkImageReader.h`) is **API 24**, and `AHardwareBuffer` is **API 26**.
Sources: https://developer.android.com/ndk/reference/group/media ,
https://android.googlesource.com/platform/frameworks/av/+/master/media/ndk/include/media/NdkMediaCodec.h
kaya's Android floor is already well above 21, so the NDK route is available unconditionally.

**Both output routes exist.**
- **To a CPU buffer:** configure with a NULL surface, then `AMediaCodec_dequeueOutputBuffer` +
  `AMediaCodec_getOutputBuffer` gives you a `uint8_t*` of the decoded frame in whatever colour format the codec
  negotiated (typically some NV12/YUV420 flavour, and the exact one is *device-dependent* — this is the classic
  MediaCodec portability tax; see Big Flake's long-standing notes, https://www.bigflake.com/mediacodec/).
- **To a Surface:** configure with an `ANativeWindow`. For an app that wants the pixels back rather than
  composited, the zero-copy route is `AImageReader_newWithUsage()` → `AImageReader_getWindow()` → hand that
  `ANativeWindow` to `AMediaCodec_configure`, then `AImageReader_acquireNextImage` and
  `AImage_getHardwareBuffer()` for an `AHardwareBuffer` you can import into GL/Vulkan without a CPU copy.
  Both Chromium and Firefox took exactly this route:
  https://bugzilla.mozilla.org/show_bug.cgi?id=1649110 (Firefox "Add AImageReader with MediaCodec support on Android"),
  https://groups.google.com/a/chromium.org/g/feature-media-reviews/c/vuadhaZcLo0 (Chromium "Implement Video decode path using AImageReader").

**The cost difference.** Surface/AImageReader output keeps the frame in GPU-resident memory; the ByteBuffer route
forces the decoder to write to (and often *convert into*) system memory. Firefox's own bug notes that with
AHardwareBuffer "there's no need for additional GL texture images and memory usage could be reduced", whereas
the shared-memory path needs an extra GL texture upload per frame. The counterweight Chromium recorded is that
cross-process IPC between AImageReader and MediaCodec can *slow* decode; in-process it is fine.
**For kaya this matters a lot**: kaya rasterizes on the CPU with tiny-skia and the backends blit. A CPU-side
frame is what kaya's architecture actually wants — which means Android's *cheap* path (Surface) is the one kaya
would have to undo, and the ByteBuffer path is the one whose device-dependent colour formats kaya would have to
normalise itself.

**Rust access.** The `ndk` crate (rust-mobile) has a `media` module ("Bindings for the NDK media classes"),
a `media_error` module, and `hardware_buffer` (API 26) / `hardware_buffer_format` modules.
https://docs.rs/ndk/latest/ndk/ — but note the crate's last release is **0.9.0, 2024-04-26**
(https://crates.io/api/v1/crates/ndk), i.e. no release in over two years as of 2026-09; `ndk-sys` carries the raw
bindgen output regardless. So the raw FFI is there; the safe wrapper is stale and kaya would likely drive
`ndk-sys` directly.

##### A3. Linux — GStreamer, VA-API, and the honest answer

**GStreamer + `appsink` is the pull-decoded-frames route.** `decodebin` (or `uridecodebin`) → `appsink`, and the
app calls `pull_sample()` / `try_pull_sample()`; the docs note appsink internally queues buffers from the
streaming thread and will grow memory if the app does not pull fast enough, and that `emit-signals=true` gives
a callback shape instead. https://gstreamer.pages.freedesktop.org/gstreamer-rs/git/docs/gstreamer_app/struct.AppSink.html
Rust example (upstream): https://github.com/sdroege/gstreamer-rs/blob/main/examples/src/bin/decodebin.rs
`gstreamer-rs` is the healthiest binding in this whole survey: **0.25.3 released 2026-06-29**, 10.0M downloads,
maintained by Sebastian Dröge at https://gitlab.freedesktop.org/gstreamer/gstreamer-rs

**What must be installed.** The bindings need GStreamer ≥ 1.14 and gst-plugins-base ≥ 1.14 to *build*; to
actually decode anything you need plugins from base/good/bad/ugly and/or **gst-libav**. On Debian/Ubuntu the
usual set is `libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-{base,good,bad,ugly}
gstreamer1.0-libav`. (gstreamer-rs README, https://gitlab.freedesktop.org/gstreamer/gstreamer-rs)

**THE CATCH, and it is the important finding for this slice:** GStreamer's software H.264 decoder *is FFmpeg*.
`avdec_h264` is described by GStreamer's own documentation as the "libav h264 decoder", shipped in the
**"GStreamer FFMPEG Plug-ins"** package (gst-libav).
https://gstreamer.freedesktop.org/documentation/libav/avdec_h264.html
So "use GStreamer on Linux instead of FFmpeg" does not avoid FFmpeg — it moves the FFmpeg dependency into the
distro's package set, where the *distro* has already made the LGPL/GPL/patent decision on the user's behalf.
That is a real advantage (kaya distributes no codec) and a real fragility (a machine without gst-libav or a
hardware decoder plugin simply cannot open an H.264 file, and kaya's error message is "no decoder").

**VA-API directly (`libva`, or `cros-codecs`).** Realistic only as an *accelerator*, not as the route:
- It is decode/encode *acceleration*, not a demuxer; you still need to parse the container and the bitstream
  headers yourself, which is why `cros-codecs` ships H.264/H.265/VP8/VP9/AV1 *stream parsers* alongside its
  VAAPI backend. https://github.com/chromeos/cros-codecs
- Driver coverage is uneven. Arch's wiki: Intel works via intel-media-driver from Broadwell on; AMD works with
  the free drivers; **NVIDIA proprietary needs the third-party `nvidia-vaapi-driver`, which is "intended mostly
  for web browser support and may not correctly work in other apps", decode only.**
  https://wiki.archlinux.org/title/Hardware_video_acceleration , https://wiki.debian.org/HardwareVideoAcceleration
- `cros-codecs` maintenance: **0.0.6, last released 2025-06-18** (https://crates.io/api/v1/crates/cros-codecs).
  Still 0.0.x after three years; it is Google/ChromeOS-internal-first ("developed for use in ChromeOS,
  particularly crosvm"). Usable as a reference for bitstream parsing; not a product dependency.

**"Is there a Linux route with NO system GStreamer?"** Practically: **FFmpeg (vendored/statically built) is the
only self-contained one**, unless kaya writes its own demuxer + bitstream parsers and drives libva/V4L2 itself
(the cros-codecs shape) — which is the largest engineering item in this whole document and still leaves the
NVIDIA-proprietary hole above. The pure-Rust alternatives (rav1d for AV1, dav1d-rs, openh264-rs) are
self-contained but do not cover the codecs the user's footage is in (see §C).

##### A4. Windows — Media Foundation IMFSourceReader

Microsoft's own description of the Source Reader is exactly the level kaya needs:

> "The Source Reader is an alternative to using the Media Session and the Microsoft Media Foundation pipeline to
> process media data. … **If the media source delivers compressed data, you can use the source reader to decode
> the data.** In that case, the source reader will load the correct decoder and manage the data flow between the
> media source and the decoder. The source reader can also perform some limited video processing: color
> conversion from YUV to RGB-32, and software deinterlacing, although these operations are not recommended for
> real-time video rendering. … The source reader does not send the data to a destination; it is up to the
> application to consume the data."

https://learn.microsoft.com/en-us/windows/win32/medfound/source-reader
The doc's own "consider using the source reader when: you want to get data from a media file without worrying
about the underlying file structure … you already have a media pipeline that is not based on Media Foundation
and you want to incorporate the Media Foundation media sources into your own pipeline" is a description of kaya.

**`MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING`** — "Enables advanced video processing by the Source
Reader, including color space conversion, deinterlacing, video resizing, and frame-rate conversion." It inserts
a video processor MFT so `SetCurrentMediaType` can request e.g. RGB32 at a given size; the doc says over the
plain `..._ENABLE_VIDEO_PROCESSING` attribute it supports a greater range of conversions and "some conversions
can be performed in hardware using the GPU." Minimum client **Windows 8**.
https://learn.microsoft.com/en-us/windows/win32/medfound/mf-source-reader-enable-advanced-video-processing
This is the attribute that gets kaya a CPU-friendly RGB32 frame without writing a YUV converter.

**Hardware decode** — set `MF_SOURCE_READER_D3D_MANAGER` to an `IMFDXGIDeviceManager` (or the legacy
`IDirect3DDeviceManager9`): "Use this attribute to provide a Direct3D device for any video decoders loaded by
the source reader. If you set this attribute and the decoder supports Microsoft DirectX Video Acceleration
(DXVA), the source reader uses the Direct3D device to allocate video buffers."  Minimum client Windows 7.
https://learn.microsoft.com/en-us/windows/win32/medfound/mf-source-reader-d3d-manager
Note the doc explicitly says not to set it if you only want compressed video out — and, importantly, that the
buffers you get are then DXVA/D3D surfaces, so the CPU read-back is on you.

**Codec availability is NOT unconditional on Windows.** Windows ships an H.264 decoder, but **HEVC/H.265 is not
in the box** — it requires a Microsoft Store extension: the paid "HEVC Video Extensions" (~$0.99) or the free
"HEVC Video Extensions from Device Manufacturer" (OEM-provisioned, not freely installable by everyone). AV1
likewise needs the "AV1 Video Extension". See Microsoft's Store listing and the community write-up:
https://apps.microsoft.com/detail/9nmzlz57r3t7 (HEVC Video Extensions),
https://windowsforum.com/threads/hevc-h-265-support-in-windows-11-how-to-get-free-or-paid-codec-support.373773/
**This is a real argument for owning decode**: on Windows, the platform route cannot open an iPhone's default
recording (HEVC) on a machine that lacks the extension, and kaya cannot make the user buy a Store package.

**Rust access.** `windows` crate 0.62.2 (2025-10-06, 312M downloads, https://crates.io/api/v1/crates/windows)
generates the whole Win32 metadata surface, and Media Foundation is fully covered:
`windows::Win32::Media::MediaFoundation::IMFSourceReader` and every sibling interface exist in the generated
bindings — https://microsoft.github.io/windows-docs-rs/doc/windows/Win32/Media/MediaFoundation/struct.IMFSourceReader.html
The one rough edge on record is implementing MF *callback* interfaces from Rust (async `IMFAsyncCallback`):
https://github.com/microsoft/windows-rs/issues/1378 — avoidable if kaya uses the Source Reader synchronously,
which is the natural shape for "decode this file as fast as possible".

##### A5. Engineering size of "four decoder backends behind one trait"

The honest way to size this is to measure a project that has already done exactly it. **Firefox's
PlatformDecoderModule is the closest analogue**: one `PlatformDecoderModule` interface, a `PDMFactory` that
picks among per-platform implementations. Byte counts read from the GitHub mirror on 2026-09-02
(https://api.github.com/repos/mozilla-firefox/firefox/contents/dom/media/platforms):

| directory | files | bytes |
|---|---|---|
| `dom/media/platforms/` (the trait, factory, allocation policy, codec-support table) | 20 | ~194 KB |
| `dom/media/platforms/apple/` (AppleVTDecoder, AppleATDecoder, AppleVTEncoder) | 12 | **153,729** |
| `dom/media/platforms/wmf/` (DXVA2Manager, WMFVideoMFTManager, MFMediaEngine…) | 52 | **560,871** |
| `dom/media/platforms/android/` (AndroidDecoderModule, RemoteDataDecoder) | 9 | **92,759** |
| `dom/media/platforms/ffmpeg/` (top level only; plus 11 per-version subdirs) | 36 | **461,690** |

Take the decode-only slice and drop the encoder files, and the *per-backend* cost still lands around
**60–250 KB of C++ each, i.e. roughly 2k–8k lines per platform**, with a shared trait + factory layer of
another ~5k lines. Note two things this table shows plainly:
1. **Windows is the expensive one** (560 KB) — DXVA2 device management alone is 54 KB, and Media Foundation's
   surface is large enough that Mozilla eventually added a *second* Windows backend (MFMediaEngine) beside the
   first.
2. **The single-library backend is not cheap either** — Firefox's FFmpeg PDM is 461 KB and carries *eleven*
   per-libavcodec-version shims (ffmpeg57 … ffmpeg63, ffvpx, libav53-55) because it dlopen's whatever the
   distro has. A *vendored, version-pinned* FFmpeg avoids exactly that tax.

Chromium's split is the same shape one size up: `media/filters` holds "software decoding implementations …
backed by FFmpeg and libvpx" and `media/gpu` holds "the platform hardware encoder and decoder implementations"
for "android, chromeos, mac, and windows, as well as v4l2 and vaapi".
https://chromium.googlesource.com/chromium/src/+/HEAD/media/README.md ,
https://chromium.googlesource.com/chromium/src/+/HEAD/media/gpu/README.md

**The counter-example worth weighing:** *Servo* — a from-scratch Rust browser engine with the same
five-platform ambition kaya has — did **not** build four backends. servo-media defines a `Backend` trait and
"currently, the only functional backend is GStreamer", on every platform.
https://github.com/servo/media , https://servo.org/blog/2019/07/09/media-update-h1-2019/
A project of Servo's size, with Igalia's multimedia team on it, chose one cross-platform media library over
four native ones. That is the single most relevant precedent for kaya.

**Estimate for kaya.** Four decoder backends behind one trait, decode-only, no encode, no DRM, no seeking
subtleties beyond keyframe seek: **on the order of 8k–15k lines of Rust + unsafe FFI**, spread over four
platform-specific unsafe surfaces that kaya's existing five-lane matrix would have to grow legs for. And the
long tail is not the happy path — it is per-device MediaCodec colour formats, Windows machines with no HEVC
extension, VideoToolbox format-description construction from a raw stream, and every combination of
"which of the four is red today". Compare: the whole of kaya's current backend layer is four *UI* backends;
this adds a fifth axis of platform divergence to a project whose core discipline is uniform semantics.

---

#### B. FFMPEG LINKED INTO THE CORE

##### B6. Licensing, precisely

**FFmpeg's own legal page** (https://www.ffmpeg.org/legal.html) states it plainly:

> "FFmpeg is licensed under the GNU Lesser General Public License (LGPL) version 2.1 or later. However, FFmpeg
> incorporates several optional parts and optimizations that are covered by the GNU General Public License (GPL)
> version 2 or later. **If those parts get used the GPL applies to all of FFmpeg.**"

Its compliance checklist begins with "compile FFmpeg without `--enable-gpl` and without `--enable-nonfree`",
then: distribute FFmpeg's source with your binaries, **use dynamic linking**, credit FFmpeg on download pages
and in the about box, state LGPL 2.1 in the EULA, and state that you do not own FFmpeg's code.
`--enable-nonfree` produces a build that is **not redistributable at all** (it lets GPL-incompatible non-free
code, e.g. the Fraunhofer FDK AAC, be linked in).

On patents the same page is deliberately unhelpful, and this is worth quoting to Akhil verbatim because it is
FFmpeg's *own* position: "We do not know, we are not lawyers so we are not qualified to answer this", followed
by a warning that standards like H.264 and MPEG-4 carry patent notices and that commercial users should expect
"the owners of the patents will come after their licensing fees."

**What a STATIC link into a proprietary app requires — LGPL 2.1 §6, verbatim**
(https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt):

> "As an exception to the Sections above, you may also combine or link a 'work that uses the Library' with the
> Library to produce a work containing portions of the Library, and distribute that work under terms of your
> choice, **provided that the terms permit modification of the work for the customer's own use and reverse
> engineering for debugging such modifications.**"

and then you must do one of:

> **a)** "Accompany the work with the complete corresponding machine-readable source code for the Library
> including whatever changes were used in the work …; and, if the work is an executable linked with the Library,
> **with the complete machine-readable 'work that uses the Library', as object code and/or source code, so that
> the user can modify the Library and then relink to produce a modified executable containing the modified
> Library.**"
>
> **b)** "Use a suitable shared library mechanism for linking with the Library. A suitable mechanism is one that
> (1) uses at run time a copy of the library already present on the user's computer system, rather than copying
> library functions into the executable, and (2) will operate properly with a modified version of the library,
> if the user installs one …"

So: **dynamic link (6b) is the easy road; static link (6a) obliges you to ship your own application's object
files** (or source) plus a way to relink. That is a real, if unglamorous, deliverable — a tarball of `.o` files
and a link script — and it is what "provide object files" means in practice.

**What real apps do.** Overwhelmingly (b): ship `libavcodec.so`/`.dll`/`.dylib` beside the app and dlopen or
link dynamically. Firefox goes further and **dlopen's the system FFmpeg at runtime** rather than shipping one —
`FFmpegRuntimeLinker.cpp` plus eleven per-version shims
(https://api.github.com/repos/mozilla-firefox/firefox/contents/dom/media/platforms/ffmpeg) — which sidesteps
both the LGPL obligation and the patent exposure by never distributing a codec at all. The static-link +
object-files route (6a) is documented as legally workable but is described in practitioner discussions as
"highly impractical" on locked-down platforms; see the two camps ("provide object files" vs "provide source")
laid out at https://roadfiresoftware.com/2013/08/the-problem-with-using-lgpl-v2-1-code-in-an-ios-app/ and the
LWN thread https://lwn.net/Articles/526355/ (2012-11-22).

##### B7. The app-store question

**iOS / Apple.** This is where the LGPL story gets bad, and the reason is structural, not FFmpeg-specific.
- **iOS has no user-installable shared libraries**, so LGPL §6(b) is unavailable and you are forced onto §6(a):
  ship object files so the user can relink. But an App Store binary is code-signed and DRM'd; a user cannot
  install the relinked result on their own device without a developer account. The practitioner consensus is
  that you must offer the relinkable object files **outside** the App Store, and that even then the "operate
  properly with a modified version" spirit is not honoured.
  https://roadfiresoftware.com/2013/08/the-problem-with-using-lgpl-v2-1-code-in-an-ios-app/
- The LWN discussion reaches the sharper conclusion, quoting Bradley Kuhn after studying app-store terms:
  the stores' terms "neither permit LGPL-covered applications any more easily than GPL-covered ones", i.e.
  **LGPL buys you less on iOS than people assume.** https://lwn.net/Articles/526355/
- **The VLC history.** VLC for iOS was pulled from the App Store in January 2011 after developer Rémi
  Denis-Courmont filed a GPL infringement notice: the App Store's DRM and usage rules conflict with the GPL's
  requirement that recipients may freely copy and redistribute.
  https://www.fsf.org/blogs/licensing/vlc-enforcement
  VideoLAN then **relicensed the VLC *engine* (libVLC and libVLCcore) from GPLv2 to LGPLv2.1-or-later**,
  announced 2011-12-21 — "to match the evolution of the video industry and to spread the VLC engine as a
  multi-platform open-source multimedia engine and library." Note the press release's own FAQ was *not*
  confident this fixed the store problem: "Will this license change allow VLC to be available on the Apple
  stores? So far, we don't know if this will change anything."
  https://www.videolan.org/press/lgpl-libvlc.html
  VLC for iOS is on the App Store today — but as **GPLv2+/MPLv2 software published by VideoLAN itself**
  (https://apps.apple.com/us/app/vlc-media-player/id650377962 ,
  https://github.com/videolan/vlc-ios), i.e. the copyright holder distributing its own code. That is a
  permission *kaya does not have* for FFmpeg. The lesson to draw is the opposite of the popular one: VLC is on
  the store because VideoLAN owns VLC, not because LGPL solved anything.
- **Practical reading for kaya:** statically linking LGPL FFmpeg into an iOS app and shipping it through the
  App Store is what a large number of apps actually do, and it is *not* clean under §6(a) unless kaya also
  publishes relinkable object files. Dynamic linking on iOS is possible now (embedded `.framework` /
  `.xcframework` inside the app bundle) but does not satisfy 6(b)(1)'s "a copy of the library already present on
  the user's computer system"; it does arguably satisfy the *relink* spirit better than a static archive.

**Google Play.** Play's Developer Program Policy does not ban GPL/LGPL, and GPL apps are published there
routinely. The practical hole is the same as iOS's: an APK is signed, so a user cannot drop in a modified
`.so` and have the app run, which defeats §6(b)(2). See the write-up at https://xebia.com/blog/the-lgpl-on-android/
Shipping FFmpeg as a `.so` inside the APK is the normal industry practice (this is exactly what
ffmpeg-kit/mobile-ffmpeg do, and they are published on Maven Central under LGPL v3 / GPL v3 variants:
https://github.com/tanersener/mobile-ffmpeg/wiki/License-LGPL-v3.0).

**Microsoft Store.** The historical restriction people remember is the 2011 *Windows Phone* Marketplace
agreement banning GPLv3/AGPLv3/LGPLv3 (https://www.theregister.com/2011/02/17/microsoft_bans_opensource_windows_phone/).
The modern Microsoft Store's live controversy was different — a June 2022 policy (10.8.7) that would have
banned *selling* open-source software, which Microsoft reversed on 2022-07-19 after backlash:
https://www.theregister.com/2022/07/19/microsoft_store_policy/ ,
https://techcrunch.com/2022/07/19/microsoft-u-turns-on-policy-that-wouldve-banned-commercial-open-source-apps/
Windows is also the platform where LGPL §6(b) is genuinely easy: ship `avcodec-*.dll` next to the exe. Windows
is not the app-store problem; **iOS is, and Android is a milder version of it.**

##### B8. Binary size

I could not find a *published, measured* size table for "FFmpeg built with only H.264+AAC decode" per platform —
the ffmpeg-kit wiki page that people cite for this teaches the technique (`--disable-everything` then
`--enable-decoder=…`) but publishes **no numbers at all**
(https://github.com/arthenica/ffmpeg-kit/wiki/How-to-Decrease-Binary-Size). Rather than repeat a folk figure,
here are the real measurements I could anchor:

**Full build, shared libraries, Debian trixie** (https://packages.debian.org/trixie/libavcodec61 ,
/libavformat61 , /libavutil59) — this is the *upper* bound, a distro build with everything on:

| package | amd64 download / installed | arm64 download / installed |
|---|---|---|
| libavcodec61 | 5,684.8 kB / **16,613 kB** | 5,268.5 kB / **14,200 kB** |
| libavformat61 | 1,175.1 kB / 3,047 kB | 1,113.6 kB / 3,120 kB |
| libavutil59 | 415.0 kB / 1,252 kB | 382.8 kB / 1,091 kB |
| **core three, installed** | **~20.9 MB** | **~18.4 MB** |

**Prebuilt iOS xcframeworks** (kewlbear/FFmpeg-iOS release assets, measured from the GitHub API on 2026-09-02,
https://api.github.com/repos/kewlbear/FFmpeg-iOS/releases): `avcodec.zip` **22,066,489 bytes**,
`avformat.zip` 4,860,891, `avutil.zip` 1,551,814, `swscale.zip` 957,946, `swresample.zip` 197,441 — i.e. a
compressed multi-slice avcodec alone is ~22 MB. Again, everything-on.

**Minimal build, lower bound.** The best measured minimal figure I found is a whole *`ffmpeg` executable*
"less than 2.5 MB" from a `--disable-everything`-style build with `--enable-small`, RTMP/H.264 scope, at
https://gist.github.com/gyk/49dc80c58691a21a1c5f5e16926beaa6 — that includes the CLI tool, so the libraries are
smaller still. **A reasonable planning number for H.264+AAC decode only, per architecture, is 2–4 MB**, against
~15–20 MB for a full build, and this must be multiplied by architecture on every platform that ships fat
binaries (iOS device+simulator, Android's four ABIs, macOS universal).

For kaya's likely scope (H.264 + HEVC decode, MP4/MOV demux, AAC decode, no encoders, no filters, no protocols
beyond `file`), expect the low end of that band — but note that **HEVC's decoder is itself large**, and that
enabling the assembly optimisations (which you must, for a video editor) is where most of the bytes are.

##### B9. Hardware decode through FFmpeg — and the catch

FFmpeg's `-hwaccel` list, per the manual (https://ffmpeg.org/ffmpeg.html): `none`, `auto`, `vdpau`, `dxva2`,
`d3d11va`, `vaapi`, `qsv`, `videotoolbox`; `mediacodec`, `vulkan`, `d3d12va`, `cuda`/`nvdec` and `amf` appear
in the fuller manual (https://ffmpeg.org/ffmpeg-all.html) and in `libavutil/hwcontext.c`
(https://github.com/FFmpeg/FFmpeg/blob/master/libavutil/hwcontext.c). Mapped to kaya's five lanes:
macOS/iOS → `videotoolbox`, Android → `mediacodec`, Linux → `vaapi` (or `vdpau`, or `vulkan`),
Windows → `d3d11va`/`dxva2` (`d3d12va` on newer).

**The catch, in FFmpeg's own words:**

> "Note that most acceleration methods are intended for playback and **will not be faster than software decoding
> on modern CPUs**. Additionally, ffmpeg will usually need to **copy the decoded frames from the GPU memory into
> the system memory, resulting in further performance loss.**"
> — https://ffmpeg.org/ffmpeg.html, `-hwaccel` documentation

The mechanism behind that sentence is `AVHWFramesContext`: a hwaccel decoder hands you an `AVFrame` whose
`data[]` are opaque platform handles (a `CVPixelBuffer`, an `AHardwareBuffer`/`ANativeWindow` slot, a
`VASurfaceID`, an `ID3D11Texture2D`), living in a GPU frame pool. To get pixels you call
`av_hwframe_transfer_data()`, which is a device→host copy; `-hwaccel_output_format` lets you *keep* the frame on
the device instead, but only helps if the next stage can consume a device surface.
https://ffmpeg.org/doxygen/trunk/hwcontext_8c.html , https://www.ffmpeg.org/doxygen/3.4/hwcontext_8h.html

**Why this bites kaya specifically.** kaya's whole architecture is "kaya rasterizes, backends blit" — the core
owns CPU pixels and hands bytes down. A hardware-decoded frame is exactly the thing that architecture cannot
consume without a readback, and a readback per frame at 4K is the cost hardware decode was supposed to save.
So kaya gets one of two shapes, and should pick deliberately:
- **CPU frames everywhere** (software decode, or hwaccel + `av_hwframe_transfer_data`): fits kaya's canvas
  model exactly, costs CPU, and is honest about it.
- **Device surfaces handed to each backend**: fast, but reintroduces per-backend divergence *in the pixel
  path*, which is the one place kaya has so far kept uniform (check-canvas-blit's whole point).

##### B10. Rust bindings in 2026

**`ffmpeg-next`** (zmwangx/rust-ffmpeg) — **9.0.0, released 2026-08-05**, 6,766,861 downloads. Latest commits
2026-08-05 / 2026-07-21. Its README says the crate "is currently in maintenance mode, and aims to be compatible
with all of FFmpeg's versions from 3.4 (currently from 3.4 til 8.0)". Licensed **WTFPL**.
https://github.com/zmwangx/rust-ffmpeg , https://crates.io/api/v1/crates/ffmpeg-next ,
https://api.github.com/repos/zmwangx/rust-ffmpeg/commits
Its sys crate **`ffmpeg-sys-next` 9.0.0 (2026-08-05)**, 7,087,355 downloads,
https://github.com/zmwangx/rust-ffmpeg-sys — 74 cargo features. The build story is in those features:
- default: link against a **system** FFmpeg found by pkg-config (avcodec/avdevice/avfilter/avformat/swresample/
  swscale on by default);
- `static` — link statically;
- `build` — **vendored: download and compile FFmpeg from source** as part of the cargo build (requires `static`),
  with `build-pic`, `build-portable`, and per-library switches `build-lib-x264`, `build-lib-x265`,
  `build-lib-dav1d`, `build-lib-vpx`, `build-lib-opus`, …;
- **licence switches are explicit cargo features**: `build-license-gpl`, `build-license-nonfree`,
  `build-license-version3` — i.e. the LGPL/GPL/nonfree decision is a line in `Cargo.toml`, which is a *good*
  property for a project that has to keep it LGPL;
- hardware: `build-videotoolbox`, `build-mediacodec`, `build-vaapi`, `build-nvenc`, `build-nvidia`, `build-amf`,
  `build-drm`, `build-vulkan`.
  Feature list: https://docs.rs/crate/ffmpeg-sys-next/latest/features
For reference, current FFmpeg upstream is **9.0.1 "Lei" (2026-08-12)**, with 8.1.2, 8.0.3, 7.1.5 also
maintained — https://ffmpeg.org/download.html

**`rsmpeg`** (larksuite) — **0.18.0+ffmpeg.8.0, released 2025-08-24**, 168,571 downloads, MIT.
https://github.com/larksuite/rsmpeg , https://crates.io/api/v1/crates/rsmpeg
Links via `rusty_ffmpeg`, with `link_system_ffmpeg` / `link_vcpkg_ffmpeg` features and environment variables
(`FFMPEG_PKG_CONFIG_PATH`, `FFMPEG_LIBS_DIR`, `FFMPEG_INCLUDE_DIR`) for a hand-built FFmpeg — which is the
shape you want for cross-compiling, because you build FFmpeg for the target yourself and point the crate at it.
The version suffix in the crate version (`+ffmpeg.8.0`) is the whole maintenance story: **rsmpeg pins a
specific FFmpeg major**, where ffmpeg-next does compile-time version detection across a range. rsmpeg is a year
behind ffmpeg-next as of 2026-09 (no FFmpeg 9 release).

**Cross-compilation reality for iOS/Android.** Neither crate does it for you. The practical route both use is:
build FFmpeg for the target with an NDK/Xcode toolchain (or take a prebuilt), then point the sys crate at the
headers and libs. Prebuilt sets exist — https://github.com/kewlbear/FFmpeg-iOS (Swift package of xcframeworks),
https://github.com/arthenica/ffmpeg-kit (Android AAR + iOS xcframework; **note: ffmpeg-kit was retired by its
author in 2025 and its binaries pulled from the CDNs**), and Qt documents its own from-source recipe for both:
https://doc.qt.io/qt-6/qtmultimedia-building-ffmpeg-android-windows.html ,
https://doc.qt.io/qt-6/qtmultimedia-building-ffmpeg-ios.html
Expect this to be a real build-system project inside kaya's flake, not a cargo feature flip.

**`ffmpeg-sidecar`** (spawn the `ffmpeg` binary and parse its output) — **2.5.2, released 2026-05-30**,
1,747,381 downloads, https://github.com/nathanbabcock/ffmpeg-sidecar , https://crates.io/api/v1/crates/ffmpeg-sidecar
The crate wraps a standalone FFmpeg binary "in an intuitive Iterator interface" and can auto-download a build.
The tradeoff is different in kind, and mostly favourable on licensing: **an unmodified FFmpeg executable invoked
as a separate process is not linking**, so LGPL §6 does not attach to kaya at all — you are a user of a program,
not a distributor of a library, *provided you do not ship the binary*. Ship it and you are distributing FFmpeg
again (still LGPL-clean if unmodified and source-offered, but now inside your app bundle, which reopens the iOS
question). The engineering cost is: process-per-decode, pixel data over a pipe, no seek without re-spawn, and
**it is a non-starter on iOS and Android**, which do not let an app fork-exec an arbitrary binary. Real GUI apps
do ship FFmpeg as a subprocess on desktop — that is the classic Handbrake/Shotcut/Kdenlive-adjacent pattern and
what ffmpeg-sidecar's 1.7M downloads represent — but no five-platform GUI toolkit can rely on it.

**One more current-state fact for B10:** the standard prebuilt-FFmpeg-for-mobile project, **`ffmpeg-kit`, was
retired on 2026-07-02** ("Development of FFmpegKit continues with FFmpegKitNext, maintained by its original
author"); historical releases remain in the repo and community forks are on Maven Central / pub.dev / npm.
https://github.com/arthenica/ffmpeg-kit
If kaya depends on prebuilt mobile FFmpeg, this is the supply chain it depends on — one maintainer, retired
once already.

---

#### C. PURE-RUST / PATENT-FREE DECODERS

##### C11. rav1d (and dav1d-rs)

**rav1d** — the Rust port of dav1d, by ISRG's Prossimo. https://github.com/memorysafety/rav1d
- crates.io: **1.1.0, released 2025-05-07**, only 32,940 downloads, BSD-2-Clause.
  https://crates.io/api/v1/crates/rav1d — 1.1.0 "synchronizes rav1d code with the latest version of dav1d,
  v1.5.1" (https://www.memorysafety.org/initiative/av1/).
- Repository is alive but slow: 641 stars, most recent commits **2026-08-14** ("Harden apt setup",
  "obu: construct optional refidx with bool::then_some"). https://api.github.com/repos/memorysafety/rav1d/commits
- **Functional completeness is real.** Prossimo, 2025-05-14: "By September of 2024 rav1d was basically
  complete", it "passes all the same tests as the dav1d decoder it is based on", and "it's possible to build and
  run Chromium with it." https://www.memorysafety.org/blog/rav1d-perf-bounty/
- **Performance is the open item and has not closed.** The same post: rav1d is "currently about 5% slower than
  the C-based dav1d decoder (the exact amount differs a bit depending on the benchmark, input, and platform)",
  down from ~11% overhead earlier (https://www.memorysafety.org/blog/rav1d-performance-optimization/, 2024-09-10).
  A **$20,000 bounty** for parity was posted 2025-05-14 and **concluded on 2025-12-31**
  (https://www.memorysafety.org/rav1d-bounty-official-rules/) with no parity announcement on the initiative page.
- **Shape:** "librav1d is designed to be a drop-in replacement for libdav1d, so it primarily exposes a **C API**
  with the same usage as libdav1d's. A Rust API is mentioned as planned but not yet implemented." So even the
  pure-Rust AV1 decoder is consumed through a C ABI today.
- **Verdict:** production-*capable* for AV1 (Chromium builds and runs with it), ~5% slower than the C reference,
  pre-1.x cadence on crates.io. Fine as a component; not a reason to build a decode stack around it.

**dav1d-rs** (`dav1d` crate) — bindings to the C libdav1d. **0.11.1, released 2025-11-25**, 1,238,301 downloads,
https://github.com/rust-av/dav1d-rs , https://crates.io/api/v1/crates/dav1d
Uses `system-deps` to find a **system** libdav1d (overridable via `PKG_CONFIG_PATH` /
`SYSTEM_DEPS_DAV1D_*`), no vendoring; README says "The bindings require dav1d>=1.3.0 (Might not work for
>1.5.0)" — a narrow version window, i.e. it does not insulate you from the C library's release cadence.

##### C12. What a patent-free-only path leaves out

**H.264 (AVC).** Licensed through **Via LA** (the merged MPEG LA / Via Licensing pool).
https://www.via-la.com/licensing-programs/avc-h-264/ — an "AVC Product" explicitly includes "media player and
other personal computer software" and "mobile devices". The PC-software rate card:
- units 1–100,000 per year: **$0.00** (available to one legal entity in an affiliated group)
- units 100,001–5,000,000: **$0.20/unit**
- units 5,000,001+: **$0.10/unit**
- annual enterprise cap: **$9.75M** from 2017 onward.
So a small app is *below the threshold* and a large one is not. The threshold is a real answer for a project at
kaya's stage and a real liability at scale. Note also the 2025 reporting that Via LA has been raising AVC
streaming-side fees sharply (https://www.tomshardware.com/service-providers/streaming/h264-streaming-license-fees-jump-from-100000-to-4-5-million).

**HEVC (H.265).** Worse: **three** pools plus unpooled holders. Access Advance's HEVC Advance pool covers
"over 27,000 patents"; Via LA runs a separate HEVC program (https://www.via-la.com/licensing-programs/hevc-vvc/);
Access Advance announced on **2025-07-21** that from **2026-01-01** HEVC rates realign to the VVC rate structure
with an approved **25% rate increase for new licensees**, current rates lockable through 2030 only if you signed
by 2025-12-31. https://accessadvance.com/2025/07/21/access-advance-announces-hevc-advance-and-vvc-advance-pricing-through-2030/
There is no equivalent to Via LA's free-first-100k tier stated publicly for a software decoder.

**FFmpeg's own position**, again, because it is the most honest sentence anyone writes on this: "We do not know,
we are not lawyers so we are not qualified to answer this" — and the warning that patent holders "will come
after their licensing fees." https://www.ffmpeg.org/legal.html

**The OpenH264 (Cisco) loophole — how it actually works, and why it does not help kaya.**
Cisco's binary licence text (https://www.openh264.org/BINARY_LICENSE.txt) grants Cisco's own AVC/H.264 Patent
Portfolio Licence from MPEG LA at no cost to you **only if**:
1. "the Cisco-provided binary is **separately downloaded to an end user's device, and not integrated into or
   combined with third party software prior to being downloaded** to the end user's device"; and
2. "the end user must have the ability to control (e.g., to enable, disable, or re-enable) the use of the
   Cisco-provided binary"; plus attribution ("OpenH264 Video Codec provided by Cisco Systems, Inc.") reproduced
   in the EULA.
Cisco's FAQ (https://www.openh264.org/faq.html) confirms the split: **"Cisco is only covering the licensing fees
for its own binary module"** — build from source and "you must pay all applicable license fees" yourself. The
FAQ also notes the mechanism works on Linux/Windows/macOS/Android but **not iOS**, because Apple's distribution
rules do not permit downloading an executable module at install time.

Consequences for kaya:
- The **`openh264` Rust crate's default `source` feature compiles Cisco's C from source via `cc`** — which is
  precisely the case Cisco does *not* cover. Its `libloading` feature is the one that matches the loophole
  (load Cisco's own prebuilt at runtime), and it requires you to fetch that binary at run time.
  https://github.com/ralfbiedert/openh264-rs (crate: 0.9.8, released **2026-08-08**, 890,766 downloads,
  https://crates.io/api/v1/crates/openh264)
- Even done correctly, the loophole is a **runtime download of a separate module the user can disable** — a
  shape a GUI toolkit cannot impose on its embedders, and one that is unavailable on iOS entirely.
- **The crate's own README is worth quoting to Akhil**: "Below a thin Rust layer we rely on a *very complex* C
  library … this project will give you *no* additional safety guarantees as far as video handling is concerned."

##### C13. Pure-Rust decoders that actually exist (honest maturity)

| codec | crate | state (observed 2026-09-02) |
|---|---|---|
| **AV1** | `rav1d` | **The only credible one.** Complete, passes dav1d's test suite, runs in Chromium, ~5% slower. crates.io 1.1.0 (2025-05-07); commits to 2026-08-14. https://crates.io/api/v1/crates/rav1d |
| **AV1 (C)** | `dav1d` bindings | Mature C library, thin Rust bindings, 0.11.1 (2025-11-25). Not pure Rust. |
| **VP8/VP9** | — | **Nothing credible.** The only Rust route is FFI to libvpx: `vpx-sys` 0.1.1, **last released 2021-03-01**, 4,768 lifetime downloads. https://crates.io/api/v1/crates/vpx-sys — effectively abandoned. |
| **H.264** | `openh264` | FFI to Cisco's C. 0.9.8 (2026-08-08), 890k downloads. Mature *as a binding*; patent-encumbered as above. |
| **H.264 (pure Rust)** | `rusty_h264` | **New and unproven.** First published **2026-06-27**, at 0.14.0 by **2026-09-03** — fifteen releases in ten weeks. 16,915 downloads, **6 GitHub stars, 1 fork.** README claims "35 of openh264's conformance streams decode byte-for-byte identical", `#![forbid(unsafe_code)]` in the core, and decode throughput of **150 Mpx/s baseline / 107 Mpx/s CABAC vs ffmpeg's 314 / 289** — i.e. by its own numbers **roughly 2–3× slower than FFmpeg**. https://github.com/remade-with-rust/rusty_h264 , https://crates.io/api/v1/crates/rusty_h264 |
| **H.264 (pure Rust)** | `rust_h264` | Also new: 0.1.0 on **2026-04-05**, 0.4.0 on **2026-04-20**, then nothing. 25,052 downloads. https://crates.io/api/v1/crates/rust_h264 |
| **H.264 (pure Rust)** | `oxideav-h264` | Currently an **empty crate** under "spec-driven rewrite". https://github.com/OxideAV/oxideav-h264 |
| **HEVC (pure Rust)** | — | Nothing. |

**Honest read:** the pure-Rust story is *AV1 only*. The two 2026 pure-Rust H.264 decoders are months old, single-
digit-star, single-maintainer projects with rapid pre-1.0 churn; one publishes benchmarks showing itself 2–3×
slower than FFmpeg, and neither has a track record on malformed input — which for a decoder is the entire risk
surface. **And writing a pure-Rust decoder does not touch the patent question at all**: patents cover the
algorithm, not the implementation language. A clean-room Rust H.264 decoder has exactly the same Via LA exposure
as FFmpeg's, minus FFmpeg's twenty years of fuzzing.

##### C14. What the user's own footage actually is

This is the decisive constraint for a video editor and it argues against every patent-free-only path.

**iPhone.** Since iOS 11 the default capture format is **HEVC** (the Camera → Formats → "High Efficiency"
setting); "Most Compatible" switches to H.264/JPEG. Apple: HEIF/HEVC capture "is recommended"; the Most
Compatible option exists to "use JPEG or H.264 format" for "more broadly compatible" output. HEVC capture is
supported on iPhone 7 and later, iPad (6th gen) and later, and Apple Vision Pro; on macOS Tahoe 26+, **screen
recordings in HDR are captured as HEVC** too. https://support.apple.com/en-us/116944
Higher tiers add **ProRes** (iPhone 13 Pro and later), which is another decoder entirely:
https://support.apple.com/en-us/109041

**Android.** Android *requires* device support for decoding **H.264 AVC Baseline (Android 3.0+), HEVC
(Android 5.0+), VP8, VP9 (4.4+)**, and **AV1 decode+encode became mandatory in Android 14**.
https://developer.android.com/guide/topics/media/media-formats
Capture default is OEM-dependent: HEVC became the default on many OEMs from Android 12
(https://www.xda-developers.com/oems-change-default-video-capture-format-android-12-hevc/), and Samsung,
Pixel and OnePlus all expose an HEVC/H.264 toggle in the camera. Samsung's Galaxy S26 Ultra adds a *third*
format, **APV**, published as **RFC 9924** in February 2026 — a new professional capture codec kaya would not
decode at all. https://smartphones.gadgethacks.com/news/samsung-galaxy-s26-ultra-apv-video-codec-explained-for-editors/

**Conclusion:** the practical floor for a video editor is **H.264 and HEVC in MP4/MOV**, and both are
patent-encumbered. An AV1-only, patent-free-only path **cannot open the user's own camera roll** — not on
iPhone (HEVC by default), not on a modern Android flagship (HEVC by default), not a QuickTime screen recording.
AV1 is what the *web* delivers, not what the *camera* writes.

---

#### SYNTHESIS FOR THE RULING

##### The three routes, side by side

| | four platform decoders behind one trait | FFmpeg linked into the core | pure-Rust / patent-free only |
|---|---|---|---|
| **codec coverage** | whatever the OS has. H.264 everywhere; HEVC everywhere **except Windows without the Store extension**; AV1 mandatory on Android 14+, needs an extension on Windows, fine on Apple hardware | everything, decided at configure time | **AV1 only.** Cannot open an iPhone or a modern Android camera roll |
| **engineering** | ~8k–15k lines of unsafe FFI across 4 platform surfaces; Firefox's analogue is 150 KB (Apple) / 561 KB (Windows) / 93 KB (Android) of C++ | one dependency + a real cross-compile build project for iOS/Android | one crate, ~5% slower than dav1d |
| **licensing** | **clean.** No codec distributed; the OS's licence covers it | LGPL 2.1: dynamic link is easy on Windows/Linux/macOS; **static link on iOS obliges §6(a) object files** | BSD-2 clean, patents untouched |
| **patents** | **the OS holder pays.** This is the single biggest argument for this route | kaya distributes an H.264/HEVC decoder → Via LA / Access Advance exposure (free below 100k units/yr for AVC PC software) | AV1 is royalty-free by design |
| **binary size** | ~0 | ~2–4 MB minimal, ~15–20 MB full, **per architecture** | ~1–2 MB for rav1d |
| **uniformity (kaya's core invariant)** | four divergent surfaces, four divergent failure modes, four sets of lane legs | **one behaviour on five platforms** | one behaviour, one codec |
| **precedent** | Chromium, Firefox — both browser-scale projects with media teams | most desktop editors; Firefox *also* has an FFmpeg PDM and dlopen's the system one | nobody ships a patent-free-only editor |

##### The finding I would put in front of Akhil first

**Servo — a from-scratch Rust engine with the same five-platform ambition — did not build four decoder backends.**
servo-media defines a `Backend` trait and, with Igalia's multimedia team on the project,
"currently, the only functional backend is GStreamer" on every platform
(https://github.com/servo/media , https://servo.org/blog/2019/07/09/media-update-h1-2019/). Meanwhile Firefox,
which *did* build four, needed 561 KB of C++ for the Windows one alone and still added a second Windows backend
beside the first.

**The second finding:** "use GStreamer on Linux instead of FFmpeg" does not escape FFmpeg. GStreamer's software
H.264 decoder `avdec_h264` is documented by GStreamer as "libav h264 decoder", shipped in the "GStreamer FFMPEG
Plug-ins" package. https://gstreamer.freedesktop.org/documentation/libav/avdec_h264.html

**The third finding, which cuts the other way and is the strongest argument for owning decode:** on Windows the
platform route **cannot open an iPhone's default recording**. Windows ships no HEVC decoder; it needs a Microsoft
Store extension the user must obtain, and kaya cannot make them. Combine that with Apple's HEVC-by-default
capture (https://support.apple.com/en-us/116944) and the platform-decoder route has a hole exactly where a video
editor's most common input lands.

**The fourth finding:** kaya's canvas architecture ("kaya rasterizes, backends blit") wants **CPU frames**, and
every hardware decode route on every platform wants to give you a **GPU surface**. FFmpeg says so itself:
"ffmpeg will usually need to copy the decoded frames from the GPU memory into the system memory, resulting in
further performance loss." (https://ffmpeg.org/ffmpeg.html) So kaya pays a readback whichever route it takes —
unless it breaks its own blit uniformity to hand device surfaces to four backends, which is the thing
`tools/check-canvas-blit.py` exists to prevent.

##### What I could NOT confirm (stated rather than guessed)

1. **No published, measured size table** for a minimal `--disable-everything --enable-decoder=h264 …` FFmpeg
   build per platform. The ffmpeg-kit wiki page everyone cites has no numbers. My 2–4 MB band is bracketed by a
   measured "<2.5 MB whole ffmpeg executable" minimal build (https://gist.github.com/gyk/49dc80c58691a21a1c5f5e16926beaa6)
   and Debian's everything-on libavcodec61 at 16.6 MB installed. **This is worth measuring in kaya's own flake
   rather than inheriting from this document.**
2. **The current Microsoft Store policy text on GPLv3/LGPLv3.** The commonly cited ban is from the 2011
   *Windows Phone* Marketplace agreement; the 2022 controversy was about *selling* open source (policy 10.8.7)
   and Microsoft reversed it on 2022-07-19. I did not find a live clause in today's Store Policies naming
   LGPLv3. FFmpeg is LGPL **2.1**, so this is probably moot either way.
3. **Whether `ffmpeg-next` 9.0.0 formally supports FFmpeg 9.** Its README still says "from 3.4 til 8.0" while
   the crate version and its sys crate both jumped to 9.0.0 on 2026-08-05, the week before FFmpeg 9.0.1 shipped.
   The README is stale; verify against the wiki/build before relying on a range.
4. **Whether the rav1d $20,000 parity bounty was claimed.** The contest "concluded on December 31, 2025"
   (https://www.memorysafety.org/rav1d-bounty-official-rules/) and the initiative page carries no outcome; the
   last performance figure on the record is still ~5% slower than dav1d.
5. **Per-frame readback costs** — I found the mechanism (`av_hwframe_transfer_data`, AImageReader vs ByteBuffer)
   documented everywhere and a *number* nowhere. Also worth measuring rather than citing.

##### Rust crate maintenance, one line each (all observed 2026-09-02)

- `ffmpeg-next` **9.0.0 / 2026-08-05**, 6.77M downloads, WTFPL, README says "maintenance mode" — healthy but not ambitious. https://crates.io/api/v1/crates/ffmpeg-next
- `ffmpeg-sys-next` **9.0.0 / 2026-08-05**, 7.09M downloads, 74 features incl. vendored `build` and explicit `build-license-gpl`/`-nonfree`. https://crates.io/api/v1/crates/ffmpeg-sys-next
- `rsmpeg` **0.18.0+ffmpeg.8.0 / 2025-08-24**, 169k downloads, MIT, pinned to one FFmpeg major, a year behind. https://crates.io/api/v1/crates/rsmpeg
- `ffmpeg-sidecar` **2.5.2 / 2026-05-30**, 1.75M downloads — subprocess, desktop only. https://crates.io/api/v1/crates/ffmpeg-sidecar
- `gstreamer` **0.25.3 / 2026-06-29**, 10.0M downloads — the healthiest binding here. https://crates.io/api/v1/crates/gstreamer
- `windows` **0.62.2 / 2025-10-06**, 312M downloads — Media Foundation fully covered. https://crates.io/api/v1/crates/windows
- `objc2-video-toolbox` **0.3.2 / 2025-10-04** (50k), `objc2-core-video` **0.3.2** (8.3M), `objc2-av-foundation` **0.3.2** (1.3M) — one generated family, one maintainer (madsmtm), all pre-1.0. https://github.com/madsmtm/objc2
- `ndk` **0.9.0 / 2024-04-26**, 50.9M downloads — has `media` and `hardware_buffer` modules but **no release in over two years**; expect to drive `ndk-sys`. https://crates.io/api/v1/crates/ndk
- `cros-codecs` **0.0.6 / 2025-06-18**, 2.0M downloads — Linux/VAAPI + bitstream parsers, still 0.0.x after 3 years. https://crates.io/api/v1/crates/cros-codecs
- `rav1d` **1.1.0 / 2025-05-07** (commits to 2026-08-14), 33k downloads — AV1 only, ~5% slower than dav1d, exposes a **C** API. https://crates.io/api/v1/crates/rav1d
- `dav1d` **0.11.1 / 2025-11-25**, 1.24M downloads — needs a system libdav1d in a narrow version window. https://crates.io/api/v1/crates/dav1d
- `openh264` **0.9.8 / 2026-08-08**, 891k downloads — default feature compiles Cisco's C **from source**, which is the case Cisco's royalty coverage explicitly excludes. https://crates.io/api/v1/crates/openh264
- `rusty_h264` **0.14.0 / 2026-09-03**, first published 2026-06-27, 6 stars — too new to bet on. https://crates.io/api/v1/crates/rusty_h264
- `vpx-sys` **0.1.1 / 2021-03-01**, 4,768 downloads — abandoned; there is no VP8/VP9 Rust story. https://crates.io/api/v1/crates/vpx-sys

END OF NOTES.

### §2.2 The frame path and the texture-registry pattern
Research slice: the cost of CPU frame delivery, and the texture-registry pattern
frameworks use instead. Every claim carries a URL.


---

##### A1. The arithmetic (computed here, not cited — plain multiplication)

One 1920x1080 frame:

| format | bytes/pixel | bytes/frame | MiB/frame |
|---|---|---|---|
| RGBA8888 / BGRA8888 | 4 | 8,294,400 | 7.91 |
| NV12 / YUV420 (8-bit, 4:2:0) | 1.5 | 3,110,400 | 2.97 |

YUV 4:2:0 is 1.5 B/px because chroma is subsampled 2x2: one Y byte per pixel plus
one U and one V byte per 2x2 block = 1 + 0.5 = 1.5. So **converting to RGBA is a
2.67x data expansion before any copy happens at all.**

ONE full-frame touch (read OR write, not both) at 1080p:

| fps | RGBA one copy | NV12 one copy |
|---|---|---|
| 24 | 199 MB/s | 75 MB/s |
| 30 | 249 MB/s | 93 MB/s |
| 60 | 498 MB/s | 187 MB/s |

4K (3840x2160) RGBA is 33.2 MB/frame -> 995 MB/s at 30fps, 1.99 GB/s at 60fps for
ONE copy.

###### Counting the copies a naive owned-rendering path actually makes

A "kaya rasterizes, backends blit" video path at 1080p60. Each numbered step is a
full-frame *read plus* a full-frame *write* through memory — memory-bandwidth
traffic is the sum of both sides:

| # | step | reads | writes | traffic @60fps |
|---|---|---|---|---|
| 1 | decoder writes NV12 output | — | 3.11 MB | 187 MB/s |
| 2 | YUV->RGBA color convert | 3.11 MB (NV12) | 8.29 MB (RGBA) | 685 MB/s |
| 3 | composite/blit RGBA frame into the canvas raster (tiny-skia `draw_pixmap`/`draw_image`) | 8.29 MB | 8.29 MB | 995 MB/s |
| 4 | hand the canvas pixmap to the backend (a `Vec<u8>` -> platform bitmap copy, unless the backend can borrow) | 8.29 MB | 8.29 MB | 995 MB/s |
| 5 | upload the bitmap to a GPU texture (CPU read + PCIe/UMA write) | 8.29 MB | 8.29 MB | 995 MB/s |
| 6 | GPU compositor samples the texture and writes the framebuffer | 8.29 MB | 8.29 MB | 995 MB/s |

Sum of steps 1-6 at 1080p60: **~4.85 GB/s of memory traffic** for a single video
rectangle, before the UI around it is drawn even once. (Steps 3 and 4 collapse into
one if the backend can blit straight out of kaya's pixmap with no staging copy;
step 2 disappears entirely if the frame is delivered as a GPU texture and converted
in a shader.) The same accounting at 1080p30 is ~2.4 GB/s; at 4K60 it is ~19 GB/s,
which is more than the entire bandwidth of most phone SoCs (see A2).

The minimum a texture path spends, by contrast, is steps 1 and 6 only — the decoder
writes NV12 into a buffer the GPU can sample directly, and the compositor reads it
(with the YUV->RGB conversion folded into the sampler, which is free — it is fixed
function on every modern GPU's sampler or a handful of ALU ops):
**~370 MB/s at 1080p60, a 13x reduction.**

---
##### A2. How much of the machine's bandwidth is that? (published figures)

**Phone SoC — Snapdragon 8 Elite Gen 5.** Qualcomm's own product brief states the
memory spec as: "Support for LP-DDR5x memory, up to 5300MHz / Memory Density: Up to
24GB" — https://www.qualcomm.com/content/dam/qcomm-martech/dm-assets/documents/Snapdragon-8-Elite-Gen-5-product-brief.pdf
(extracted from the PDF's Memory section). Qualcomm does not print a GB/s figure;
the arithmetic from the spec is 5300 MHz DDR = 10,600 MT/s across a 64-bit bus
(4 x 16-bit channels) = **84.8 GB/s**, which is the figure third parties quote:
https://www.notebookcheck.net/Qualcomm-Snapdragon-8-Elite-Gen-5-for-Galaxy-Processor-Benchmarks-and-Specs.1271123.0.html

**Laptop — Apple silicon (Apple's own newsroom, exact sentences).**
- "M4 supports up to 32GB of unified memory and has higher memory bandwidth of 120GB/s."
- "M4 Pro supports up to 64GB of fast unified memory and 273GB/s of memory bandwidth..."
- "M4 Max supports up to 128GB of fast unified memory and up to 546GB/s of memory bandwidth..."
https://www.apple.com/newsroom/2024/10/apple-introduces-m4-pro-and-m4-max/

###### The honest ratio

| machine | peak BW | naive CPU path @1080p60 (4.85 GB/s) | texture path (0.37 GB/s) |
|---|---|---|---|
| Snapdragon 8 Elite Gen 5 phone | ~84.8 GB/s | **5.7%** | 0.4% |
| MacBook Air / base M4 | 120 GB/s | **4.0%** | 0.3% |
| M4 Max | 546 GB/s | 0.9% | 0.07% |

Two caveats that make the percentage understate the problem:

1. **Peak is not achievable.** Real STREAM-style efficiency on LPDDR is well under
   100% of peak, and on a phone the GPU, the display controller, the ISP and the
   modem are all contending for the same LPDDR. A 6% peak-bandwidth figure is a
   larger fraction of *available* bandwidth.
2. **Bandwidth is power.** On a phone, DRAM traffic is one of the larger energy
   line items; a video path that moves 13x more bytes than it needs to shows up as
   battery and as thermal throttling long before it shows up as dropped frames.
3. **4K is where it stops being arguable.** The same naive path at 4K60 is
   ~19.4 GB/s — 23% of a flagship phone's entire theoretical memory bandwidth, for
   one video rectangle. At that point the CPU path is not a tradeoff, it is a wall.

---

##### A3. YUV->RGB on the CPU: measured cost, and why frameworks use a shader

**libyuv** is Chromium's SIMD YUV library: "libyuv is an open source project that
includes YUV scaling and conversion functionality", optimized for "SSSE3 and AVX2"
on x86/x64 and "Neon, SVE2, and SME" on Arm (also MSA on MIPS, RVV on RISC-V) —
https://chromium.googlesource.com/libyuv/libyuv/+/HEAD/README.md

**Measured conversion cost (Mozilla bug 1256475, "Use libyuv for non scaling YUV
color conversion", on an Intel Core i7-6700K at 4GHz):**
https://bugzilla.mozilla.org/show_bug.cgi?id=1256475

4K frame, I420 -> ARGB:
| implementation | time per frame |
|---|---|
| libyuv `I420ToARGB` AVX2 | **8 ms** |
| libyuv `I420ToARGB` SSSE3 | 9 ms |
| libyuv `I420ToARGB` **C fallback** | **54 ms** |
| Gecko's old `ConvertYCbCrToRGB32` MMX/SSE | 12 ms |
| Gecko's old `ConvertYCbCrToRGB32` C fallback | 120 ms |

1080p frame in the same bug: ~8 ms before the patch, ~5 ms after (path
`I422ToARGBRow_AVX2`).

What those numbers mean for kaya:

- **SIMD is not optional, it is the whole thing.** The C fallback is **6.75x** slower
  than AVX2 at 4K (54ms vs 8ms). 54ms/frame is 3 frames' worth of budget at 60fps
  for the *color conversion alone*. The bug itself records the regression risk in
  the other direction: "if chip does not support ssse3, libyuv::I420ToARGB()
  fallback to c and it degrade performance compared to ConvertYCbCrToRGB32 mmx/sse."
- Even the *good* number is expensive. 8 ms of a 4 GHz desktop core to convert one
  4K frame; a 1080p frame is ~1/4 the pixels so ~2 ms of a fast desktop core per
  frame, i.e. **~12% of one core at 60fps just to change the pixel format**, before
  compositing. On a phone's little core that multiplies.
- On the GPU the same conversion is *free*: it is either fixed-function in the
  sampler (external OES textures on Android, `CVMetalTextureCache` planar textures
  on Apple) or three multiply-adds in a fragment shader executed as part of a
  sample the compositor was going to do anyway. That is the reason every framework
  in section B pushes it there.

---

##### A4. What tiny-skia is, and is not

From the README — https://github.com/linebender/tiny-skia/blob/main/README.md :

- "tiny-skia is a tiny [Skia](https://skia.org/) subset ported to Rust"; the goal is
  "an absolute minimal, **CPU only**, 2D rendering library."
- Supported: "filling and stroking a shape with a solid color, gradient or pattern;
  stroke dashing; clipping; images blending; PNG load/save." Main missing feature is
  text rendering.
- **Explicitly NOT supported: GPU rendering, PDF generation, and non-RGBA8888 images.**
  That last one is decisive here: tiny-skia has no notion of a YUV/NV12 surface, no
  planar image type, and no video surface of any kind. Every video frame must be
  converted to RGBA8888 *before* tiny-skia can touch it.
- SIMD: yes. x86 gets "decent performance ... by default"; AVX needs
  `RUSTFLAGS="-Ctarget-cpu=haswell"`; "We support ARM AArch64 NEON as well and there
  is no need to pass any additional flags."
- Speed relative to Skia (README's own claim): "tiny-skia is 20-100% slower than
  Skia on x86-64 and about 100-300% slower on ARM", while being faster than cairo
  and raqote in many cases, and adding ~200 KiB to the binary vs Skia's 3-8 MiB.
  Benchmark harness: https://github.com/linebender/tiny-skia/blob/main/benches/README.md

###### What would a per-frame 1080p `draw_pixmap` cost?

**No published benchmark of tiny-skia at 1080p image blit exists that I could find** —
tiny-skia's benches are path/gradient/stroke microbenchmarks, not full-frame image
composition, and nobody has published a video-rate number. So this has to be reasoned
from bandwidth rather than quoted, and it should be stated that way rather than
inventing a figure.

The floor is memory traffic: a `SrcOver` blend of a 1080p RGBA pixmap onto a 1080p
RGBA pixmap reads 8.29 MB of source, reads 8.29 MB of destination and writes 8.29 MB
of destination = ~25 MB of traffic per frame, 1.5 GB/s at 60fps. If the source is
opaque and the blend mode is `Source` (which a video frame is, and which tiny-skia
does have), the read of the destination goes away: ~16.6 MB/frame, ~1 GB/s at 60fps.
Streaming 1 GB/s through a single core is achievable on a desktop and marginal on a
phone's efficiency core, so the *blit itself* is not automatically fatal — **the
problem is that it is one of six such passes**, and the only one of the six a
texture path does not eliminate.

The other structural cost is that tiny-skia has no scaler tuned for this: any
non-1:1 video scaling (which is the normal case — a 1080p frame in a 640pt view)
goes through a general pattern/transform path per frame, and the README's own
"100-300% slower on ARM" than Skia applies to exactly that code.

---
##### B5. Flutter's texture registry — the canonical form of the pattern

Flutter is the closest architectural analogue to kaya's "we own the pixels" stance,
and it is exactly where Flutter makes an exception.

**The `Texture` widget** (https://api.flutter.dev/flutter/widgets/Texture-class.html)
— verbatim:

> "Backend textures are images that can be applied (mapped) to an area of the Flutter
> view. They are created, managed, and updated using a platform-specific texture
> registry."

> "A texture widget refers to its backend texture using an integer ID. Texture IDs are
> obtained from the texture registry and are scoped to the Flutter view."

> "**Texture widgets are repainted autonomously as dictated by the backend (e.g. on
> arrival of a video frame). Such repainting generally does not involve executing Dart
> code.**"

That last sentence is the whole design in one line: **the pixels never enter the
framework's language runtime, and a new frame does not go through the framework's
build/layout/paint cycle at all.** Dart declares a rectangle with an integer id; the
engine's Skia/Impeller scene composites the platform texture into that rectangle on
the raster thread. Flutter's per-frame cost for video is the compositor sampling a
texture — the same cost as any other layer.

Related APIs: `TextureLayer` (https://api.flutter.dev/flutter/rendering/TextureLayer-class.html),
`TextureBox` (https://api.flutter.dev/flutter/rendering/TextureBox-class.html). The
widget carries `filterQuality` (default `FilterQuality.low`) and a `freeze` flag —
both are compositor-side sampling knobs, not per-frame CPU work.

**Android: `SurfaceProducer` replaced `SurfaceTextureEntry` (Flutter 3.22 landed,
3.24 stable).** https://docs.flutter.dev/release/breaking-changes/android-surface-plugins

> "For Impeller, use of this API is recommended."

The reason given is exactly the GPU-API one: Android's `HardwareBuffer` (API 29+) is
"backend-agnostic" and coincides with Flutter's move to the Vulkan renderer, whereas
"the old `SurfaceTexture` API relied on OpenGLES and was incompatible with Vulkan."
The plugin's whole job becomes:

```java
TextureRegistry.SurfaceProducer producer = textureRegistry.createSurfaceProducer();
Surface surface = producer.getSurface();   // hand this to MediaCodec / ExoPlayer
```

i.e. **the decoder writes directly into a buffer the compositor can sample. There is
no frame data path through the framework at all.**

**iOS: the `FlutterTexture` protocol returns a `CVPixelBufferRef`.** The engine calls
`copyPixelBuffer` when it wants a frame; the plugin calls `textureFrameAvailable` to
say one exists. Flutter's own tracking issue for redesigning this
(https://github.com/flutter/flutter/issues/159162) documents the pull model and its
races: "There is race between `textureFrameAvailable` and `copyPixelBuffer` in a sense
that call to `textureFrameAvailable` may or may not have any effect depending on
whether engine already cleared that flag or not." Despite the name, `copyPixelBuffer`
returns a *retained reference* to an IOSurface-backed buffer, not a byte copy — the
engine wraps it as a Metal texture (`FlutterDarwinExternalTextureMetal.mm`).

Worth noting for kaya: **even Flutter, which owns a complete GPU scene graph, treats
this as a hard boundary with its own lifecycle problems.** It is not free; it is just
enormously cheaper than moving bytes.

---

##### B6. The per-platform primitives, precisely

###### APPLE (macOS + iOS)

- **`CVPixelBuffer` backed by `IOSurface`.** Camera and decoder output is IOSurface-backed
  by construction; an IOSurface is a shareable, GPU-addressable buffer.
  Apple's Q&A on creating them: https://developer.apple.com/library/ios/qa/qa1781/_index.html
- **`CVMetalTextureCacheCreateTextureFromImage`** — "Creates a Core Video Metal texture
  buffer from an existing image buffer."
  https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)
  This is the zero-copy step: no pixels move, the Metal texture aliases the IOSurface.
  Apple's own note in the docs: the function "increments the use count of the image
  buffer, but not the IOSurface buffer. The Core Video Metal texture owns this IOSurface
  buffer" — i.e. it is explicitly an aliasing, not a copying, API. (The GLES-era twin is
  `CVOpenGLESTextureCache`.)
- **`AVPlayerItemVideoOutput`** — pulls frames from a running `AVPlayer` as
  CVPixelBuffers; `copyPixelBufferForItemTime:` "is typically called in response to a
  CVDisplayLink callback or CADisplayLink delegate invocation and if
  hasNewPixelBufferForItemTime also returns YES."
  https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput
- **`AVSampleBufferDisplayLayer`** — "An object that displays compressed or uncompressed
  video frames." A `CALayer` subclass; you enqueue `CMSampleBuffer`s through
  `sampleBufferRenderer` (an `AVSampleBufferVideoRenderer` conforming to
  `AVQueuedSampleBufferRendering`). iOS 8+/macOS 10.8+/visionOS 1.0+.
  https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer
  **This is the one that matters for a framework that does NOT own a GPU scene**: it is a
  Core Animation layer, so it composites with the rest of the native view tree for free,
  and it accepts frames you decoded yourself.
- Apple DTS, asked directly whether to use `CAMetalLayer` or `AVSampleBufferDisplayLayer`
  for video (https://developer.apple.com/forums/thread/756206):
  > "AVSampleBufferDisplayLayer will leverage the GPU and like Core Image may optimize
  > behavior dynamically based on the underlying hardware and operating system."
  > "Metal is a low-level framework dedicated to the GPU so you have finer grain control
  > over your rendering pipeline. This comes at the cost of high-level features offered
  > by AVFoundation and WebRTC."
  > "Overall AVSampleBufferDisplayLayer is probably better suited for your needs in this
  > case and is expected to perform well."

###### ANDROID

- **`SurfaceTexture`** — captures frames into a `GL_TEXTURE_EXTERNAL_OES` texture.
  https://developer.android.com/reference/android/graphics/SurfaceTexture
- **`AHardwareBuffer`** + `EGL_ANDROID_get_native_client_buffer` — the Vulkan-era
  replacement; a shareable cross-process GPU buffer.
  https://developer.android.com/ndk/reference/group/a-hardware-buffer
- **Compose (1.7+): `AndroidExternalSurface` and `AndroidEmbeddedExternalSurface`.**
  This is the exact case kaya's Compose backend is in, and Google states the cost
  difference explicitly. From the kdoc
  (https://composables.com/foundation/androidexternalsurface):
  > `AndroidExternalSurface` "uses a separate window layer, graphics composition is
  > handled by the system compositor which can bypass the GPU and provide better
  > performance and power usage characteristics."
  Z-order is `Behind` (default), `MediaOverlay`, or `OnTop`; there is an `isSecure` flag
  for DRM. Signature:
  ```kotlin
  @Composable fun AndroidExternalSurface(
      modifier: Modifier = Modifier, isOpaque: Boolean = true,
      surfaceSize: IntSize = IntSize.Zero,
      zOrder: AndroidExternalSurfaceZOrder = AndroidExternalSurfaceZOrder.Behind,
      isSecure: Boolean = false, onInit: AndroidExternalSurfaceScope.() -> Unit)
  ```
  `AndroidEmbeddedExternalSurface` instead "positions its surface as a regular element
  inside the composable hierarchy... graphics composition is handled like any other UI
  widget using the GPU, which can lead to **increased power and memory bandwidth usage**"
  — and is what you use when the video must be "sandwiched between two other widgets, or
  if it must participate in visual effects."
  Google's stated rule: "**It is recommended to use AndroidExternalSurface over
  AndroidEmbeddedExternalSurface whenever possible.**"
  https://composables.com/docs/androidx.compose.foundation/foundation/composables/AndroidEmbeddedExternalSurface
- Android's media docs put the same rule in SurfaceView/TextureView terms
  (https://developer.android.com/media/media3/ui/surface):
  > "SurfaceView has a number of benefits over TextureView for video playback:
  > Significantly lower power consumption on many devices. More accurate frame timing,
  > resulting in smoother video playback. Support for higher quality HDR video output on
  > capable devices. Support for secure output when playing DRM-protected content. The
  > ability to render video content at the full resolution of the display on Android TV
  > devices that upscale the UI layer."
  > "TextureView should be used only if SurfaceView does not meet your needs."
  It also flags that Compose's two wrappers "provide an API surface that limits access of
  the underlying views", recommending `PlayerSurface`/`ContentFrame` from
  `media3-ui-compose` for full lifecycle handling.

---
###### GTK4 / Linux

GTK's model is the most kaya-shaped of the four, because GTK is a widget toolkit that
does NOT own a GPU scene the way Flutter does — and it solved this problem anyway.

- **`GdkPaintable`** is the abstraction: "An interface for content that can be painted.
  The content of a `GdkPaintable` can be painted anywhere at any size without requiring
  any sort of layout." When contents change, the paintable calls
  `gdk_paintable_invalidate_contents()`, emitting `invalidate-contents`; static content
  sets `GDK_PAINTABLE_STATIC_CONTENTS`. Implementations include `GdkTexture`,
  `GdkMemoryTexture`, `GdkGLTexture` and `GdkDmabufTexture`.
  https://docs.gtk.org/gdk4/iface.Paintable.html
  `GtkPicture` displays any paintable: https://docs.gtk.org/gtk4/class.Picture.html
- **The CPU option: `GdkMemoryTexture`** — "A `GdkTexture` representing image data in
  memory." https://docs.gtk.org/gdk4/class.MemoryTexture.html — this is the naive path,
  and it is what a "kaya rasterizes, GTK blits" video implementation would use per frame.
- **The zero-copy option (GTK 4.14+): `GdkDmabufTextureBuilder` + `GtkGraphicsOffload`.**
  From GTK's own announcement (https://blog.gtk.org/2023/11/15/introducing-graphics-offload/):
  > "GtkGraphicsOffload widget, whose only job it is to give a hint that GTK should try
  > to offload the content of its child widget by attaching it to a subsurface instead of
  > letting GSK process it"
  The new `GdkDmabufTextureBuilder` wraps dmabufs (kernel buffers identified by file
  descriptors, typically from pipewire, video4linux or gstreamer) as `GdkTexture`s. Two
  configurations: the subsurface **above** the main surface enables direct scanout — a
  zero-copy path from decoder to display — and **below** it when UI must overlay the
  video, in which case the compositor still composes. Conditions: the content must
  already be dmabufs, and effects like corner-rounding defeat it.
  **Platform limit, stated flatly: "Graphics offload will only work with Wayland on
  Linux."** (X11 gets nothing.)
- Centricular's writeup of the GStreamer side
  (https://centricular.com/devlog/2024-04/gtk4-dmabuf-import/): before dmabuf import, the
  GTK4 sink "could only handle RGB system memory (i.e. after downloading from the GPU in
  case of hardware decoders) or GL textures"; dmabuf import "reduces CPU usage and power
  consumption considerably when using a suitable hardware decoder and running GTK on
  Wayland." (No measured numbers are published in that post — the claim is qualitative.)
- **`gtk4paintablesink`** is the ready-made bridge, a GStreamer element written in Rust
  providing "a `gst_video::VideoSink` along with a `gdk::Paintable` that's capable of
  rendering the sink's frames." It accepts system memory (RGBA/BGRA/RGB/BGR), GL textures,
  and "DMABufs on Linux with GTK 4.14+".
  https://gstreamer.freedesktop.org/documentation/gtk4/index.html
  `GtkGLArea` remains the manual-GL escape hatch: https://docs.gtk.org/gtk4/class.GLArea.html

###### WINUI 3 / Windows

- **`SwapChainPanel`** — "provides a hosting surface where Microsoft DirectX swap chains
  provide content that can be rendered into a XAML UI"; you get at the underlying
  `IDXGISwapChain1` by QI'ing the panel for `ISwapChainPanelNative`, and can "refresh
  graphics without syncing to the XAML framework refresh timer."
  https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.swapchainpanel
  https://learn.microsoft.com/en-us/windows/uwp/gaming/directx-and-xaml-interop
  **Constraint worth knowing:** in WinUI 3, `SwapChainPanel` does not support transparency
  and cannot be sampled by `CompositionBackdropBrush`/`AcrylicBrush` effects.
- **Visual layer: `CompositionSurfaceBrush` painting a `SpriteVisual`** is the
  lower-level composition route.
  https://learn.microsoft.com/en-us/windows/uwp/composition/composition-brushes
  https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/composition
- **`MediaPlayer` frame server mode** is Microsoft's supported "you own the frames" path
  (https://learn.microsoft.com/en-us/windows/apps/develop/media-playback/play-audio-and-video-with-mediaplayer):
  > "In frame server mode, the **MediaPlayer** does not automatically render frames to an
  > associated **MediaPlayerElement**. Instead, your app copies the current frame from the
  > **MediaPlayer** to an object that implements `IDirect3DSurface`. The primary scenario
  > this feature enables is using pixel shaders to process video frames provided by the
  > **MediaPlayer**. **Your app is responsible for displaying each frame after processing,
  > such as by showing the frame in a XAML Image control.**"
  Enabled with `IsVideoFrameServerEnabled = true`; you handle `VideoFrameAvailable` and
  call `CopyFrameToVideoSurface(IDirect3DSurface)`.
  https://learn.microsoft.com/en-us/uwp/api/windows.media.playback.mediaplayer.copyframetovideosurface
  Note the shape: **the target is a D3D surface, not a byte array.** Microsoft's own
  sample then keeps everything on the GPU (Win2D `CanvasBitmap` -> `GaussianBlurEffect`
  -> `CanvasImageSource`); nothing in the supported path ever reads the pixels into
  CPU memory.

---

##### B7. THE HARD PART — what does the pattern cost architecturally?

**The premise to check: does the framework need its own GPU compositor?**

Flutter needs one *because it has one*: `Texture` works by giving the engine's Skia/
Impeller scene a texture to draw. But that is Flutter's implementation of the pattern,
not the pattern itself. **The pattern is "the video lives in a compositable surface the
platform owns, and the framework positions it" — and every one of kaya's four backends
already sits on a platform compositor that can do this.** SwiftUI sits on Core Animation,
Compose sits on SurfaceFlinger/HWC, GTK4 sits on GSK plus (on Wayland) the system
compositor, WinUI sits on Windows.UI.Composition/DWM. kaya does not need to build a GPU
compositor; it needs to be able to say "put a platform-owned surface in this rectangle."

That is the good news. The cost is real but it is a *different* cost from "build a
renderer": it is **a second content model.** kaya's node tree currently has one leaf that
produces pixels (the canvas), and its bytes are kaya's. A video node's bytes would not be
kaya's — they would be a platform handle, per backend, with a per-backend lifecycle, and
kaya's own observables (expect_ink and friends) could not read them the way they read a
canvas raster. That is the architectural price, and it is paid in the harness and the
gates as much as in the backends.

###### Per-backend: can this be done inside a native-view UI layer?

**SwiftUI (macOS + iOS) — YES, and the primitive is `AVSampleBufferDisplayLayer`.**
It is a `CALayer` subclass that "displays compressed or uncompressed video frames"
(https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer), so
it composites in the normal Core Animation tree alongside every SwiftUI view — no
GPU scene of kaya's own required. You reach it from SwiftUI through
`NSViewRepresentable`/`UIViewRepresentable`, which is exactly the drop-down mechanism
kaya's SwiftUI backend already uses for gaps. Apple DTS's own recommendation when asked
`CAMetalLayer` vs `AVSampleBufferDisplayLayer` for video:
> "Overall AVSampleBufferDisplayLayer is probably better suited for your needs in this
> case and is expected to perform well." — https://developer.apple.com/forums/thread/756206

Ranking of SwiftUI options, fast to slow:
1. `AVSampleBufferDisplayLayer` (enqueue `CMSampleBuffer`s; layer-composited, GPU) — fast.
2. `CAMetalLayer` / `MTKView` with a `CVMetalTextureCache`-derived texture — fast, more
   control, more code, and it loses AVFoundation features (PiP, etc.).
3. `AVPlayerLayer` / SwiftUI's `VideoPlayer` — fast, but only if AVPlayer owns the media.
4. **`Image(decorative: cgImage, scale:)` recreated per frame — SLOW, and this is the
   trap.** There is no SwiftUI primitive that takes a `CVPixelBuffer`; the only route is
   CVPixelBuffer -> CGImage -> `Image`, which forces a CPU-side pixel path AND drives a
   SwiftUI view-graph invalidation + diff on every frame. This is the "kaya rasterizes,
   SwiftUI blits" shape, and it is the slow one.

**Compose (Android) — YES, and Google has already written the answer down as a
recommendation.** `AndroidExternalSurface` gives a composable a real `Surface` to hand
`MediaCodec`/ExoPlayer, and it "uses a separate window layer, graphics composition is
handled by the system compositor which can bypass the GPU and provide better performance
and power usage characteristics." `AndroidEmbeddedExternalSurface` is the in-tree variant
whose "graphics composition is handled like any other UI widget using the GPU, which can
lead to increased power and memory bandwidth usage." Google's rule: "It is recommended to
use AndroidExternalSurface over AndroidEmbeddedExternalSurface whenever possible."
(https://composables.com/foundation/androidexternalsurface). Note this is *Compose's own
API*, in `androidx.compose.foundation` — no Flutter-style engine required.

**GTK4 — YES: `GtkPicture` + a `GdkPaintable`.** GTK is the existence proof that a plain
widget toolkit can do this: the widget displays a paintable, the paintable signals
`invalidate-contents` per frame, and the paintable's backing can be a `GdkMemoryTexture`
(CPU, slow), a `GdkGLTexture`, or a `GdkDmabufTexture` (zero-copy from a hardware
decoder, GTK 4.14+). Wrapping it in `GtkGraphicsOffload` promotes it to a Wayland
subsurface. `gtk4paintablesink` supplies the whole thing off the shelf. **The caveat is
that the fast path is Wayland-only** — on X11 GTK falls back to texture upload, which is
the CPU path again.

**WinUI 3 — YES, but it is the roughest of the four.** `SwapChainPanel` is a XAML
element hosting a DXGI swap chain, so it composites in the XAML tree; the D3D11 video
processor does YUV->RGB and scaling on the GPU. Frame server mode's `CopyFrameToVideoSurface`
targets an `IDirect3DSurface`, keeping the frame on the GPU. The friction: `SwapChainPanel`
has no transparency and cannot be sampled by backdrop effects in WinUI 3, so it is
genuinely a hole in the XAML tree rather than a normal element — which pushes the same
"UI beside, not on top" constraint that section C describes.

**Summary verdict for B7:** the texture-registry pattern does NOT require kaya to build
Flutter's GPU compositor. All four platforms expose a *platform-composited surface* that a
native-view UI layer can position. What kaya would give up is that video pixels stop being
kaya's pixels — no `expect_ink` over a video frame, no tiny-skia effect applied to it, and
four separate lifecycles to manage.

---
##### B8. How expensive is the normal UI path per frame? (what is actually measured)

**The honest headline: almost nobody has published a clean per-frame measurement of
"push a full-frame bitmap through the framework's normal image widget."** What exists is
(a) platform vendors stating the rule qualitatively, sometimes forcefully, and (b) a few
incidental numbers from bug reports. Both are below. Do not let a survey turn the
qualitative statements into invented milliseconds.

###### Android — the strongest authoritative statements of the four

From AOSP's graphics architecture docs (https://source.android.com/docs/core/graphics/arch-tv):
> "TextureView has better alpha and rotation handling than SurfaceView, but **SurfaceView
> has performance advantages when compositing UI elements layered over videos.**"
> "When a client renders with TextureView, the UI toolkit composites the TextureView
> object's content into the view hierarchy with the GPU."
> "Updates to the content may cause other view elements to redraw, for example, if the
> other views are positioned on top of TextureView."
> "After view rendering completes, SurfaceFlinger composites the app UI layer and all
> other layers, so that **every visible pixel is composited twice.**"
> "In API 24 and higher, it's recommended to implement SurfaceView instead of TextureView."

And (https://source.android.com/docs/core/graphics/arch-sv-glsv):
> "Rendering with SurfaceView, SurfaceFlinger directly composes buffers to the screen.
> Without a SurfaceView, you need to composite buffers to an offscreen surface, which then
> gets composited to the screen, so rendering with SurfaceView eliminates extra work."

Media3's list of SurfaceView's advantages over TextureView leads with "**Significantly
lower power consumption on many devices**" (https://developer.android.com/media/media3/ui/surface).
Compose's own kdoc says the embedded variant "can lead to **increased power and memory
bandwidth usage**". **Nowhere does Google publish the delta in numbers.**

No published measurement was found for `ImageBitmap`-recreated-per-frame in Compose
specifically. The general Compose performance material is about recomposition counts, not
bitmap upload (https://developer.android.com/develop/ui/compose/performance).

###### Windows — one qualitative rule and one incidental number

Microsoft Learn, "Optimize animations, media, and images for WinUI apps"
(https://learn.microsoft.com/en-us/windows/apps/develop/performance/optimize-animations-and-media):
> "**Making per-frame updates, which are effectively dependent animations.** An example of
> this is applying transformations in the handler of the CompositionTarget.Rendering event."
> (listed under things that *disable* the composition-thread optimization and put work on
> the UI thread)
> "The [SoftwareBitmapSource] class **obviates an extra copy that would typically be
> necessary with WriteableBitmap**, and that helps reduce peak memory and source-to-screen
> latency." / "your app should use **SoftwareBitmapSource** when loading uncompressed image
> data instead of using **WriteableBitmap**."
> "The XAML framework can optimize the display of video content when it is the only thing
> being rendered, resulting in an experience that uses less power and yields higher frame
> rates."
> "**Animating a MediaPlayerElement is a similarly bad idea.** Beyond the performance
> detriment, it can cause tearing or other artifacts in the video content being played."

The one hard number found is WPF, not WinUI, and is a regression report rather than a
steady-state measurement — but it is the right order of magnitude to be scared of:
dotnet/wpf#6411 reports `WriteableBitmap` used to display **1920x1080** video frames
"will cost 70-90 ms with .net6", against no such cost on .NET Framework 4.8
(https://github.com/dotnet/wpf/issues/6411). A sibling report, dotnet/wpf#8045, records
`WriteableBitmap.Lock()` taking 100-200 ms at 3352x909 and under a millisecond at
3353x909 — a one-pixel width change (https://github.com/dotnet/wpf/issues/8045). The
lesson is not the specific number; it is that **the per-frame-bitmap path on a XAML stack
has cliffs nobody documents.**

###### Apple — no published number at all

Apple publishes no measurement of `Image(decorative:)`-per-frame vs
`AVSampleBufferDisplayLayer`. The strongest available statement is the DTS engineer's
recommendation quoted in B6. This is a genuine gap: **if kaya wants a number here it will
have to measure it, and that measurement would be novel.**

###### GTK — no published number

GTK's and Centricular's claims are qualitative ("reduces CPU usage and power consumption
considerably"). No before/after figures are published in either post.

###### The one place a real number exists: Chromium

Chromium's VideoNG deep-dive (https://developer.chrome.com/docs/chromium/videong) is the
only source found that publishes overlay-vs-composite power figures:
> "the use of these (also often) opaque buffers ensures that **high bandwidth video data
> never actually leaves the GPU**"
> macOS fullscreen: "**power consumption during fullscreen video playback was halved**"
> "we can use overlays even in non-fullscreen cases, **saving up to 50% nearly everywhere**"
> "the goal of any modern video playback engine with efficiency in mind is to minimize
> bandwidth between the decoder and the final rendering step"

A 50% power reduction from *nothing but changing where the frame is composited* is the
best single datum in this whole document for the "is the CPU path affordable" question.

---

##### C. THE HYBRID: video as its own compositor layer

###### C9. Is there a middle route?

**Yes, and it is what every platform actually does — including for its own video
players.** The route is: kaya's canvas stays exactly as it is (CPU raster, tiny-skia,
blit), and a `video` node is declared as a *platform-composited surface* placed in the
layout, with kaya's UI drawn **around** it rather than **over** it. The platform's
compositor puts the two together. kaya never sees a video pixel.

This is not a compromise invented for kaya; it is the model with the best name-brand
support of anything in this document:

- **Chromium**: "video is just a fixed-size hole with opacity", where "each video talks
  directly to Viz" through a `SurfaceLayer` — hole-punching, in a browser engine that owns
  a full compositor and *still* prefers to hand the frame to the platform.
  https://developer.chrome.com/docs/chromium/videong
  Design doc: https://www.chromium.org/developers/design-documents/video-playback-and-compositor/
- **Android** is the extreme case, and it is the default: a `SurfaceView`'s surface is
  "the producer side of a BufferQueue, whose consumer is a SurfaceFlinger layer"; "the
  framework places the newly created surface behind the app UI surface" and the view
  leaves a transparent region for it. The Hardware Composer HAL then decides per-layer
  whether the display hardware can scan the video plane out directly ("device composition")
  instead of the GPU compositing it ("client composition").
  https://source.android.com/docs/core/graphics/arch-sv-glsv
  https://source.android.com/docs/core/graphics/hwc
  In Compose this is literally spelled as an argument:
  `zOrder = AndroidExternalSurfaceZOrder.Behind | MediaOverlay | OnTop`.
- **GTK4** offers the same choice explicitly: the offload subsurface goes **above** the
  main surface (direct scanout, the fast case) or **below** it "when UI elements appear
  over the video", in which case "the compositor still handles composition."
  https://blog.gtk.org/2023/11/15/introducing-graphics-offload/
- **Windows** states the rule as guidance rather than mechanism: "**Don't draw XAML
  elements on top of video when it's in embedded mode. If you do, the framework is forced
  to do a little extra work to compose the scene.** Placing transport controls below an
  embedded media element instead of on top of the video is a good example of optimizing
  for this situation." And for the full-window case: "For the most efficient media
  playback, set the size of a MediaPlayerElement to be the width and height of the screen
  and don't display other XAML elements", hiding captions and transport controls with
  `Visibility="Collapsed"` "when they are not needed to put media playback back into its
  most efficient state."
  https://learn.microsoft.com/en-us/windows/apps/develop/performance/optimize-animations-and-media

###### What the hybrid forbids

This is the part to be honest about, because the restrictions are real and they are the
same on all four platforms:

1. **Nothing of kaya's may be drawn ON the video.** Captions, transport controls, a
   timestamp, a watermark, a focus ring — if it overlaps the video rectangle, either it
   forces the compositor off the fast path (Windows: "extra work"; GTK: subsurface goes
   *below*; Android: HWC falls back to client composition) or, in the strictest
   configurations, it is simply painted under the video and invisible. Android's own docs
   flag exactly this as SurfaceView's weak spot resolved only by ordering:
   "SurfaceView has performance advantages when compositing UI elements layered over
   videos" — i.e. the layering is what you must get right.
2. **No blending between two clips.** A crossfade needs both frames in one buffer; two
   compositor layers can only be alpha-blended by the compositor, which several of these
   paths (opaque overlay planes, `SwapChainPanel` with no transparency) do not support.
3. **No per-frame effects.** A tiny-skia blur, a colour grade, a mask, a rounded corner
   over the video — all require the pixels, which kaya will not have. GTK names the
   corner-rounding case specifically as something that "interfere[s] with subsurface usage".
4. **No animating or transforming the video rectangle.** Microsoft: "Animating a
   MediaPlayerElement is a similarly bad idea. Beyond the performance detriment, it can
   cause tearing or other artifacts." Android's `SurfaceView` is historically the widget
   that does not animate or scroll cleanly (which is exactly why `TextureView` exists, and
   why Media3 says use TextureView only "where smooth animations or scrolling of the video
   surface is required prior to Android 7.0").
5. **No `expect_ink` over the video.** kaya's harness reads its own raster; a
   compositor-owned surface is not in it. Every video observable would have to be a
   different kind of assertion (frame counters, presentation timestamps, platform
   screenshot), and the byte-frozen cross-platform string discipline that scenes rely on
   does not survive a real decoder's output anyway.
6. **Two content models forever.** Layout, clipping, scrolling, z-order and the a11y tree
   all have to be taught that one leaf is not kaya's pixels. The rounded-corner example is
   the canary: the moment a video sits inside a clipped scroller with a corner radius,
   three of the four backends silently leave the fast path.

###### The escape hatch each platform gives back

Every platform offers an in-tree variant that lifts restrictions 1-4 at the cost of the
performance: Android's `AndroidEmbeddedExternalSurface`/`TextureView`, GTK's plain
`GtkPicture` without `GtkGraphicsOffload`, WinUI's frame-server-into-a-Win2D-image path,
Apple's `CAMetalLayer`/`Image`-per-frame. So the honest shape of the design space is a
**two-tier** one, and every platform already models it that way:

| tier | what you get | what you pay |
|---|---|---|
| **overlay / offload** (SurfaceView `Behind`, GTK offload subsurface, SwapChainPanel, AVSampleBufferDisplayLayer as a sibling layer) | up to 50% less power (Chromium's figure), decoder-to-display zero copy, hardware scanout | UI beside the video, not over it; no effects, no blend, no transform |
| **embedded** (AndroidEmbeddedExternalSurface, GtkPicture + memory/GL texture, Image + frame server, Image(decorative:) per frame) | video is a normal element: clip it, round it, overlay it, animate it | "every visible pixel is composited twice" (Android's words), plus whatever copies the path makes |

kaya's canvas rule ("kaya rasterizes, backends blit") survives intact under either tier —
it just does not extend to video. What the rule cannot survive is video frames going
through tiny-skia: that is the six-copy, ~4.85 GB/s-at-1080p60 path of section A1, on a
rasterizer whose own README says it does not do non-RGBA8888 images and does not do GPU.

---

##### Sources (all URLs cited above, collected)

- tiny-skia README: https://github.com/linebender/tiny-skia/blob/main/README.md
- tiny-skia benches: https://github.com/linebender/tiny-skia/blob/main/benches/README.md
- libyuv README: https://chromium.googlesource.com/libyuv/libyuv/+/HEAD/README.md
- Mozilla bug 1256475 (libyuv timings): https://bugzilla.mozilla.org/show_bug.cgi?id=1256475
- Snapdragon 8 Elite Gen 5 product brief: https://www.qualcomm.com/content/dam/qcomm-martech/dm-assets/documents/Snapdragon-8-Elite-Gen-5-product-brief.pdf
- Notebookcheck SD 8 Elite Gen 5 (84.8 GB/s): https://www.notebookcheck.net/Qualcomm-Snapdragon-8-Elite-Gen-5-for-Galaxy-Processor-Benchmarks-and-Specs.1271123.0.html
- Apple M4 Pro / M4 Max newsroom: https://www.apple.com/newsroom/2024/10/apple-introduces-m4-pro-and-m4-max/
- Flutter Texture widget: https://api.flutter.dev/flutter/widgets/Texture-class.html
- Flutter TextureLayer: https://api.flutter.dev/flutter/rendering/TextureLayer-class.html
- Flutter TextureBox: https://api.flutter.dev/flutter/rendering/TextureBox-class.html
- Flutter SurfaceProducer breaking change: https://docs.flutter.dev/release/breaking-changes/android-surface-plugins
- Flutter issue 159162 (FlutterTexture redesign): https://github.com/flutter/flutter/issues/159162
- AVSampleBufferDisplayLayer: https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer
- CVMetalTextureCacheCreateTextureFromImage: https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)
- AVPlayerItemVideoOutput: https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput
- Apple QA1781 (IOSurface-backed CVPixelBuffers): https://developer.apple.com/library/ios/qa/qa1781/_index.html
- Apple DTS, CAMetalLayer vs AVSampleBufferDisplayLayer: https://developer.apple.com/forums/thread/756206
- Android SurfaceTexture: https://developer.android.com/reference/android/graphics/SurfaceTexture
- AHardwareBuffer: https://developer.android.com/ndk/reference/group/a-hardware-buffer
- Compose AndroidExternalSurface kdoc: https://composables.com/foundation/androidexternalsurface
- Compose AndroidEmbeddedExternalSurface kdoc: https://composables.com/docs/androidx.compose.foundation/foundation/composables/AndroidEmbeddedExternalSurface
- Media3 surface types: https://developer.android.com/media/media3/ui/surface
- AOSP SurfaceView: https://source.android.com/docs/core/graphics/arch-sv-glsv
- AOSP TextureView: https://source.android.com/docs/core/graphics/arch-tv
- AOSP Hardware Composer HAL: https://source.android.com/docs/core/graphics/hwc
- AOSP graphics architecture: https://source.android.com/docs/core/graphics/architecture
- GdkPaintable: https://docs.gtk.org/gdk4/iface.Paintable.html
- GdkMemoryTexture: https://docs.gtk.org/gdk4/class.MemoryTexture.html
- GtkPicture: https://docs.gtk.org/gtk4/class.Picture.html
- GtkGLArea: https://docs.gtk.org/gtk4/class.GLArea.html
- GTK graphics offload announcement: https://blog.gtk.org/2023/11/15/introducing-graphics-offload/
- Centricular, dmabuf import in the GTK4 sink: https://centricular.com/devlog/2024-04/gtk4-dmabuf-import/
- gtk4paintablesink: https://gstreamer.freedesktop.org/documentation/gtk4/index.html
- WinUI SwapChainPanel: https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.swapchainpanel
- DirectX and XAML interop: https://learn.microsoft.com/en-us/windows/uwp/gaming/directx-and-xaml-interop
- Composition brushes: https://learn.microsoft.com/en-us/windows/uwp/composition/composition-brushes
- Visual layer overview: https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/composition
- MediaPlayer frame server mode: https://learn.microsoft.com/en-us/windows/apps/develop/media-playback/play-audio-and-video-with-mediaplayer
- CopyFrameToVideoSurface: https://learn.microsoft.com/en-us/uwp/api/windows.media.playback.mediaplayer.copyframetovideosurface
- WinUI media/animation optimization: https://learn.microsoft.com/en-us/windows/apps/develop/performance/optimize-animations-and-media
- dotnet/wpf#6411 (WriteableBitmap 70-90ms at 1080p): https://github.com/dotnet/wpf/issues/6411
- dotnet/wpf#8045 (WriteableBitmap.Lock cliff): https://github.com/dotnet/wpf/issues/8045
- Chromium VideoNG: https://developer.chrome.com/docs/chromium/videong
- Chromium video playback and compositor: https://www.chromium.org/developers/design-documents/video-playback-and-compositor/
- Compose performance: https://developer.android.com/develop/ui/compose/performance

STATUS: COMPLETE.

### §2.3 What this means for kaya

Owned rendering is feasible and it is expensive, and the expense is not where
people expect it.

**It is NOT primarily a bandwidth problem.** A naive CPU path at 1080p60
moves about 4.85 GB/s, which is ~5.7% of a flagship phone's peak memory
bandwidth — survivable. It is 13x what a texture path spends, it is battery
and heat rather than dropped frames, and it becomes a wall only at 4K60
(~19 GB/s, about a quarter of the whole phone). The sharper number is the
one measured on the normal per-frame bitmap route: WPF's `WriteableBitmap`
costs 70-90 ms per 1080p frame. That is the shape of "push frames through the
UI toolkit's image widget", and it does not work.

**It IS a second-content-model problem.** kaya does not need to build
Flutter's GPU compositor — every backend already sits on a platform
compositor, and each exposes a surface a native-view UI layer can position:
`AVSampleBufferDisplayLayer` on Apple (a plain CALayer, reachable through the
Representable drop-down kaya already uses), `AndroidExternalSurface` in
Compose, `GtkPicture` + `GdkPaintable` on GTK, `SwapChainPanel` on WinUI. What
kaya gives up is that video pixels stop being kaya's pixels: no `expect_ink`
over them, no tiny-skia effect on them, four lifecycles to manage, and a
standing rule that kaya may not draw ON the video (Microsoft states it
outright: "Don't draw XAML elements on top of video when it's in embedded
mode"). tiny-skia cannot help either way — it is RGBA8888-only and has no
notion of a planar or YUV surface, so every frame must be converted before it
can be touched, and libyuv's own numbers put that conversion at 8 ms per 4K
frame with AVX2 and 54 ms without.

**And two pieces of history say the four-backend design does not hold.** Qt
built exactly it — `QVideoSink`/`QVideoFrame` over AVFoundation, MediaCodec,
Windows Media Foundation and GStreamer — and has since made FFmpeg the default
on every platform, deprecating the WMF backend at 6.10 and MediaCodec at 6.8,
with "new features will only be implemented on the FFmpeg media backend."
Servo, facing the same choice with a funded multimedia team, has one
functional backend and it is GStreamer everywhere. Firefox did build four and
spends ~561 KB of C++ on the Windows module alone.

So if kaya ever owns decode, the realistic shapes are ONE backend everywhere
(FFmpeg, with an iOS licensing problem that has no clean answer) or a narrow
platform-decoder trait that only ever answers "give me the frame at time t"
— which is exactly what thumbnails need and nothing more.

---

## §3 — What an editor actually needs
### §3.0 The editor's UI against kaya's existing vocabulary (repo-internal)

Before asking what a preview costs, it is worth pricing the timeline
itself, because a surprising amount of the editor is already spellable
and one part of it is not.

**Already there:**

- `slider` is kind 7 (crates/kaya/src/spec.rs:2356). Trim, zoom and
  volume need no new kind.
- Dragging clips is the CURRENT milestone (docs/dnd-plan.md, design pass
  2026-09-02); a timeline is that milestone's natural forcing app.
- A waveform, a playhead, clip rectangles and their labels are all
  drawable with the canvas's existing ops: `move_to`, `line_to`,
  `close`, `stroke`, `fill`, `font`, `text` (spec.rs:2372-2381). A
  peak envelope is a polyline or a filled path; a playhead is a stroked
  line; a clip is a filled rect with a text run.

**Not there, and worth knowing before the app is scoped:**

- **The canvas has no image op.** The op vocabulary is five geometry ops
  plus two text ops, and docs/canvas-plan.md §3.3 states that additions
  are refusals rather than omissions. So a FILMSTRIP of thumbnails
  cannot be drawn inside a canvas today. Either the timeline lays out N
  `image` widgets in a row (which works, and is the wrap-native answer),
  or the canvas grows a `draw_image` op (a spec change, a wire change,
  eight bindings, three interpreter copies).
- **The canvas has no curves.** Clip rectangles cannot have rounded
  corners in a canvas drawing; a timeline drawn with the current
  vocabulary is square-cornered.
- **Audio is designed but unbuilt.** DESIGN.md:3139-3151 rules the
  architecture — "the core owns the real-time callback (Rust, RT-safe)
  and drains a sample ring the app fills ahead of playback (20 to 100 ms
  ahead; an underrun produces silence)" — and docs/deferred.md:1508-1511
  keeps it "admission-gated on an app that needs it."

**That last point is the hinge of the whole decision, and it is easy to
miss.** A video editor needs audio. Which route is taken decides whether
the video milestone silently pulls the AUDIO milestone in with it:

- **Platform player**: AVPlayer / ExoPlayer / MediaPlayer / GtkMediaFile
  each play the audio track themselves, with their own clock and their
  own A/V sync. `volume` and `muted` are properties on the player. kaya's
  audio milestone stays deferred, untouched.
- **Owned rendering**: kaya decodes video frames, so kaya must also
  decode and PLAY audio — because A/V sync is driven by the audio clock,
  not the video clock, in every player that works. That means the
  core-owned RT callback and the sample ring have to exist before the
  first frame is correct on screen. The video milestone becomes the video
  AND audio milestone, on five platforms.

### §3.1 Preview architectures: clip monitor versus program monitor
Research slice for kaya's "forcing app" question: how much of the video stack must the
library own if the demo app is a video editor with playback?


##### A1. Media bin preview vs composed timeline preview

The distinction, crisply:

- **Source (media bin / clip) monitor** — plays ONE file from disk at a time. A plain
  platform player does this: hand it a URL, get frames on screen, seek within the file.
  Nothing about the project's edit is involved.
- **Program (timeline / composed) monitor** — plays what the PROJECT would export at the
  playhead. At any instant that may be: a cut between two different source files, a
  crossfade blending two clips at once, a title or PiP overlay composited on top, several
  audio tracks mixed with per-clip gain and fades, a clip playing at 2x speed with resampled
  audio, and a colour/effect chain. No single-file player can show any of that, because the
  frame at that instant does not exist in any file.

Both monitors are standard vocabulary in real editors:

- Kdenlive's manual names them exactly: "The Clip Monitor displays the original video of the
  selected clip in the Project Bin ... The Project Monitor displays the video output as
  arranged on the timeline." https://docs.kdenlive.org/en/cutting_and_assembling/monitors.html
- Shotcut's UI has a Source tab and a Project tab on the same player for the same reason:
  https://shotcut.org/howtos/editing/basic-editing/

###### MLT (the engine behind Shotcut and Kdenlive)

MLT is a C multimedia framework with a **pull-based producer/consumer** model. Kdenlive's own
developer intro (KDE/kdenlive/dev-docs/mlt-intro.md) states the four services:

- **Producers** are sources of individual audio and video frames — files, devices, colour and
  title clips. "producers produce frames only when asked to do so, because MLT adheres to
  pulling frames."
- **Consumers** are the sinks — "a screen display such as Kdenlive's monitors, or an
  audio/video encoder such as AAC/H.264 that writes video container files."
- **Filters** modify frames as they pass through ("you usually see filters as effects").
- **Transitions** "are mixers that combine exactly two input frames into a new single output
  frame."

And the structural pair that makes a timeline:

- **Playlist** — a producer that plays other producers "only one after another (sequentially)".
  This is one timeline TRACK.
- **Tractor** — a producer that "can use producers in parallel at the same time", i.e. several
  playlists plus the transitions that mix them. This is the whole MULTITRACK timeline.

Source: https://github.com/KDE/kdenlive/blob/master/dev-docs/mlt-intro.md
MLT project home: https://mltframework.org/
MLT's own docs on the framework/services: https://mltframework.org/docs/framework/

The crux for kaya: **the composed timeline is itself just another producer.** The monitor is a
consumer attached to the tractor; the exporter is a different consumer attached to the SAME
tractor. That is why Shotcut/Kdenlive preview is WYSIWYG with export — one graph, two sinks.
Shotcut wraps MLT objects in a `MultitrackModel` (a QAbstractItemModel over the C API);
Kdenlive wraps `Mlt::Producer` in `ClipController`, `Mlt::Playlist` in `TrackModel`, and
`Mlt::Tractor` in `TimelineItemModel`.
https://github.com/mltframework/shotcut  ·  https://github.com/KDE/kdenlive

##### A2. Can the PLATFORM play a composed timeline? (the crux)

Short answer: **all four platforms now ship a composition-playing API, but they are not equal.
Apple's is mature and general; Windows' is a frozen WinRT API that still works; Android's landed
as experimental in December 2025; Linux/GTK has GES, which is a real engine but is a separate
library, not "the platform".**

###### Apple (macOS + iOS) — YES, mature, and this is the strong case

`AVComposition`/`AVMutableComposition` is a *virtual asset*: tracks assembled from time ranges
of other assets. It subclasses `AVAsset`, so anywhere an asset is playable, a composition is
playable — `AVPlayerItem(asset: composition)` then `AVPlayer`.

- `AVVideoComposition` — "An object that describes how to compose video frames at particular
  points in time." Built-in compositor gives per-source "a spatial transformation, an opacity
  value, and a cropping rectangle ... These values can vary over time by applying linear ramping
  functions." (That is enough for cuts, PiP, and opacity crossfades with no custom code.)
  https://developer.apple.com/documentation/avfoundation/avvideocomposition
- Custom compositor: "You can create a custom video compositor by implementing the
  `AVVideoCompositing` protocol. The system provides the custom video compositor with pixel
  buffers for each of its video sources during playback, and can perform arbitrary graphical
  operations on them to produce visual output." (Same doc.) Note **"during playback"** — the
  system drives your compositor at preview time, not only at export.
- `AVAudioMix` mixes the audio tracks (per-track volume ramps).
  https://developer.apple.com/documentation/avfoundation/avaudiomix
- Apple's own sample **AVCustomEdit** is exactly the editor case: "a simple AVFoundation based
  movie editing application demonstrating custom compositing to add transitions ... It implements
  the AVVideoCompositing and AVVideoCompositionInstruction protocols to have access to individual
  source frames, which are then rendered using OpenGL or Metal off screen rendering." It ships an
  `APLCrossDissolveRenderer`. Preview and export use the same objects.
  https://developer.apple.com/library/archive/samplecode/AVCustomEdit/Listings/ReadMe_md.html
- `AVPlayerItem.customVideoCompositor` exists as a property, i.e. playback of a custom-composited
  timeline is a first-class thing.
  https://developer.apple.com/documentation/avfoundation/avplayeritem/customvideocompositor
- WWDC20 "Edit and play back HDR video with AVFoundation" is the current talk on this path.
  https://developer.apple.com/videos/play/wwdc2020/10009/

So on Apple, a timeline editor needs **no frame pipeline at all**: build the composition, hand it
to AVPlayer, put an `AVPlayerLayer` / SwiftUI `VideoPlayer` on screen.

###### Android — YES as of Media3 1.9.0 (Dec 2025), but EXPERIMENTAL

`androidx.media3.transformer.Transformer` is the **export** engine. The preview counterpart is
`CompositionPlayer`:

- "The 1.9.0 release introduces CompositionPlayer under a new @ExperimentalApi annotation. The
  annotation indicates that it is available for experimentation, but is still under development."
  It "enables real-time preview of media edits", is "built upon the familiar Media3 Player
  interface", and "uses the same Composition object that you would pass to Transformer for
  exporting, streamlining the editing workflow by unifying the data model for preview and export."
  https://android-developers.googleblog.com/2025/12/media3-190-whats-new.html
- Source: https://github.com/androidx/media/blob/release/libraries/transformer/src/main/java/androidx/media3/transformer/CompositionPlayer.java
- Demo app (what a real composed preview looks like in code):
  https://github.com/androidx/media/tree/main/demos/composition
- Release notes / versions: https://developer.android.com/jetpack/androidx/releases/media3
- Maturity caveats are visible in the issue tracker: multiple video sequences was a feature
  REQUEST (https://github.com/androidx/media/issues/1488), CompositionPlayer "freezes when playing
  a sequence of video clips that have no audio tracks" (https://github.com/androidx/media/issues/2854),
  and extreme clip speeds can wedge the hardware decoder
  (https://github.com/androidx/media/issues/3053).

###### Windows — YES, `Windows.Media.Editing.MediaComposition`, WinRT, works from WinUI 3

- Namespace overview: "The APIs in the Windows.Media.Editing namespace allow you to quickly
  develop apps that enable users to create media compositions from audio and video source files
  ... append multiple video clips together, add video and image overlays, add background audio,
  and apply both audio and video effects." It explicitly positions itself against Media
  Foundation: "an easy-to-use Windows Runtime interface that dramatically reduces the amount and
  complexity of code required to perform these tasks when compared to the low-level Microsoft
  Media Foundation API."
  https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/media-compositions-and-editing
- Preview: `composition.GeneratePreviewMediaStreamSource(width, height)` returns a
  `MediaStreamSource`; wrap it with `MediaSource.CreateFromMediaStreamSource` and set it as the
  `Source` of a `MediaPlayerElement`. **The doc's current code sample is WinUI 3** — it uses
  `Microsoft.UI.Xaml.Controls.MediaPlayerElement`, `WinRT.Interop.InitializeWithWindow.Initialize`
  and `Microsoft.UI.Dispatching.DispatcherQueue`, and the canonical URL is under
  `/windows/apps/develop/media-authoring-processing/`. Page date on fetch: 2026-08-23. So it is
  live and desktop-supported, **not deprecated** — but it is a WinRT API being consumed from
  WinUI 3, which for kaya means the WinUI backend already has the C#/WinRT plumbing it needs.
- Caveats straight from the doc: MP4 video only; MP3/WAV/FLAC background audio; a clip may appear
  once (use `Clone()` to reuse); and the big one — "The MediaPlayerElement timeline is not
  automatically updated to reflect changes in the composition. It's recommended that you call both
  GeneratePreviewMediaStreamSource and set the MediaPlayerElement Source property every time you
  make a set of changes to the composition". That is a **rebuild-the-source-on-every-edit** model,
  which is coarse compared with AVFoundation's live composition.
- Export is `RenderToFileAsync` with `MediaTrimmingPreference.Fast|Precise`; projects serialize
  with `SaveAsync`/`LoadAsync` (.cmp).
- API reference: https://learn.microsoft.com/en-us/uwp/api/Windows.Media.Editing.MediaComposition
- Microsoft's sample: https://github.com/microsoft/Windows-universal-samples/tree/main/Samples/MediaEditing

###### Linux / GTK — GES (GStreamer Editing Services), a real engine but a separate library

- "GStreamer Editing Services is a library to simplify the creation of multimedia editing
  applications, based on the GStreamer multimedia framework." Cross-platform, LGPL.
  https://gstreamer.freedesktop.org/documentation/gst-editing-services/
- Model: a `GESTimeline` **is a `GstElement`** and "can therefore be used in any GStreamer
  pipeline like any other object" — which is the same trick MLT plays. A timeline holds `GESLayer`s
  (user-visible track arrangement) holding `GESClip`s, which create `GESTrackElement`s that go into
  `GESTrack`s (one audio, one video, matching GStreamer output streams).
  https://github.com/GStreamer/gst-editing-services/blob/master/docs/index.md
- Preview = attach a video sink; export = attach an encodebin. `ges-launch-1.0` is the CLI that
  does both: https://gstreamer.freedesktop.org/documentation/tools/ges-launch.html
- Rust bindings exist and are first-party: `gstreamer-editing-services` in gstreamer-rs.
  https://crates.io/crates/gstreamer-editing-services ·
  https://gstreamer.freedesktop.org/documentation/rust/stable/latest/docs/gstreamer_editing_services/
  Maturity note from the bindings' own docs: "The GStreamer Editing Services API is not Thread Safe
  and before the 1.16 release this was not properly expressed in the code, so users are strongly
  encouraged to run with GES >= 1.16."
  https://github.com/GStreamer/gstreamer-rs
- The reference consumer is **Pitivi**, which is GES's own editor:
  https://gitlab.gnome.org/GNOME/pitivi

###### Verdict for kaya

"The platform can play a composed timeline" is **true on all four**, but only Apple's is a
no-caveat yes. Ranked by how much the app has to carry:

| Platform | API | State | Preview fidelity out of the box |
| --- | --- | --- | --- |
| macOS/iOS | AVComposition + AVVideoComposition + AVAudioMix + AVPlayer | mature, ~10 years | cuts, opacity ramps, transforms, crops, audio mix; arbitrary transitions via custom compositor |
| Windows | Windows.Media.Editing.MediaComposition | shipped, stable, frozen-feeling; WinUI 3 sample current | clips, overlays/layers, background audio, effects; **must regenerate the stream source on edit** |
| Android | media3 `CompositionPlayer` | @ExperimentalApi since 1.9.0 (Dec 2025) | single/multi sequence, effects, speed; open bugs |
| Linux | GES (not "the platform" — a GStreamer library, Rust bindings available) | mature engine, small user base | full NLE model (layers/clips/tracks/transitions) |

The uncomfortable part: these four have **four different composition models with four different
capability sets**. Making them present ONE uniform semantics — kaya's invariant 1 — is the whole
cost of this route. A crossfade means an `AVVideoCompositing` custom compositor on Apple, a
`MediaOverlay` with opacity or a video effect on Windows, an effect chain on media3, and a
`GESTransitionClip` on GES. They will not agree on frame-exactness, seek behaviour, or which
codecs the composition accepts (Windows: MP4 only).
##### A3. What the cross-platform frameworks actually do today

###### Flutter — no composed preview. Player + rendered proxies + ffmpeg export.

`video_player` gives a `Texture` fed by AVPlayer/ExoPlayer; the popular editor package
`video_editor` (crop/trim/rotate/cover) depends on **`video_player`, `video_thumbnail`,
`path_provider`, `transparent_image`, `path`** — no compositor. Its "preview" of a crop is a
`CropGridViewer` drawing a rectangle over a single playing video; the trim UI is a filmstrip of
extracted thumbnails (`trimThumbnailsQuality` "specifies the quality of the generated trim slider
thumbnails, from 0 to 100"). Export is **not in the package** at all: from v3.0.0 "the
video_editor package no longer includes ffmpeg_kit_flutter" — it hands you an ffmpeg command
string and you run it yourself. https://pub.dev/packages/video_editor
That is the honest state of Flutter video editing: **single-source preview + geometry overlay,
full fidelity only at export**. (And the ecosystem's ffmpeg binding, ffmpeg-kit, was retired in
2025, which made this worse: https://github.com/arthenica/ffmpeg-kit )

###### React Native — same shape, one level lower

`react-native-video` is a wrapper: ExoPlayer on Android, AVPlayer on iOS/tvOS/visionOS.
https://docs.thewidlarzgroup.com/react-native-video/docs/v6/intro/
It plays sources. Multiple simultaneous players are possible but the ExoPlayer issue tracker is
full of the reasons not to lean on it for a timeline: creating player instances is expensive, and
"each device has limited media codecs responsible for video decoding" — you run out of hardware
decoders. https://github.com/google/ExoPlayer/issues/273 ·
https://github.com/google/ExoPlayer/issues/11265
Nothing in the RN ecosystem composes a timeline; RN editor apps call out to native modules or
ffmpeg.

###### Electron / Tauri (the web route) — and this is where the interesting precedent is

Three tiers on the web:
1. `HTMLVideoElement` — one source, no frame access, seek is "close enough".
2. **Media Source Extensions** — you feed the browser byte ranges; still one decode pipeline.
3. **WebCodecs** — "enables web developers to encode and decode video and audio in the browser
   efficiently (using hardware acceleration) and with very low-level control (processing on a
   per-frame basis)". Its own stated use cases: "browser-based video and audio editing, as well
   as live-streaming and video conferencing."
   https://developer.mozilla.org/en-US/docs/Web/API/WebCodecs_API ·
   spec: https://www.w3.org/TR/webcodecs/
   A `VideoFrame` is a `CanvasImageSource`, so `drawImage`/`texImage2D` composite it directly —
   the browser hands you the decoded frame and gets out of the way.
   https://developer.chrome.com/docs/web-platform/best-practices/webcodecs

**WebCodecs is the precedent kaya should study, because it is exactly "the toolkit exposed the
platform decoder and let the app composite".** The web platform had had a `<video>` element for
a decade and it was not enough for editors; the fix was not "add a timeline element", it was
"expose the decoder and the frame".

Real editors that took it:
- **Clipchamp** (Microsoft's web editor). Its CTO's W3C Media Production Workshop talk describes
  the pre-WebCodecs pipeline as **WebAssembly-compiled FFmpeg** with a decoder → compositor →
  encoder chain, the pain being "Memory is scarce still. Performance is equally important. Video
  encoding is expensive if you use software encoding paradigm, as we, for the longest time have
  done", and the fix as building "codec stubs, inside FFmpeg" that call the WebCodecs encoder, so
  "We now also have access to the circuitry that's devoted to hardware accelerated video and audio
  decoding and encoding."
  https://www.w3.org/2021/03/media-production-workshop/talks/soeren-balko-clipchamp-webcodecs.html
- **Descript**: "Back in 2018, we built Descript as an Electron application" with "native C/C++
  libraries like FFMPEG/libav"; then spent ~4 years on a new media engine for web + desktop —
  "To make Descript work in browsers, we had to remove those dependencies on native libraries and
  rebuild key pieces of our media engine from the ground up" — landing on WebCodecs for its
  "zero-copy interface between hardware video decoders/encoders and WebGL/WebGPU", with audio
  still decoded in WebAssembly because browser audio-codec support is uneven.
  https://www.descript.com/blog/article/the-new-descript-how-we-multiplied-the-apps-speed-and-performance

Note what BOTH of them did: they wrote their own compositor. Neither asked the platform to
compose a timeline. They asked for decoded frames.

###### Qt — the closest analogue to what kaya would be building, and its trajectory is the warning

Qt Multimedia's shape is exactly the "toolkit hands the app the decoded frame" design:
- `QVideoSink` is "a generic sink for video data"; it emits `videoFrameChanged`, and "the video
  frame can then be used to read out the data of those frames and handle them further". You
  install your own with `QMediaPlayer::setVideoSink`. https://doc.qt.io/qt-6/qvideosink.html
- `QVideoFrame` is the frame handle. `map()` "maps the video frame contents to system (CPU
  addressable) memory" and the doc warns: "In some cases the video frame data might be stored in
  video memory or otherwise inaccessible memory, so it is necessary to map a frame before
  accessing the pixel data" and **"This may involve copying the contents around, so avoid mapping
  and unmapping unless required."** `handleType()` returns `RhiTextureHandle` when the frame lives
  in GPU memory behind Qt's RHI (OpenGL/Vulkan/Metal/D3D), or `NoHandle` when it is already CPU
  memory. Also: "QVideoFrame objects can consume a significant amount of memory or system
  resources and should not be held for longer than required by the application."
  https://doc.qt.io/qt-6/qvideoframe.html
- `QGraphicsVideoItem` is the scene-graph presentation of the same:
  https://doc.qt.io/qt-6/qgraphicsvideoitem.html

**Now the important part for kaya.** Qt originally implemented this on FOUR native backends —
"gstreamer on Linux, AVFoundation on macOS, WMF on Windows, and the MediaCodec framework on
Android, were the default in 6.4". Qt has since reversed that:

- "The FFmpeg media backend is the default backend except on WebAssembly, native backends are
  still available but with limited support."
- "The Windows media backend built on top of Windows Media Foundation is deprecated as of Qt 6.10
  and will be removed in the next major release."
- "MediaCodec on Android is deprecated as of Qt 6.8 and will be removed in the next major release."
- "New features will only be implemented on the FFmpeg media backend, with the exception of
  WebAssembly."
- Qt ships FFmpeg 7.1.3 binaries with the installer.

https://doc.qt.io/qt-6/qtmultimedia-index.html ·
https://doc.qt.io/qt-6/qtmultimedia-building-from-source.html

That is the single most decision-relevant fact in this report. **The one big cross-platform
toolkit that tried to unify four native media stacks behind one frame API gave up and now ships
FFmpeg on every desktop platform**, keeping the native backends only as limited-support
alternatives. Whatever kaya decides, it should decide it knowing that.
##### A4. The minimal "render the timeline at its playhead" pipeline

If kaya owns the pipeline, this is the whole of it. Five steps, and the difficulty is not evenly
spread.

**(i) Find the clip(s) under the playhead.** Pure data structure work: an interval lookup over
each track, plus overlap detection for transitions. Cheap; this is the part the app owns anyway.
MLT's model is the reference shape: a `playlist` is a track (sequential), a `tractor` is the
multitrack (parallel), and both are themselves producers.
https://github.com/KDE/kdenlive/blob/master/dev-docs/mlt-intro.md

**(ii) Decode/seek those clips.** Each visible clip needs a decoder positioned at the right
source time. This is where the platform APIs live: `AVAssetReader` / `AVPlayerItemVideoOutput`,
`MediaCodec` + `MediaExtractor`, `IMFSourceReader`, `GstAppSink`. Note that Media Foundation's
`IMFSourceReader` is explicitly the "give me raw frames without the pipeline" API and it warns
what it does NOT do (quoted in (iv)).
https://learn.microsoft.com/en-us/windows/win32/medfound/source-reader

**(iii) Composite onto a surface.** Blend N frames with per-clip transform/opacity, draw titles
and overlays. On kaya this maps onto the canvas the library already has — but only if the decoded
frame can reach it. Today kaya's canvas is CPU-rasterized by the core and blitted by the backend
(`docs/canvas-plan.md` §1.1, per CLAUDE.md's check-canvas-blit description). A 4K frame at 30fps
through a CPU raster path is 1 GB/s of memcpy before any compositing. That is the collision
point between this feature and the existing canvas architecture, and it is worth naming early.

**(iv) Present at the right wall-clock time.** Frames must reach the display on a clock. The
Source Reader doc is blunt about how much this is NOT free: "The source reader does not send the
data to a destination; it is up to the application to consume the data ... Also, **the source
reader does not manage a presentation clock, handle timing issues, or synchronize video with
audio.**" Its "consider using" list literally includes "Your data-processing tasks are not time
sensitive, or you do not require a presentation clock."
https://learn.microsoft.com/en-us/windows/win32/medfound/source-reader

**(v) Mix and play audio in sync.** And this is the hard one, because **audio is the clock**.
The canonical statement is ffplay's `-sync` option: "Set the master clock to audio (type=audio),
video (type=video) or external (type=ext). **Default is audio.**" and "Most media players use
audio as master clock, but in some cases (streaming or high quality broadcast) it is necessary to
change that." Its `-framedrop` companion: "Drop video frames if video is out of sync. Enabled by
default if the master clock is not set to video."
https://ffmpeg.org/ffplay.html · source: https://ffmpeg.org/doxygen/trunk/ffplay_8c_source.html

What that means concretely: the audio device's consumption rate is the timebase. You keep an
audio ring buffer full, read the device's playback position, compute the presentation time from
it, and *drop or repeat video frames* to match. Video never drives. An editor makes this harder
than a player does, because the audio being played is a MIX of several tracks with gain and fades,
so you own the mixer too, and a scrub or a clip drag must re-seek every decoder and refill the
mix without an audible click.

###### Where the difficulty actually is

1. **A/V sync against a mixed audio clock** (above). This is the classic multi-week item.
2. **Seek latency on long-GOP H.264/HEVC.** A decoder can only start at a keyframe and must decode
   forward to the target. Camera footage with a 1-2 second GOP means a random seek costs dozens of
   decoded frames. This is exactly why editors ship *proxies* and *all-intra* intermediates: at a
   proxy keyframe interval of 72 "scrubbing and playback was stuttery and laggy", at interval 1
   "the playback and scrubbing was as smooth as ProRes 422 Proxy".
   https://community.adobe.com/questions-729/are-h-264-proxy-files-really-that-bad-anymore-1397483
3. **Keeping decode ahead of presentation.** N clips under the playhead = N concurrent decoders,
   and hardware decoders are a finite pool — ExoPlayer's tracker: "each device has limited media
   codecs responsible for video decoding, and the app will crash after all available media codecs
   run out." https://github.com/google/ExoPlayer/issues/273
4. **When even a real engine can't keep up, it pre-renders.** Kdenlive's answer is *timeline
   preview rendering*: "Preview rendering allows you to render parts or your complete timeline in
   the background, so you can smoothly play it back." Their documented example is FullHD footage
   that plays at 25fps raw and drops to **6fps** with four effects applied. Video only — "Kdenlive
   renders audio always independent of the preview rendering" — in 25-frame chunks, and "Any change
   to the video portion covered by the preview render zone triggers a new render pass."
   https://docs.kdenlive.org/en/tips_and_tricks/tips_and_tricks/timeline_preview_rendering.html
   Proxy clips are the other half and solve a different problem — "proxy clips are low-res and
   low-quality variants of the source clips, without any effects applied".
   https://docs.kdenlive.org/en/project_and_asset_management/project_settings/proxy_settings.html

##### A5. The cheaper design: player-per-clip, composition only at export

The shape: keep one platform player per clip (or two, ping-ponged). Seek the next clip's player
while the current one plays, and at the cut point swap which one is visible. The preview shows
hard cuts only. No transitions, no overlays, no PiP, no colour effects, no multi-track audio mix in
the preview. Full fidelity exists **only** in the export, which goes through ffmpeg or the
platform exporter (`AVAssetExportSession`, `media3 Transformer`, `MediaComposition.RenderToFileAsync`,
GES + encodebin).

**Who ships something like this:** the whole Flutter/React-Native tier does, by omission —
`video_editor` previews one `video_player` with a crop rectangle drawn over it and emits an ffmpeg
command for export (https://pub.dev/packages/video_editor). Mobile "trim and stitch" editors are
overwhelmingly this: single-clip preview, real composition deferred. On Android before Media3
1.9.0 (Dec 2025) there was no supported composed-preview API at all, so every Android editor of
the last decade either did this or wrote its own GL compositor.

**What the user loses:** the thing an NLE exists for. They cannot see a crossfade, cannot judge a
title's position or timing, cannot balance two audio tracks by ear, cannot see a speed ramp, and
cannot trust that what they see is what they get. Every edit that involves more than one clip at
once becomes "export and check".

**What it costs you technically:** less than it sounds, but not nothing. Player instances are
expensive to create and hardware decoders are finite (see A4/3), the swap at the cut is visible
unless you pre-roll and pause the incoming player on the exact frame, and gapless audio across the
swap is its own problem.

**Honest assessment for kaya:** as a *forcing app*, the swap design forces almost nothing. It
exercises "put a platform video view in a kaya layout and show/hide it", which kaya can nearly do
today. The interesting pressure — a real decoded frame reaching kaya's canvas, a presentation
clock, per-frame invalidation at 30-60Hz driven by something other than user input — only appears
in the full pipeline or in the platform-composition route.
#### B. Thumbnails and waveforms

### §3.2 What real cross-platform editors are built with
#### C. What real cross-platform editors are actually built with

| Editor | UI toolkit | Media engine | Codecs | Audio out |
| --- | --- | --- | --- | --- |
| **Shotcut** | Qt 6 (6.4 min), QML/Quick | **MLT** | FFmpeg | **SDL** |
| **Kdenlive** | Qt + KDE Frameworks 6, C++ | **MLT** | FFmpeg (via MLT) | via MLT |
| **Olive** | Qt | own node graph + renderer | FFmpeg ≥ 3.0 | **PortAudio** |
| **Pitivi** | GTK (Python) | **GES** (GStreamer Editing Services) | GStreamer | GStreamer |
| **Descript** | Electron → now web + desktop | own media engine | FFmpeg/libav → **WebCodecs** + WASM audio | browser |
| **Clipchamp** (MS) | web (PWA) | own compositor | WASM FFmpeg + **WebCodecs** | browser |
| **Screen Studio** | Electron / TypeScript | (recording core in Swift) | — | — |
| **CapCut** (ByteDance) | Qt on desktop (see caveat) | proprietary | proprietary | — |

Sources:
- **Shotcut** — repo README: "cross-platform (Qt), open-source (GPLv3) video editor", built on
  Qt 6 (6.4 minimum), MLT, FFmpeg, **SDL for cross-platform audio playback**, frei0r, FFTW.
  https://github.com/mltframework/shotcut · https://www.shotcut.org/
- **Kdenlive** — repo README: "Kdenlive is written in C++ and is using these technologies and
  frameworks: Core Framework: MLT for video editing functionality; GUI Framework: Qt and KDE
  Frameworks 6; Additional Libraries: frei0r (video effects), LADSPA (audio effects)".
  https://github.com/KDE/kdenlive · MLT wrapping detail:
  https://github.com/KDE/kdenlive/blob/master/dev-docs/mlt-intro.md
- **Olive** — "a free non-linear video editor for Windows, macOS, and Linux ... alpha software and
  is considered highly unstable" (https://github.com/olive-editor/olive). Its CMakeLists.txt asks
  for Qt, `find_package(FFMPEG 3.0 REQUIRED COMPONENTS avutil avcodec avformat avfilter swscale
  swresample)`, `OpenColorIO 2.1.1`, `OpenImageIO 2.1.12`, `OpenEXR`, `OpenTimelineIO`, and
  **`PortAudio`**.
  https://raw.githubusercontent.com/olive-editor/olive/master/CMakeLists.txt
- **Pitivi** — "a video editor built upon the GStreamer Editing Services", GTK, Python.
  https://gitlab.gnome.org/GNOME/pitivi
- **Descript** — "Back in 2018, we built Descript as an Electron application" with "native C/C++
  libraries like FFMPEG/libav"; ~4 years rebuilding the media engine so it runs in a browser too;
  now on WebCodecs ("zero-copy interface between hardware video decoders/encoders and
  WebGL/WebGPU") with WebAssembly audio decode.
  https://www.descript.com/blog/article/the-new-descript-how-we-multiplied-the-apps-speed-and-performance
- **Clipchamp** — fully in-browser pipeline (decoder → compositor → encoder), originally
  WASM-compiled FFmpeg, now with WebCodecs stubs inside FFmpeg for hardware encode/decode.
  https://www.w3.org/2021/03/media-production-workshop/talks/soeren-balko-clipchamp-webcodecs.html
- **Screen Studio** — its founder: "Screen Studio is an Electron app made with web technologies",
  with the recording core in Swift. https://x.com/pie6k/status/1624535267401924611
- **CapCut** — ByteDance; mobile, desktop and web. **Caveat: I could not find a primary source for
  its stack.** Wikipedia categorizes it as Qt software but the article body documents nothing
  technical. Treat as unverified. https://en.wikipedia.org/wiki/CapCut

###### The pattern in that table

Two things jump out.

1. **Nobody in the native-desktop column asked a UI toolkit for media.** Every one of them either
   adopted a dedicated NLE engine (MLT, GES) or wrote their own on FFmpeg. Qt is present in four
   rows and is the *widget* layer in all four; QtMultimedia does not appear once. Shotcut even
   reaches past Qt for audio output and links SDL. Olive links PortAudio. That is four independent
   teams concluding that the toolkit's media layer is not the right dependency for an editor.
2. **The web column wrote its own compositor on top of an exposed decoder.** Descript and Clipchamp
   both did the same thing: get frames from a hardware decoder, composite yourself. That is the
   design that most resembles "kaya gives the app the decoded frame".

Also worth noting: even Remotion, the programmatic-video project furthest into WebCodecs, has
labelled its `@remotion/webcodecs` package "🚧 Unstable API Warning" and is moving to a separate
media library (Mediabunny). https://www.remotion.dev/docs/webcodecs

#### Synthesis: the four routes, priced

**Route 1 — Wrap each platform's composition engine.** AVComposition / MediaComposition /
CompositionPlayer / GES. Highest fidelity per unit of kaya code; playback, sync, mixing and
scrubbing are the platform's problem. The cost is invariant 1: four engines with four capability
sets, four transition models, four codec-support matrices, one of them experimental (Android) and
one of them not really "the platform" (GES is a library kaya would ship). Divergences would have to
be carved out explicitly, which is a maintainer ruling, not an implementation detail.

**Route 2 — Own the pipeline: expose the decoded frame, composite on kaya's canvas.** The
WebCodecs/Qt-QVideoSink shape. Uniform semantics by construction, and the most *interesting*
forcing app — it forces a frame-clocked render path, GPU-backed canvas content, and a presentation
clock, none of which kaya has. The cost is that you now own A/V sync against an audio clock, seek
scheduling, decoder lifetime, and pixel-format/colour handling on five backends — and Qt, which
tried exactly this with four native backends, retreated to shipping FFmpeg everywhere.

**Route 3 — Player-only, swap at cuts, fidelity at export.** Cheap, ships fast, and is what the
Flutter/RN ecosystem does. Forces very little in kaya; the user cannot see a transition.

**Route 4 — Split the feature at its natural joint.** Import-time extraction (thumbnails + peaks,
cached) gives the ENTIRE timeline — filmstrips, waveforms, drag, trim, zoom, playhead, sliders —
drawn on kaya's existing canvas with zero decoding, and that alone is a heavy, honest forcing app
for virtualization, canvas throughput, gestures and scroll. Preview is then a separate decision
that can take Route 1, 2 or 3 without redoing the timeline. This is the sequencing kaya's own
"depth then breadth" rule would suggest, and it is also how the real editors are layered: MLT's
producers/consumers and Kdenlive's cached audio thumbnails are different subsystems.

One number to hold onto while deciding: kaya's canvas is CPU-rasterized in the core and blitted by
each backend, deliberately (check-canvas-blit's rule, "KAYA RASTERIZES, BACKENDS BLIT"). Video at
30fps is the first workload that argues with that rule, and Route 2 would force the argument
immediately. Routes 1 and 4 do not.

#### Addenda / verified quotes

- **AVComposition is playable because it IS an asset.** Apple's abstract: "An object that combines
  and arranges media from multiple assets into a single composite asset **that you can play or
  process**." Inherits From: `AVAsset`. Overview: "A composition is a container for one or more
  tracks of media. Its tracks are instances of AVCompositionTrack that present media of a uniform
  type like audio or video. A track itself is a container for one or more segments of media, which
  are instances of AVCompositionTrackSegment, a type that represents a region of media in the
  source track." https://developer.apple.com/documentation/avfoundation/avcomposition
  This is the whole reason the Apple route is free: anything that takes an `AVAsset` takes a
  composition, so `AVPlayerItem(asset:)` → `AVPlayer` plays the timeline.

- **MLT's network shape, from its own docs:** "A service is the collective name for producers,
  filters, transitions and consumers." and "The general structure of an MLT 'network' is simply
  the connection of a 'producer' to a 'consumer'."
  https://mltframework.org/docs/framework/

- **media3 CompositionPlayer, from the source, verbatim:**
  "A `Player` implementation that plays `compositions` of media assets. The `Composition` specifies
  how the assets should be arranged, and the audio and video effects to apply to them." …
  "`CompositionPlayer` instances must be accessed from a single application thread." …
  "This player only supports setting the repeat mode as all of the `Composition`, or off."
  Annotated `@ExperimentalApi // TODO: b/470355043 - Publish CompositionPlayer.`
  https://github.com/androidx/media/blob/release/libraries/transformer/src/main/java/androidx/media3/transformer/CompositionPlayer.java

- **The Media Foundation sentence that prices "own the pipeline":** "The source reader does not
  send the data to a destination; it is up to the application to consume the data. For example,
  the source reader can read a video file, but it will not render the video to the screen. Also,
  the source reader does not manage a presentation clock, handle timing issues, or synchronize
  video with audio."
  https://learn.microsoft.com/en-us/windows/win32/medfound/source-reader

- **Qt's retreat, verbatim:** "The FFmpeg media backend is the default backend except on
  WebAssembly, native backends are still available but with limited support." / "The Windows media
  backend built on top of Windows Media Foundation is deprecated as of Qt 6.10 and will be removed
  in the next major release." / "MediaCodec on Android is deprecated as of Qt 6.8 and will be
  removed in the next major release." / "New features will only be implemented on the FFmpeg media
  backend, with the exception of WebAssembly."
  https://doc.qt.io/qt-6/qtmultimedia-index.html

- **ffplay, verbatim:** "-sync type — Set the master clock to audio (type=audio), video
  (type=video) or external (type=ext). Default is audio. ... Most media players use audio as master
  clock, but in some cases (streaming or high quality broadcast) it is necessary to change that."
  "-framedrop — Drop video frames if video is out of sync. Enabled by default if the master clock
  is not set to video." https://ffmpeg.org/ffplay.html

### §3.3 What this means for kaya

The distinction that decides the milestone is the one every editor already
names: a CLIP monitor plays one file, a PROGRAM monitor plays the edit. Only
the second needs anything kaya does not already have a route to, and the
second is where every project in this space reached past its UI toolkit —
Shotcut and Kdenlive to MLT, Pitivi to GES, Olive to FFmpeg, Descript and
Clipchamp to their own WebCodecs compositors. Two of them link SDL or
PortAudio rather than use their toolkit's audio.

All four platforms do have a composed-timeline API, and they are not equally
real: Apple's `AVComposition` is mature and plays through an ordinary
`AVPlayerItem`; Windows' `MediaComposition` is stable but coarse; Android's
media3 `CompositionPlayer` is `@ExperimentalApi`, first shipped December
2025, with open freeze and deadlock bugs; Linux's is GES, a library kaya
would ship rather than "the platform". Four APIs that disagree on
frame-exactness, seek behaviour and which effects exist is the opposite of
what invariant 1 asks for.

The practical reading: **a cut-between-players timeline is the right scope,
and it is a genuinely demanding forcing app for kaya** — a video kind on five
backends, its props and occurrences through nine bindings, its harness
observables, drag and drop on a timeline, sliders driving a model at
interactive rates, offline media extraction through the asset system. A
composed preview forces mostly non-kaya work: a decoder abstraction, a
compositor, an audio clock, A/V sync. If the point is to grow the library,
the cheaper option is also the better forcing function.

One thing to be honest about in the plan: the hard part of owning a preview
pipeline is not decoding, it is the CLOCK. ffplay's default master clock is
audio, and Media Foundation's Source Reader states the bill outright — "the
source reader does not manage a presentation clock, handle timing issues, or
synchronize video with audio." That is the work kaya would be signing up for,
and it lands squarely on the audio milestone kaya has designed and not built.

---

## §4 — Thumbnails and waveforms
##### B6. Frame extraction for the filmstrip

Every platform ships a "give me a still at time T" API. None of them requires the app to own a
decoder, and all of them are one call.

###### Apple — `AVAssetImageGenerator`

"An object that generates images from a video asset. Use an image generator to extract images from
a video asset at particular times within its timeline."
https://developer.apple.com/documentation/avfoundation/avassetimagegenerator

- Batch API: `generateCGImagesAsynchronously(forTimes:completionHandler:)` — "Generates images
  asynchronously for an array of requested times, and returns the results in a callback."
  Modern async replacement: `images(for:)`, returning an `AVAssetImageGenerator.Images` async
  sequence. https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/images(for:)
- **The performance knob is the tolerance pair.** `requestedTimeToleranceBefore` is "A maximum
  length of time before the requested time to allow image generation to occur";
  `requestedTimeToleranceAfter` is the same after. Leave them at their default
  (`CMTime.positiveInfinity`) and the generator returns the nearest **keyframe**, which is nearly
  free. Set both to `.zero` and it must decode forward from the previous keyframe to the exact
  frame — this is the difference between a filmstrip that populates instantly and one that takes
  seconds per thumbnail on long-GOP footage.
  https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/requestedtimetolerancebefore
- `maximumSize` — decode/scale down at generation time rather than after.
  `appliesPreferredTrackTransform` — "specifies whether to apply the track matrix or matrices when
  generating an image", i.e. honour the rotation metadata a phone recording carries. Forgetting
  this is the classic sideways-filmstrip bug.
- **Cost model:** with tolerance = infinity, one keyframe decode per thumbnail. With tolerance = 0,
  one GOP of decoding per thumbnail. A filmstrip should use the loose tolerance; only the playhead
  needs exactness.

###### Android — three tiers

1. `ThumbnailUtils.createVideoThumbnail(File, Size, CancellationSignal)` — the recommendation when
   you have a file path.
2. `MediaMetadataRetriever`: check `embeddedPicture` first (all API levels); on API 28+ use
   **`getScaledFrameAtTime(timeUs, option, width, height)`** rather than `getFrameAtTime` — the
   platform doc's own guidance: "If you don't need a full-resolution frame (for example, because
   you need a thumbnail image), use `getScaledFrameAtTime()` instead of `getFrameAtTime()`."
   `OPTION_PREVIOUS_SYNC` is the keyframe-tolerance equivalent of Apple's tolerance knob.
   `getFramesAtIndex(frameIndex, numFrames)` (API 28+) pulls **consecutive** frames, which is what
   a filmstrip actually wants.
   https://developer.android.com/social-and-messaging/guides/media-thumbnails ·
   https://developer.android.com/reference/android/media/MediaMetadataRetriever
3. **media3 `FrameExtractor`** — the new and best-fitting one. It "provides an efficient way to
   extract decoded frames from a MediaItem", and its documented use cases name ours exactly:
   "Displaying precise frame previews in an editor timeline, allowing users to seek through the
   content and visualize frames accurately", plus "Scaling, cropping, or rotation directly during
   extraction, avoiding a separate post-processing step". `getFrame(long)` / `getThumbnail()`
   return `ListenableFuture<FrameExtractor.Frame>`; "the complex decoding work doesn't block the
   main thread"; instances "must be accessed from a single application thread".
   https://developer.android.com/media/media3/inspector/extract-frames

###### Linux / GStreamer

No single call; the documented recipe is a pipeline plus a seek. GStreamer's own application
development manual has the snapshot example: build `playbin`/`decodebin` → `appsink`, seek to the
target (their example seeks to 5% in "to avoid capturing a black first frame"), then "get the
preroll buffer from appsink" via `pull-preroll`, read the caps for dimensions, and map the buffer.
https://gstreamer.freedesktop.org/documentation/application-development/advanced/pipeline-manipulation.html
Reference implementation: `gst-plugins-base/gst/playback/gstscreenshot.c`, and the
`gst_video_convert_sample()` helper for converting the pulled sample into the pixel format you
want. https://gstreamer.freedesktop.org/documentation/video/gstvideoutils.html
Higher up, GES clip assets carry thumbnailing, and Pitivi's `previewers.py` is the working example
of a GTK filmstrip. https://gitlab.gnome.org/GNOME/pitivi

###### Windows — two routes

1. **`MediaComposition.GetThumbnailAsync` / `GetThumbnailsAsync`** — thumbnails **of the
   composition**, not of a source file, which is a nice extra: "Asynchronously gets a vector view
   of thumbnails of the media composition", taking `timesFromStart` (an iterable of `TimeSpan`
   offsets from the composition's start), `scaledWidth`, `scaledHeight` and a `VideoFramePrecision`
   ("the frame precision algorithm to use") — precision being Windows' version of Apple's
   tolerance. Aspect ratio is preserved if you give only one dimension.
   https://learn.microsoft.com/en-us/uwp/api/windows.media.editing.mediacomposition.getthumbnailsasync
   **Known bug, worth knowing before betting on it:** GetThumbnailsAsync returning the same
   (first) thumbnail regardless of timestamps, with the workaround being N calls to
   `GetThumbnailAsync` at "around 4-5 times slower".
   https://github.com/microsoft/WindowsAppSDK/issues/5049 ·
   https://github.com/MicrosoftDocs/winrt-api/issues/1173
2. **Media Foundation `IMFSourceReader`** — seek with `SetCurrentPosition`, pull with
   `ReadSample`. "If the media source delivers compressed data, you can use the source reader to
   decode the data ... The source reader can also perform some limited video processing: color
   conversion from YUV to RGB-32". Explicitly *not* a player: "the source reader does not manage a
   presentation clock, handle timing issues, or synchronize video with audio" — which is exactly
   right for thumbnails and exactly wrong for preview.
   https://learn.microsoft.com/en-us/windows/win32/medfound/source-reader

###### Cost summary

| Platform | Filmstrip API | Tolerance knob | Notes |
| --- | --- | --- | --- |
| Apple | AVAssetImageGenerator.images(for:) | requestedTimeTolerance{Before,After} | set maximumSize; appliesPreferredTrackTransform |
| Android | media3 FrameExtractor (or getScaledFrameAtTime) | OPTION_PREVIOUS_SYNC vs CLOSEST | single-thread affinity; scale during extraction |
| Linux | appsink + seek + pull-preroll | seek flags (KEY_UNIT vs ACCURATE) | you assemble the pipeline |
| Windows | MediaComposition.GetThumbnailsAsync, or IMFSourceReader | VideoFramePrecision | batch call has an open correctness bug |

##### B7. Audio waveform extraction

The universal method, unchanged for 25 years: **decode the audio once, reduce to min/max (or RMS)
pairs per bucket of N samples, cache the result, and draw the cache.**

The reference implementation is BBC R&D's **`audiowaveform`** (C++, github.com/bbc/audiowaveform).
It "combines input channels into mono, then computes minimum and maximum sample values over groups
of N input samples", where N is the zoom (default 256 samples per point, or specify pixels-per-second,
default 100). Output is 8-bit or 16-bit. https://github.com/bbc/audiowaveform

The `.dat` format is documented and stable — this is the closest thing to a standard peaks file:
little-endian, header of `version`, `flags` (bit 0: 0 = 16-bit, 1 = 8-bit), `sample_rate`,
`samples_per_pixel` ("Number of audio samples per waveform minimum/maximum pair"), `length`
("number of minimum and maximum value pairs per channel"), plus `channels` in version 2; then
interleaved min/max pairs to EOF. 8-bit values are -128..127, 16-bit -32768..32767. A JSON form
carries the same fields (`version`, `channels`, `sample_rate`, `samples_per_pixel`, `bits`,
`length`, `data`).
https://github.com/bbc/audiowaveform/blob/master/doc/DataFormat.md

**Is it a standard?** No formal standard, but it is a de-facto one: it is the format **peaks.js**
(also BBC) consumes, and peaks.js is the widely used browser waveform component. Its README makes
the caching argument for us: precomputed data "saves your users' bandwidth and allows the waveform
to be rendered faster", while the Web Audio route "requires downloading the entire audio file to
the browser and is CPU intensive" and suits short files only.
https://github.com/bbc/peaks.js
The other browser component, wavesurfer.js, takes the same two routes (decode in-browser, or feed
it a precomputed `peaks` array). https://wavesurfer.xyz/docs/

Desktop editors do the identical thing under a different name: Kdenlive calls them **audio
thumbnails** and caches them per project (they live in the project's cache folder and are
regenerated if deleted).
https://docs.kdenlive.org/en/project_and_asset_management/project_settings/cache.html

**One design note that matters for kaya:** min/max is not RMS. Min/max preserves transients and is
what editors draw (you can see a click); RMS is smoother and is what loudness meters use. Store
min/max at a fine bucket and derive coarser zooms by taking min-of-mins and max-of-maxes — that is
a pure reduction over the cached array and needs no re-decode, so zooming a waveform costs nothing.

##### B8. Is an offline extraction step at import enough for the TIMELINE?

**Yes — completely, for the timeline surface itself. And this is the part kaya can build with what
it already has.**

At import, per source file: extract N thumbnails at a fixed cadence (say one per second, plus a
denser pass around the in/out points) and one peaks file. Cache both keyed by (file identity,
size, mtime). After that, the timeline is:

- clip rectangles → kaya rects
- filmstrip → tiled bitmaps drawn on kaya's canvas
- waveform → a polyline/bar chart from the min/max array on kaya's canvas
- playhead, ruler, zoom, snapping → arithmetic
- drag, trim handles, sliders → kaya's existing gesture and widget surfaces

**Zero video decoding while the user edits.** Dragging a clip, trimming with a slider, zooming
the timeline, scrolling, changing volume — none of it touches a decoder. Thumbnails re-tile by
picking different cached images; the waveform re-buckets by reducing the cached array. This is
exactly the load kaya's canvas was built for, and it is a genuinely demanding forcing app on its
own: hundreds of images on a scrolling, zooming, virtualized surface with hit-testing and drag,
which stresses virtualization, canvas throughput, gesture routing and scroll — all things kaya has
and would be pushed hard by.

**What it does NOT cover — and this is the honest boundary:**

1. **Scrubbing the preview.** Dragging the playhead demands a frame at an arbitrary time, now.
   Cached thumbnails are one-per-second; scrubbing wants ~every frame. (A trick real editors use:
   scrub against the cached filmstrip and only decode when the playhead settles. That degrades
   gracefully and is worth doing regardless.)
2. **Playback.** Obviously. A/V sync, presentation clock, audio mixing — all of A4.
3. **Any composed observation.** A crossfade, an overlay, a colour effect: no cached thumbnail can
   show it.
4. **Audio scrub/preview.** Waveform drawing needs no audio device; hearing the clip does.
5. **Freshness.** Trim in, trim out and speed change the mapping from timeline x to source time,
   so the filmstrip must re-tile from the cache (cheap) — but a source file replaced on disk
   invalidates the cache entirely.

So: the import-time extraction step buys the ENTIRE timeline widget and buys it cheaply. It does
not buy the preview monitor, which is the requirement the maintainer stated. The two are cleanly
separable, and could ship in that order.

### §4.1 What this means for kaya

This is the cheapest and most certain part of the whole report: **an
import-time extraction step buys the entire timeline widget.** Every platform
has a one-call still extractor with a tolerance knob — Apple's
`AVAssetImageGenerator` (with the two default-value traps: the time
tolerances default to infinity, and `appliesPreferredTrackTransform` defaults
false, so portrait video comes back sideways), Android's media3
`FrameExtractor` whose documented use case is literally editor-timeline frame
previews, a GStreamer appsink seek plus `pull-preroll` on Linux, and
`MediaComposition.GetThumbnailsAsync` on Windows. Waveforms are a solved,
boring problem: decode once, take min and max per bucket, cache — BBC's
`audiowaveform` `.dat` format is the de-facto standard, and Kdenlive calls
the same thing "audio thumbnails" and caches per project.

With thumbnails and a peaks file cached at import, the timeline — filmstrips,
waveforms, dragging, trimming, zooming, the playhead — is drawn entirely with
kaya's existing canvas ops and existing widgets, with **no video decoding at
all while the user edits**. It does not buy scrubbing the preview, playback,
or any composed observation, but those are cleanly separable and can ship
after.

The one gap on kaya's side, from §3.0: **the canvas has no image op**, so a
filmstrip is either N `image` widgets laid out in a row (which works today
and is the wrap-native answer) or a new `draw_image` op — a spec change
through eight bindings and three interpreter copies. Worth deciding early,
because it changes what the timeline is made of.

---
## §5 — Decisions the maintainer must make

Each ruling states the mechanism in plain words, then the options, then a
recommendation. The evidence is in §0-§4.

### D1 — Platform player first, or straight to owned rendering?

**The mechanism.** Two routes put moving pictures on screen. In the FIRST,
kaya declares a `video` widget and each backend hands the file to the
operating system's own player — AVPlayer on Apple, ExoPlayer on Android,
GtkMediaFile (or a GStreamer pipeline, D7) on Linux, MediaPlayer on
Windows. Those players own the
decoder, the audio, the clock and the sync; kaya sends play/pause/seek and
reads back position and state. In the SECOND, kaya decodes the video itself
in the Rust core and puts each frame on screen through a surface it manages,
which means kaya also owns audio output and A/V sync, because sync is driven
by the audio clock.

**Options.**
- (a) Ship the `video` kind over each platform's player; treat owned
  rendering as a separate, later milestone with its own forcing app.
- (b) Skip the player and build owned rendering now.
- (c) Build both at once — the player for the media bin, owned rendering
  for the timeline preview.

**Recommendation: (a).** Five independent reasons, none of which is
"it is easier".

1. It is already the tree's own recommendation (docs/deferred.md's Video
   widget entry) and the tree ruled 2026-08-26 that video belongs to the
   IMAGE widget's high-rate path, not to the canvas.
2. The closest peer toolkit shipped exactly this (.NET MAUI's MediaElement
   over ExoPlayer/AVPlayer/MediaPlayer) and its API surface is a ready
   template.
3. The peer toolkit that owns its rasterizer (Avalonia) still has no video,
   and its maintainer's answer is native embedding per platform — so owning
   the renderer buys nothing here.
4. The player carries the AUDIO, which kaya has designed and not built. Route
   (b) silently makes this the audio milestone as well.
5. The editor's first honest deliverable — a media bin that previews a
   single file, plus a timeline drawn from cached thumbnails and waveforms —
   needs nothing more than a player.

The cost of (a) is that a COMPOSED timeline preview (a cut between two
clips, a crossfade, a title overlay) is not expressible; see D3.

### D2 — If the player route is taken, what is the `video` kind's surface?

**Recommendation:** copy MAUI's shape, minus the parts that are not uniform.
Props: `source` (an asset name or a picked-file handle — **a PATH, never a
stream**: Windows has `MediaSource.CreateFromStream` but AVFoundation has no
file-descriptor or in-memory initializer at all, so a stream source would be
a per-platform shim for one platform's convenience), `autoplay`, `loop`,
`muted`, `volume`, `speed`, `aspect`. Commands: `play`, `pause`, `stop`,
`seek(ms)`. Mirrors the app reads: `position`, `duration`, `state`,
`media_width`/`media_height`. Occurrences: `ended`, `failed`,
`seek_completed`. NO platform transport controls — the editor draws its own
scrubber, the platform chrome is non-uniform anyway, and on Apple the
chrome-free route is `AVPlayerLayer` (SwiftUI's `VideoPlayer` **cannot** hide
its controls) while on Windows it is
`MediaPlayerElement.AreTransportControlsEnabled = false`.

**Three sub-rulings this surface forces, each recorded because it is a
uniformity question and invariant 1 owns those:**

- **The codec floor.** Taking the intersection of what every target decodes
  with no extra install leaves essentially **H.264 in MP4 with AAC audio**.
  Apple cannot play VP9 or WebM/MKV at all; Windows plays VP9 and MKV in-box
  but needs a Store extension for HEVC and AV1; Android and GStreamer differ
  again. Either kaya states that floor and refuses above it, or it grows a
  capability query and the app asks. Recommendation: state the floor AND
  ship the query, the way `capabilities`/`aux_windows` already works.
- **"Poster frame" and "every frame" are different features, and on Windows
  the second turns the first off.** `MediaPlayer`'s frame-server mode is
  EXCLUSIVE — Microsoft's own remarks say "the media player does not render
  video content" — while Apple's `AVPlayerItemVideoOutput` is ADDITIVE (the
  player keeps drawing). That is a real semantic divergence, so per
  invariant 1 the uniform answer is: kaya exposes a poster/thumbnail
  extraction that is a separate call against a file, and does NOT expose
  "give me the currently playing frame" at all in v1.
- **Chrome ownership drags system integration with it.** Turning off the
  platform transport controls also turns off what those controls were wired
  to — Now Playing / lock-screen metadata on Apple, `DisplayRequest`
  (keep-awake) on Windows, the media notification on Android. MAUI's answer
  is explicit props (`MetadataTitle`, `ShouldKeepScreenOn`); kaya needs the
  same or it ships a player whose screen sleeps mid-playback.

### D3 — Does the milestone promise a composed timeline preview?

**The mechanism.** A media-bin preview shows one file; a timeline preview
shows the EDIT — the clip under the playhead, the transition when two
overlap, the title on top, the audio mixed. A single-file player cannot show
an edit. The middle route is that some platforms can play a composed
timeline natively (Apple's AVComposition/AVVideoComposition is the mature
one); see §3 for whether the other three have an equivalent.

**All four platforms DO have a composed-timeline API, but they are not
equally real** (§3 has the URLs): Apple's `AVComposition` +
`AVVideoComposition` is mature and plays through an ordinary `AVPlayerItem`;
Windows' `Windows.Media.Editing.MediaComposition` is stable but coarse (you
regenerate the stream source after every edit, MP4 only); Android's media3
`CompositionPlayer` is `@ExperimentalApi`, first shipped 1.9.0 in December
2025, with open freeze and deadlock bugs; and Linux's is GES, which is a
GStreamer library kaya would ship rather than "the platform". Four APIs that
"will not agree on frame-exactness, seek behaviour, or which effects exist"
is the opposite of what invariant 1 asks for.

**And the pattern across every editor ever shipped points the same way.**
Shotcut and Kdenlive both reach past Qt to MLT; Pitivi reaches past GTK to
GES; Olive reaches past Qt to FFmpeg; two of them even link SDL or PortAudio
rather than use their toolkit's audio. Descript and Clipchamp wrote their own
compositor over WebCodecs. **Nobody asked a UI toolkit to compose a
timeline** — the media engine is a separate project in every case.

**Options.**
- (a) The editor previews the SOURCE clip only; the composed result exists
  only in the exported file.
- (b) The editor cuts between players — one player per clip, swap which is
  visible at a cut. Cuts work; transitions, overlays and mixes do not.
- (c) A real composed preview, which needs owned rendering, or four
  platform composition APIs that disagree, or an engine (MLT/GES-class) that
  kaya would be writing.

**Recommendation: (b) for this milestone, with (a) as the honest fallback,
and (c) NOT promised at all.** (b) is what makes it an EDITOR rather than a
player, it forces genuinely new kaya surface (a video kind that can be
swapped, seeked and driven from a timeline model), and it does not require a
frame pipeline. (c) should be named in the plan as what kaya is NOT doing,
with the reason recorded: every editor that has ever shipped got its
composition from a media engine that was not its UI toolkit, and the four
platform composition APIs disagree too much to hide behind one semantics.

**A note on the forcing-app logic.** The maintainer's stated purpose for the
editor is to FORCE library growth. Worth checking what each option actually
forces. (b) forces: a `video` kind on five backends, its props and
occurrences through nine bindings, its harness observables, drag and drop on
a timeline, sliders driving a model at interactive rates, and offline media
extraction plumbed through the asset system. That is a lot of kaya. (c)
forces mostly NON-kaya work — a decoder abstraction, a compositor, an audio
clock, A/V sync — which grows a media engine rather than a GUI library. If
the goal is to grow kaya, (b) is the better forcing function, not merely the
cheaper one.

### D4 — Thumbnails and waveforms: offline at import, or live?

**Recommendation: offline at import, cached, drawn with the canvas.** The
timeline is then pure kaya — filled paths and text over cached data, no
decoder running while the user drags. See §4 for the per-platform extraction
APIs. Note the one gap: the canvas has NO image op, so a thumbnail filmstrip
is either N `image` widgets in a row or a new `draw_image` op (§3.0).

### D5 — If and when owned rendering happens, which decoder route?

**The mechanism.** To decode a video yourself you need code that turns
compressed bytes into frames. Three sources for that code: the operating
system's own decoder (which the OS vendor has already licensed the patents
for), FFmpeg (one implementation everywhere, but you are then distributing a
codec), or patent-free decoders written from scratch.

**Options.**
- (a) **Four platform decoders behind one Rust trait** — VideoToolbox /
  AVAssetReader on Apple, NDK `AMediaCodec` on Android, GStreamer `appsink`
  on Linux, `IMFSourceReader` on Windows.
- (b) **FFmpeg linked into the core** — `ffmpeg-next` or `rsmpeg`.
- (c) **Patent-free only** — `rav1d`/`dav1d` for AV1, and nothing credible
  for H.264/HEVC in pure Rust.

**Recommendation: (a) for a DECODE-ONLY trait, but read Qt's history first,
because Qt built this exact thing and retreated from it.**

**The Qt evidence, which is the most decision-relevant fact in the whole
report.** Qt Multimedia shipped precisely the design under discussion —
`QVideoSink`/`QVideoFrame` handing the application decoded frames, over four
native backends (AVFoundation, MediaCodec, Windows Media Foundation,
GStreamer). Qt has now made **FFmpeg the default backend on every platform**,
deprecated the Windows Media Foundation backend as of 6.10 and the MediaCodec
backend as of 6.8, and states: "New features will only be implemented on the
FFmpeg media backend."
<https://doc.qt.io/qt-6/qtmultimedia-index.html>
That is a toolkit with far more people than kaya has, doing option (a),
concluding after years that option (b) was the maintainable one. Any plan to
build four decoder backends has to answer it.

- **(c) is disqualified by the footage.** A video editor opens the user's own
  files, and phones record H.264 and HEVC. An AV1-only decoder cannot open a
  single clip the user shot. It is a non-answer.
- **(b) has a licensing problem specifically on the platform kaya must ship
  to.** iOS has no user-installable shared libraries, so LGPL 2.1 §6(b) — the
  "ship a DLL next to the exe" escape that makes FFmpeg easy on Windows — is
  unavailable, and §6(a) requires shipping relinkable object files, which a
  code-signed App Store binary defeats. The popular counter-example does not
  hold: VLC is on the App Store because VideoLAN OWNS VLC and can grant
  itself permission, not because LGPL solved anything. Plenty of apps ship
  static LGPL FFmpeg on iOS anyway; that is a risk kaya would be adopting
  knowingly, not a clean path. FFmpeg also brings a real build-system project
  (cross-compiling it for iOS and Android is a from-source recipe, and the
  main prebuilt set, ffmpeg-kit, was retired by its author in 2025).
- **(a) has neither problem.** The OS vendor licensed the codecs; kaya
  distributes no codec, so there is no LGPL obligation and no patent
  exposure. It is also the same decoders the PLAYER route would have used, so
  the codec floor does not move between the two milestones — the app sees the
  same capability either way, which is what invariant 1 wants.
- The cost of (a) is four implementations instead of one — and Qt's retreat
  says that cost compounds over years, not that it is unaffordable up front.
  The honest synthesis: (a) is right for a NARROW trait that only decodes
  frames from a file at a timestamp (which is what thumbnails and a preview
  need), and Qt's retreat is about a FULL media backend — players, cameras,
  capture, encoding, streaming — which is a much larger surface. If kaya's
  trait ever grows past "give me the frame at time t", the Qt outcome is the
  one to expect.
- **Two caveats that cut the other way, and they are strong:**
  - **(a)'s Linux arm is FFmpeg wearing a hat.** GStreamer's software H.264
    decoder IS libavcodec — `avdec_h264` is documented as the "libav h264
    decoder" from the GStreamer FFmpeg plug-ins package. So (a) does not
    avoid FFmpeg on Linux; it moves the licence and patent decision onto the
    distro, which is a legitimate and common answer but is not the same as
    "no FFmpeg". And GStreamer is not in the lane's container today (D7).
  - **On Windows, the platform decoder cannot open an iPhone's default
    recording.** Windows ships no HEVC decoder; it needs a Store extension
    that costs about a dollar and that kaya cannot buy on the user's behalf.
    iPhones have recorded HEVC by default since iOS 11. That is the single
    strongest argument FOR owning decode: route (a) — and the player route
    too — leaves a Windows user unable to open the footage they shot.
  - **And Servo, facing this exact choice, did not build four backends.**
    servo-media has a `Backend` trait whose "only functional backend is
    GStreamer", on every platform, with a full-time multimedia team.
    Firefox, which DID build four, needed ~561 KB of C++ for the Windows
    module alone. Measured against Firefox's tree, a decode-only version of
    (a) for kaya is roughly **8,000-15,000 lines of unsafe FFI across four
    surfaces**, plus five lanes of new legs.
- **One more fact that damages the "hardware decode makes it fast" premise.**
  FFmpeg's own manual: most acceleration methods "are intended for playback
  and will not be faster than software decoding on modern CPUs", and ffmpeg
  "will usually need to copy the decoded frames from the GPU memory into the
  system memory, resulting in further performance loss." Every hardware route
  hands back a GPU surface; kaya's blit architecture wants CPU bytes. **kaya
  pays a readback either way** — unless it stops blitting its own pixels for
  video, which is exactly the architectural exception D8 is about.

### D6 — What may a `video` scene assert?

**Recommendation: semantic observables only** — position, duration, state,
media size, an `ended` occurrence — plus ONE `expect_ink` per lane against a
synthetic flat-colour clip, to prove the frames reached the screen. Reason
in §1.0c: kaya's Apple sampling calls cannot read a hosted player's pixels
at all, and four decoders will never agree byte-for-byte on a real clip.
This also needs a decision about whether the Apple harness grows a second
sampling route, or whether the flat-clip check is Android/GTK/WinUI only
(which would break the byte-shared-scene invariant unless the verb is
written to be uniform).

### D7 — The Linux lane, and which GTK route

**The mechanism.** GTK4's media backend is a separate module over GStreamer;
the lane's container (tools/linux/Dockerfile) installs `libgtk-4-dev` and
`ffmpeg` and NO GStreamer packages at all. So a `video` kind on GTK needs
new packages in the image, or a different backend on Linux.

**Options:** add the GStreamer plugin set to the image; or use
`gtk4paintablesink` and drive playback from Rust through `gstreamer-rs`; or
declare Linux a depth-stub for `video` in the first slice
(tools/check-stubs.py already holds that convention, and it would be
recorded rather than silently absent).

**Recommendation: `gstreamer-rs` + `gtk4paintablesink`, not `GtkMediaFile`.**
The reason is parity, not taste. `GtkMediaStream` has NO playback rate at all
— GTK's own docs point a "full-fledged video player" at "the `GdkPaintable`
API and a media framework such as Gstreamer directly" — so a `video` kind
built on `GtkMediaFile` could not offer `speed`, which the other three
platforms all have, and the uniform surface would have to shrink to GTK's
floor. `gtk4paintablesink` is a maintained GStreamer sink written in Rust
that hands back a `gdk::Paintable` (which drops straight into a `GtkPicture`,
and which kaya's own `KayaCanvas` already accepts as a type), and driving
`playbin3` from Rust gets rate, accurate-versus-keyframe seek flags, track
selection and the bus's EOS and error messages. It is roughly 200 lines of
Rust against 5 for `GtkMediaFile`, and it is the only GTK route that reaches
parity.

Two further Linux facts worth having on the record:
- **`gtk4-media-ffmpeg` is gone** (removed in GTK 4.14, "hasn't been building
  for a year"), so GStreamer is the only GTK media backend. There is no
  second option to fall back to.
- **A missing plugin is an assertable error, not a blank screen**: GTK's
  fallback reports `G_IO_ERROR_NOT_SUPPORTED` with "GTK could not find a
  media module. Check your installation." And Debian's
  `libgtk-4-media-gstreamer` pulls NO plugin sets, so the container needs
  plugins-base and plugins-good named explicitly, plus libav or openh264 if
  the test asset is H.264.
- **Leave `GtkGraphicsOffload` OFF by default.** It is the GTK analogue of
  Android's hole-punching, it is Wayland-only (kaya's lane also runs X11), and
  it is declined SILENTLY when the widget is clipped, rounded, transformed or
  made translucent — a "why is my rounded video square on Wayland only" bug
  with no error anywhere.

### D8 — The architectural exception, stated out loud

**The mechanism.** kaya's canvas rule is "the core rasterizes, backends
blit", and `tools/check-canvas-blit.py` exists to keep any backend from
drawing pixels kaya did not produce. A native player view is the exact
inverse: the platform decodes, the platform composites, and kaya only says
where the rectangle goes. On Android the cheap path is a SurfaceView, which
is not merely "not kaya's pixels" — it is a HOLE punched in the surface kaya
draws into, composited by SurfaceFlinger underneath.

**This is a carve-out, and carve-outs are the maintainer's to make**
(the standing rule: never decide an invariant exception autonomously). It
should be written into DESIGN.md the way the drop-down policy already is,
with its conformance scene named, rather than discovered later by whoever
reads check-canvas-blit.py and finds a widget that ignores it.

**The honest framing:** the rule was written about the CANVAS, and
docs/canvas-plan.md §16 already separates "pixels kaya rasterized" from
"pixels somebody else produced and kaya presents". A video widget is the
second category by construction. So this is arguably not an exception at all
but the §16 split doing its job — which is worth saying explicitly, because
it is the difference between a principled boundary and a hole.

### D9 — Two things to probe before any arm is written

Both are cheap, both are premises the plan rests on, and both are the kind of
thing this repo has been burned by believing instead of measuring.

1. **Can kaya's Compose harness read a SurfaceView-hosted video's pixels?**
   The two readings are in §1.0d. Ten minutes on the emulator settles it, and
   it decides whether Android can assert a video pixel at all.
2. **What does the linux container actually need?** Install the GStreamer
   plugin sets in a scratch image and run `GTK_MEDIA=gstreamer` against a
   test clip — and run `GTK_MEDIA=none` too, because GTK's failure is an
   assertable sentence ("GTK could not find a media module. Check your
   installation.") rather than a silent blank, which makes it a watched
   branch instead of a believed one.

### D10 — The test asset

**Recommendation: a short VP9-in-WebM clip, flat-coloured.** VP9 has been
mandatory on Android since 4.4, decodes on the emulator, and lives in
gst-plugins-good (unencumbered, present in every distro build) — and it
dodges a real emulator defect, `c2.goldfish.hevc.decoder` dying after two or
three loops on virtual devices (androidx/media#2461). The catch is that
**Apple cannot play VP9 or WebM at all**, so the five-lane intersection for
ONE shared asset is still H.264 in MP4. Either the scene carries two assets
and each lane picks, or the asset is H.264/MP4 and the Android emulator's
H.264 path is verified first. This needs a ruling; it is not a detail,
because invariant 6 says the scene is shared byte-for-byte.
