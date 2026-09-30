# Apple (macOS, iOS): the platform's own video view vs kaya's headless frames

Research for kaya, 2026-09-29. Scope: macOS and iOS. Current design under
reconsideration: docs/video-editor-plan.md §2-§3 (headless AVPlayer +
AVPlayerItemVideoOutput feeding the image widget's high-rate path),
docs/canvas-plan.md §16.

Sources are cited inline. "MEASURED" marks a claim read off a probe run on
this Mac (Darwin 25.6.0, macOS 26), probe source in
scratchpad/video-native/probe/ (gone).

Status: complete for the questions asked; the unsettled points are listed
at the end.

## MEASURED: the macOS probe (run 2026-09-29, macOS 26 / Darwin 25.6.0, 2x display)

Probe: scratchpad/video-native/probe/main.swift (gone), compiled with the repo's
`kaya_swiftc` (tools/lib/swift-toolchain.sh). It writes a 2 s 320x240 H.264
MP4 of one flat asymmetric colour (sRGB C83C1E) with AVAssetWriter, opens ONE
non-activated window (`.accessory` policy, `orderFrontRegardless`) holding
four panes on one AVPlayer, pauses after 1.5 s, reads the pixels four ways,
and exits. It photographed only its own window (`screencapture -x -o
-l<windowNumber>`). `pgrep -fl video-native/probe/probe` after each run:
empty ("no probe running"), both runs.

Panes:
- A: an `AVPlayerLayer` sublayer of a layer-backed NSView whose layer has
  `cornerRadius = 50, masksToBounds = true`, inside an `NSScrollView`
  scrolled 40 pt, with a sibling NSView (pure green) added AFTER it,
  overlapping it.
- B: `AVPlayerView` with `controlsStyle = .none`.
- C: SwiftUI `NSHostingView` of `ZStack { NSViewRepresentable(AVPlayerLayer
  host).clipShape(RoundedRectangle(cornerRadius: 50)); Color.green (overlay) }`.
- D: SwiftUI `VideoPlayer(player:)`.

Results (window capture values are in the PNG's own colour space, which
screencapture tagged Display P3; the source colour is sRGB C83C1E):

| read | A (layer, rounded, scrolled, overlaid) | B (AVPlayerView, controls none) | C (SwiftUI rep, clipShape, overlay) | D (SwiftUI VideoPlayer) |
|---|---|---|---|---|
| AVPlayerItemVideoOutput CVPixelBuffer centre | C73B1E (sRGB-ish BGRA; 1 LSB from source) | same player | same | same |
| `NSView.cacheDisplay(in:to:)` of the content view | FFFFFF (the white window ground: no video) | 000000 (the view's black ground: no video) | FFFFFF | 000000 |
| `CALayer.render(in:)` of the root layer | FFFFFF | 000000 | FFFFFF | n/a |
| `screencapture -l<window id>` (window server) | centre BE4E2F (video); corner inside the radius FFFFFF (clipped); overlay 75FB4C (the sibling's green, drawn OVER the video) | centre, bottom edge and corner all BE4E2F: no control chrome at all | centre BE4E2F; corner FFFFFF (clipShape clipped it); overlay 65C466 (SwiftUI's system green) over the video | centre 722F1C, bottom 2C1F1C: the video is DIMMED by VideoPlayer's paused-state control scrim; its controls cannot be turned off by any VideoPlayer API |

What this settles on macOS:
1. `AVPlayerLayer` is composited like any other CALayer: masked by an
   ancestor's rounded `masksToBounds`, by SwiftUI's `clipShape`, drawn over
   by a later sibling, and scrolled inside an NSScrollView (the pane was
   scrolled 40 pt and the clip still rounded at the new position).
2. `AVPlayerView(controlsStyle: .none)` shows no chrome at all.
3. The video pixels are NOT in the process's own snapshots
   (`cacheDisplay`, `CALayer.render(in:)`): both return the ground colour.
   They ARE in a window-server capture of the window by id. So a kaya colour
   check on a native video view must go through the window-server capture
   route kaya's mac recorder already uses (`screencapture -l<id>`), and
   must compare in a stated colour space with a tolerance: the captured
   value is colour-managed (the 709-tagged clip, converted to the
   display's P3), so it is not byte-equal to the source colour (BE4E2F in
   P3 for sRGB C83C1E).
4. `AVPlayerView.updatesNowPlayingInfoCenter` defaults to `true` on macOS
   (read back from a fresh view).

Two smaller probes, same rules (one non-activated window, own pid only,
`pgrep` empty afterwards):

- probe2 (scratchpad/video-native/probe2/main.swift (gone)):
  `AVPictureInPictureController.isPictureInPictureSupported()` = true on this
  Mac, and a controller built with `init(playerLayer:)` over a PLAIN
  `AVPlayerLayer` (no AVKit view) reports `isPictureInPicturePossible = true`
  1.2 s into playback. PiP was not started (starting it would put a window on
  the maintainer's screen). The same probe read
  `MPNowPlayingInfoCenter.default().nowPlayingInfo` in-process while playing,
  once behind a bare AVPlayerLayer and once behind an `AVPlayerView`
  (`controlsStyle = .none`, `updatesNowPlayingInfoCenter` at its default
  true): both read EMPTY and `playbackState = 0 (unknown)`. THIS DOES NOT
  SETTLE whether AVPlayerView publishes Now Playing on macOS: the clip has no
  audio track and the read is the app's own dictionary, so "AVKit publishes
  through its own MediaRemote session, not through `default()`" and "nothing
  was published for a silent clip" read the same. Settling it needs the
  system's view of Now Playing (the menu-bar module), which means driving
  the host UI; not done.
- probe3 (scratchpad/video-native/probe3/main.swift (gone)): the accessibility tree
  of a window holding an `AVPlayerView(controlsStyle: .none)`, an
  `AVPlayerView(controlsStyle: .inline)` and a bare `AVPlayerLayer`, read from
  a second process through AXUIElement (`AXIsProcessTrusted = true`). The
  window's children were ONLY the inline view's controls, flattened into the
  window: `AXCheckBox "play/pause"`, `AXButton "More Controls"`, `"show
  legible media selection menu"`, `"show audible media selection menu"`,
  `"show action menu"`, `"show chapter menu"`, `"playback speed"`,
  `AXCheckBox "zoom"`, `"Show Live Text"`, `"show external playback menu"`,
  and one empty AXStaticText. Neither the `.none` view nor the bare layer
  contributed any element: no group, no image, no "video" role. So on
  macOS the native view's accessibility IS its controls; with the controls
  hidden, VoiceOver gets nothing from it, the same as from kaya's image
  widget.

## 1. The native views: composited layer or special surface?

### AVPlayerLayer (macOS 10.7+, iOS 4+)
- A CALayer subclass; Apple's own usage is as a view's backing layer
  (`override static var layerClass { AVPlayerLayer.self }`), and its
  `contents` is "opaque and you can't change it"
  ([AVPlayerLayer](https://developer.apple.com/documentation/avfoundation/avplayerlayer)).
- It composites like any layer in the app's Core Animation tree: MEASURED on
  macOS (above) for ancestor `masksToBounds` + `cornerRadius`, SwiftUI
  `clipShape`, a sibling drawn over it, and scrolling inside NSScrollView.
  On iOS the same Core Animation model applies (the documented pattern is
  a UIView backed by the layer); NOT measured on the simulator in this pass.
  Apple's own "Becoming a now playable app" sample uses exactly this for
  its custom-controls player on iOS, tvOS and macOS
  (`Shared/Utility/AssetPlayerView.swift`: "a view backed by an
  AVPlayerLayer";
  [sample](https://developer.apple.com/documentation/mediaplayer/becoming-a-now-playable-app)).
- It has NO controls of its own, so "hide the controls" does not arise.
- `isReadyForDisplay` tells when the first frame is up; "the layer doesn't
  present any content until the value becomes true"
  ([isReadyForDisplay](https://developer.apple.com/documentation/avfoundation/avplayerlayer/isreadyfordisplay)).
- It renders the selected subtitle/caption option itself (§2), and
  `videoGravity` is the fit/fill knob (`resizeAspect`, `resizeAspectFill`,
  `resize`), which maps 1:1 onto kaya's `fit` vocabulary
  (`contain`/`cover`/`fill`).
- It can hand back the frame it is showing, but only while paused:
  `displayedPixelBuffer()` (macOS 13 / iOS 16, documented as deprecated at
  27.0) "only returns an image when playback is in a paused state ... It
  also returns nil when displaying protected content"
  ([displayedPixelBuffer](https://developer.apple.com/documentation/avfoundation/avplayerlayer/displayedpixelbuffer())),
  replaced by `displayedReadOnlyPixelBuffer()` (macOS 26 / iOS 26), nil "if
  the current player's rate is non-zero, displayed pixel buffer is
  protected" ([displayedReadOnlyPixelBuffer](https://developer.apple.com/documentation/avfoundation/avplayerlayer/displayedreadonlypixelbuffer())).
- New in 26.4: `setCaptionPreviewProfileID(_:position:text:)` draws a caption
  preview "using the visual appearance settings from the specified
  accessibility profile" (profile ids from `MACaptionAppearanceCopyProfileIDs()`),
  which is AVFoundation stating that the layer draws captions in the user's
  MediaAccessibility style
  ([setCaptionPreviewProfileID](https://developer.apple.com/documentation/avfoundation/avplayerlayer/setcaptionpreviewprofileid(_:position:text:))).

### AVPlayerView (AppKit, macOS 10.9+)
- An NSView "that displays content from a player and presents a native user
  interface"; styles range "from no controls to controls matching the look
  of QuickTime Player"
  ([AVPlayerView](https://developer.apple.com/documentation/avkit/avplayerview)).
  `.none`: "The view displays no playback controls"
  ([AVPlayerViewControlsStyle.none](https://developer.apple.com/documentation/avkit/avplayerviewcontrolsstyle/none)).
  MEASURED: `.none` draws no chrome at all.
- CAVEAT for kaya: "Regardless of the selected controls style, the player
  view always supports the following standard set of keyboard shortcuts":
  Space play/pause, arrows frame-step, J/K/L shuttle
  ([AVPlayerView](https://developer.apple.com/documentation/avkit/avplayerview)).
  So with `.none` the view still owns keys whenever it is first responder;
  kaya would have to keep it from becoming first responder (or accept
  those keys as platform behaviour) if the app's own key handling must win.
- Also on by default and relevant to "hidden controls": Live Text / visual
  lookup on pause, `allowsVideoFrameAnalysis` default true (macOS 13)
  ([allowsVideoFrameAnalysis](https://developer.apple.com/documentation/avkit/avplayerview/allowsvideoframeanalysis));
  PiP off by default, `allowsPictureInPicturePlayback` default false (macOS 10.15)
  ([allowsPictureInPicturePlayback](https://developer.apple.com/documentation/avkit/avplayerview/allowspictureinpictureplayback));
  Now Playing on by default, `updatesNowPlayingInfoCenter` default true (macOS 10.13)
  ([updatesNowPlayingInfoCenter](https://developer.apple.com/documentation/avkit/avplayerview/updatesnowplayinginfocenter);
  MEASURED true). Trimming UI via `beginTrimming(completionHandler:)`.
- Composites like any layer-backed NSView (MEASURED: pane B clipped to its
  frame, no chrome).

### AVPlayerViewController (UIKit, iOS 8+; also Mac Catalyst)
- `showsPlaybackControls = false` hides the system controls; Apple's own
  example use is "a non-interactive video presentation, such as a video
  splash screen", and warns not to toggle it while onscreen because "doing
  so creates or destroys user interface elements"
  ([showsPlaybackControls](https://developer.apple.com/documentation/avkit/avplayerviewcontroller/showsplaybackcontrols)).
- `contentOverlayView` sits "between the video content and the playback
  controls" for noninteractive views
  ([contentOverlayView](https://developer.apple.com/documentation/avkit/avplayerviewcontroller/contentoverlayview)).
- With it you get "the full support of the system player– support for Picture
  in Picture, SharePlay, Visual Analysis, Native Catalyst Support, New
  hardware and feature support" (WWDC22 10147,
  [Create a great video playback experience](https://developer.apple.com/videos/play/wwdc2022/10147/)).
- It is a VIEW CONTROLLER: embedding it inline means a child view
  controller. MAUI found that "On iOS 16+ and macOS 13+ the
  AVPlayerViewController has to be added to a parent ViewController,
  otherwise the transport controls won't be displayed", and walks its
  visual tree (including CollectionView/CarouselView templates) to find one
  ([MauiMediaElement.macios.cs](https://github.com/CommunityToolkit/Maui/blob/main/src/CommunityToolkit.Maui.MediaElement/Views/MauiMediaElement.macios.cs)).
- It owns its player's Now Playing session: "An AVPlayerViewController
  manages its own player and Now Playing session, so you can't add your own
  Now Playing session"
  ([MPNowPlayingSession](https://developer.apple.com/documentation/mediaplayer/mpnowplayingsession)).
- Not subclassable
  ([AVPlayerViewController](https://developer.apple.com/documentation/avkit/avplayerviewcontroller)).

### SwiftUI VideoPlayer (macOS 11+, iOS 14+)
- Only two initializers: `init(player:)` and `init(player:videoOverlay:)`,
  whose overlay is "placed below the system-provided playback controls, and
  only receives unhandled events"
  ([VideoPlayer](https://developer.apple.com/documentation/avkit/videoplayer),
  [init(player:videoOverlay:)](https://developer.apple.com/documentation/avkit/videoplayer/init(player:videooverlay:))).
  There is NO API to hide its controls. MEASURED on macOS: paused, it dims
  the video under its control scrim (centre BE4E2F became 722F1C). Unfit
  for kaya, whose editor draws its own transport.

### AVSampleBufferDisplayLayer (macOS 10.8+, iOS 8+)
- A CALayer that "displays compressed or uncompressed video frames" the app
  enqueues, with its own `controlTimebase`
  ([AVSampleBufferDisplayLayer](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer));
  since macOS 14 / iOS 17 the enqueueing half is `sampleBufferRenderer`
  (`AVSampleBufferVideoRenderer`).
- It has capture protection as API: `preventsCapture` "indicates whether
  the layer protects against screen capture" (macOS 10.15 / iOS 13)
  ([preventsCapture](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/preventscapture)),
  plus `preventsDisplaySleepDuringVideoPlayback` and
  `preventsAutomaticBackgroundingDuringVideoPlayback`.
- PiP-capable: `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`
  (macOS 12 / iOS 15); "The system supports displaying content from an
  AVPlayerLayer or AVSampleBufferDisplayLayer"
  ([ContentSource](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/contentsource-swift.class)).
- It is the route for "kaya's own frames, platform-presented": if kaya ever
  decoded (or produced) frames itself it could still hand them to this
  layer and keep PiP. But the app then owns A/V sync
  (AVSampleBufferRenderSynchronizer + AVSampleBufferAudioRenderer), which
  is exactly the audio/clock work the plan refused (§2 of the plan).

### Inside SwiftUI (NSViewRepresentable / UIViewRepresentable)
- MEASURED on macOS: an NSViewRepresentable hosting an AVPlayerLayer-backed
  view is clipped by SwiftUI's `clipShape` and drawn over by a later ZStack
  sibling. kaya's SwiftUI interpreter can therefore host the native layer
  as one more representable, with its own layout, clip and z-order intact.
- The representable is an NSView/UIView, so hit testing goes to it; a bare
  AVPlayerLayer host has no controls and does not consume clicks beyond
  what the host view does. An AVPlayerView with `.none` still takes the
  keyboard shortcuts above when focused.

## 2. What the native view gives for free vs the headless route

The headless route is the current plan: `AVPlayer` +
`AVPlayerItemVideoOutput` pulling `CVPixelBuffer`s on a display link, handed
to the image widget's high-rate path. What follows splits every service
into "belongs to the PLAYER" (same in both routes) and "belongs to the
LAYER/VIEW" (lost or rebuilt by the headless route).

| service | native view (AVPlayerLayer / AVPlayerView / AVPlayerViewController) | headless (AVPlayerItemVideoOutput) |
|---|---|---|
| Subtitles / closed captions drawn over video | Drawn by the layer: "Selecting a subtitle or closed-caption option displays the associated text within the video display provided by AVPlayerViewController, AVPlayerView, and AVPlayerLayer" ([Selecting subtitles](https://developer.apple.com/documentation/avfoundation/selecting-subtitles-and-alternative-audio-tracks)). | Not in the frames; the video output is not in that list. The app must add an `AVPlayerItemLegibleOutput` and draw the text itself. |
| User caption style (MACaptionAppearance) | Honoured: "Apps don't need to do anything in order for that timed text to honor the user's preferences, except to allow AV Foundation to perform the rendering" (WWDC13 608, [transcript](https://asciiwwdc.com/2013/sessions/608)); 26.4's caption preview API draws in a MediaAccessibility profile ([setCaptionPreviewProfileID](https://developer.apple.com/documentation/avfoundation/avplayerlayer/setcaptionpreviewprofileid(_:position:text:))). | Reachable: `TextStylingResolution.default` gives "the same level of styling information that AVFoundation would use itself to render text within an AVPlayerLayer. The text styling will accommodate user-level Media Accessibility settings" ([default](https://developer.apple.com/documentation/avfoundation/avplayeritemlegibleoutput/textstylingresolution-swift.struct/default)). But kaya then owns the layout (position, region, edge style, window colour, font scaling) of every cue, per platform, and the scene has to prove it. |
| Automatic subtitle / audio description selection from system accessibility preferences | PLAYER: "By default, the AVPlayer instance applies selection criteria based on system accessibility preferences" ([appliesMediaSelectionCriteriaAutomatically](https://developer.apple.com/documentation/avfoundation/avplayer/appliesmediaselectioncriteriaautomatically)). | Same player, same selection. Audio description is an audible option, so it works headless too. Only the DRAWING of the legible option is lost. |
| Picture in Picture | `AVPictureInPictureController(playerLayer:)` or `ContentSource(sampleBufferDisplayLayer:...)` (macOS 10.15 / 12, iOS 9 / 15). MEASURED macOS: possible with a plain AVPlayerLayer. On iOS it needs background audio configured ([AVPictureInPictureController](https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller), [Adopting PiP in a custom player](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-custom-player)). "AVFoundation stops vending video frames to AVPlayerLayer when PiP mode is active" (same article). | No layer, no PiP: the controller takes only those two layer kinds. Flutter's texture player had to add a hidden AVPlayerLayer for its (unmerged, closed 2026-06-02) PiP attempt, with a "float-up animation workaround for texture-based players" ([flutter/packages#11105](https://github.com/flutter/packages/pull/11105)); PiP on Flutter's iOS video_player is still an open issue from 2020 ([flutter/flutter#60048](https://github.com/flutter/flutter/issues/60048)). |
| AirPlay video | PLAYER: `allowsExternalPlayback` default true, `isExternalPlaybackActive` ([allowsExternalPlayback](https://developer.apple.com/documentation/avfoundation/avplayer/allowsexternalplayback)); AVPlayerViewController "supports AirPlay automatically" once the app is configured for playback ([AVPlayerViewController](https://developer.apple.com/documentation/avkit/avplayerviewcontroller)). A route button for custom UIs is `AVRoutePickerView` (macOS 10.15 / iOS 11) ([AVRoutePickerView](https://developer.apple.com/documentation/avkit/avroutepickerview)). | Player-level, so available; Flutter's texture player enabled it in 2.12.0 by setting `usesExternalPlaybackWhileExternalScreenIsActive` ("Selecting an AirPlay route previously moved only the audio") ([CHANGELOG](https://github.com/flutter/packages/blob/main/packages/video_player/video_player_avfoundation/CHANGELOG.md)). While AirPlay video is active the device shows nothing locally in either route. |
| HDR / EDR | "AVKit manages all the details for you and will automatically play back HDR Video as EDR on displays supporting EDR"; AVPlayer "automatically rendering the result as EDR when possible" (WWDC22 110565, [Display HDR video in EDR](https://developer.apple.com/videos/play/wwdc2022/110565/)). | The app must request a half-float or 10-bit output with linear transfer and present through an EDR-opted layer (`wantsExtendedDynamicRangeContent`, `RGBA16Float`, extended linear P3), per the same session. Flutter's texture route instead "Forces tone-mapping to SDR on iOS to prevent washed-out HDR video playback" (video_player_avfoundation 2.9.7, CHANGELOG above). |
| FairPlay / protected content | Plays in AVPlayerLayer (the whole FPS model presents through AVKit/AVFoundation's layers); AVSampleBufferDisplayLayer adds `preventsCapture`. | The documented statement is on the layer's read-back: `displayedPixelBuffer()` "returns nil when displaying protected content" ([doc](https://developer.apple.com/documentation/avfoundation/avplayerlayer/displayedpixelbuffer())). For the video output itself Apple's docs say nothing; a developer-forum report states `copyPixelBufferForItemTime` returns NULL for FairPlay streams ([forum 726854](https://developer.apple.com/forums/thread/726854), no Apple answer). Flutter hit a related wall with plain AES-128 HLS: "blank video for encrypted video streams on iOS 16", fixed by adding "An invisible AVPlayerLayer ... to overwrite the protection of pixel buffers" ([FVPTextureBasedVideoPlayer.m](https://github.com/flutter/packages/blob/main/packages/video_player/video_player_avfoundation/darwin/video_player_avfoundation/Sources/video_player_avfoundation_objc/FVPTextureBasedVideoPlayer.m), [flutter/flutter#111457](https://github.com/flutter/flutter/issues/111457)). NOT MEASURED here (no FPS key server). For kaya's editor (local H.264 files) this does not bite; for a streaming app it does. |
| Power / efficiency | MEASURED, in-process CPU only, 1080p60 H.264, 6 s window, 960x540 window, this Mac under load avg ~4.8: bare AVPlayerLayer 0.081 s / 0.088 s (1.4-1.5% of one core). | Same clip, `AVPlayerItemVideoOutput` (IOSurface-backed BGRA) pulled on `NSView.displayLink`, each frame set as `layer.contents = IOSurface`: 0.151 s / 0.302 s (2.5-5.0% of one core), 360/360 frames pulled. Both are small; the difference is the per-frame main-thread tick plus BGRA conversion. NOT measured: decoder and WindowServer cost (out of process), and whether either path gets a hardware overlay plane. Apple's only public guidance found: "It is best to use the highest level framework possible to take advantage of the optimizations provided automatically for you" (WWDC22 110565). Flutter users reported Texture-route stutter and raster-thread blocking that a platform view fixed ([flutter/flutter#86613](https://github.com/flutter/flutter/issues/86613)). |
| Display sleep | PLAYER: `preventsDisplaySleepDuringVideoPlayback`, "default value is true in iOS ... and false in macOS" ([doc](https://developer.apple.com/documentation/avfoundation/avplayer/preventsdisplaysleepduringvideoplayback)). | Same (player-level). The plan's "keep-awake becomes an explicit prop" is a PLAYER prop in either route. |
| VoiceOver | MEASURED macOS: AVPlayerView exposes its CONTROLS (play/pause toggle, legible/audible menus, speed, AirPlay, Live Text...) and nothing for the picture; `.none` and a bare AVPlayerLayer expose nothing. | Nothing either; kaya's own widget and controls carry the a11y, which is where kaya's uniform a11y props already live. Parity. |
| Keyboard | AVPlayerView keeps Space / arrows / J K L at every controls style ([AVPlayerView](https://developer.apple.com/documentation/avkit/avplayerview)). | None; kaya's key handling alone. |
| Live Text / visual lookup | AVPlayerView `allowsVideoFrameAnalysis` default true (macOS 13) ([doc](https://developer.apple.com/documentation/avkit/avplayerview/allowsvideoframeanalysis)); AVPlayerViewController too (react-native-video turns it off: "Disable video frame analysis to prevent visual lookup", [VideoComponentView.swift](https://github.com/TheWidlarzGroup/react-native-video/blob/master/packages/react-native-video/ios/view/VideoComponentView.swift)). Not in a bare AVPlayerLayer. | None. |

Summary of §2: the BARE AVPlayerLayer is the sweet spot. It is a plain
composited layer (so kaya's clip/scroll/overlay rules hold, MEASURED), and
it adds exactly the services that belong to the video surface: captions in
the user's style, PiP, EDR, protected-content presentation. Everything that
belongs to the player (media selection, audio description, AirPlay, sleep,
rate, volume) is the same in both routes. The AVKit views add controls,
keyboard shortcuts, Live Text and Now Playing ownership that kaya would
mostly have to switch off.

## 3. Can a test read it?

- MEASURED macOS: the process's own snapshots do NOT contain video pixels.
  `NSView.cacheDisplay(in:to:)` and `CALayer.render(in:)` returned the ground
  colour (white behind a bare layer, black behind AVPlayerView) at the
  video's centre. This matches the documented opacity of the layer's
  `contents` ("opaque and you can't change it",
  [AVPlayerLayer](https://developer.apple.com/documentation/avfoundation/avplayerlayer)).
- MEASURED macOS: a window-server capture of the probe window by id
  (`screencapture -x -o -l<windowNumber>`, the route kaya's mac recorder
  already uses through tools/mac/flightrec-winlist.swift) DOES contain the
  video pixels, the rounded clip and the overlay. The value is
  colour-managed (PNG tagged Display P3; sRGB C83C1E read as P3 BE4E2F), so
  an ink check needs a colour-space conversion and a tolerance wider than
  kaya's ±1, or a reference taken from a known-sRGB swatch in the same
  capture. `CGWindowListCreateImage` itself was not called: this host's SDK header
  marks it `SCREEN_CAPTURE_OBSOLETE(10.5,14.0,15.0)` (CGWindow.h:274),
  i.e. deprecated in 14 and obsoleted in 15, with ScreenCaptureKit the
  replacement; both go
  through the same window server and need the Screen Recording permission
  this host already grants the terminal.
- A paused native layer can also answer for itself: `displayedPixelBuffer()`
  (macOS 13 / iOS 16) / `displayedReadOnlyPixelBuffer()` (26) returns the
  displayed frame while paused. That is an in-process, permission-free
  read of what the layer is showing (not of the composited window), and
  kaya's `expect_ink`-style verb for video could use it on both macOS and
  iOS. Not measured here.
- iOS simulator: not measured in this pass. The same two routes exist (a
  simulator screenshot via simctl, which is the whole screen; the
  displayed-pixel-buffer read). An XCUITest screenshot of an element is
  also whole-surface.
- Protected content: `displayedPixelBuffer` returns nil for it (doc,
  above); `AVSampleBufferDisplayLayer.preventsCapture` exists precisely to
  black out captures. Whether a window capture of an AVPlayerLayer showing
  FairPlay content comes back black is widely reported but NOT measured
  here and not stated in an Apple doc found in this pass.

## 4. Media keys, Now Playing, and volume

### The mechanism (both platforms)
- `MPRemoteCommandCenter` (macOS 10.12.2+, iOS 7.1+) "responds to remote
  control events sent by external accessories and system controls"; it is a
  process-wide singleton (`shared()`), with play, pause, stop,
  togglePlayPause, next/previous track, skip forward/backward, seek
  forward/backward, changePlaybackPosition, changePlaybackRate, and
  language-option commands
  ([MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)).
  A handler returns `.success` / `.commandFailed`; a command set
  `isEnabled = false` is not sent and "the user interface may be changed to
  reflect this when your app is the Now Playing app"
  ([MPRemoteCommand](https://developer.apple.com/documentation/mediaplayer/mpremotecommand),
  [isEnabled](https://developer.apple.com/documentation/mediaplayer/mpremotecommand/isenabled)).
  There is NO volume command in the list.
- `MPNowPlayingInfoCenter` (macOS 10.12.2+, iOS 5+): the app sets
  `nowPlayingInfo` (title, artist, artwork, duration, elapsed time, rate,
  media type, ...), and "The system displays Now Playing information on the
  device's Lock Screen and in the media controls in Control Center", on an
  AirPlay TV and on accessories
  ([MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)).
  Elapsed time need not be ticked: "the playback position, once set, is
  updated automatically according to the playback rate. There is no need
  for explicit period updates from the app" (Apple's sample,
  `Shared/NowPlayable/NowPlayable.swift`, [Becoming a now playable app](https://developer.apple.com/documentation/mediaplayer/becoming-a-now-playable-app));
  it must be re-set on seek, rate change and item change.
- Routing: the system sends remote events to the Now Playing app, and "An
  app doesn't receive remote control events until it begins playing
  content ... These controls send remote control events to the app that's
  currently or was most recently playing"
  ([Handling external player events](https://developer.apple.com/documentation/mediaplayer/handling-external-player-events-notifications)).
  The same page: "All iOS apps that create their own media player, macOS
  apps, and external media apps should support these events. When you use
  either the system or application player, you don't get event
  notifications because those players automatically handle events."

### macOS specifics
- `playbackState` "only applies to macOS. You must set this property every
  time the app begins or halts playback, otherwise remote control
  functionality may not work as expected"
  ([playbackState](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter/playbackstate)).
  Apple's Mac sample sets `.paused` at session start, `.stopped` at session
  end and `.playing`/`.paused` on every change
  (`NowPlayable-Mac/NowPlayable/MacNowPlayableBehavior.swift`); a real
  third-party bug where macOS never set it and the media keys did not reach
  the app: [svoltolini/gumbo#229](https://github.com/svoltolini/gumbo/issues/229).
- What reaches the app through this one door: the keyboard's F7/F8/F9
  media keys and Touch Bar media controls, AirPods / headphone controls, and
  the Control Center / menu-bar Now Playing module (Apple's doc names
  keyboards and headphones through "external accessories and system
  controls"; the per-key routing is documented only in that general form,
  and third-party reports confirm the keys go to the app holding Now Playing,
  e.g. [macworld](https://www.macworld.com/article/233997/how-to-make-sure-the-playpause-button-works-on-your-mac.html)).
- No audio session on macOS: "Apple platforms, other than macOS which
  primarily leaves control to an app, provide an audio experience that the
  operating system manages"
  ([Configuring your app for media playback](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback)).
- Automatic publishing: `AVPlayerView.updatesNowPlayingInfoCenter` (macOS
  10.13, default true; MEASURED true). A bare AVPlayer/AVPlayerLayer has no
  such switch, and `MPNowPlayingSession` (which can auto-publish) lists no
  macOS availability (only Mac Catalyst 16)
  ([MPNowPlayingSession](https://developer.apple.com/documentation/mediaplayer/mpnowplayingsession)).
  So on native macOS a kaya video built on AVPlayerLayer (or headless)
  publishes by hand, as Apple's own custom-player sample does. Whether
  AVPlayerView's automatic publishing is visible through
  `MPNowPlayingInfoCenter.default()` could NOT be settled here (probe2).

### iOS specifics
- The app must be playing with a `.playback` audio session to be the Now
  Playing app; the category keeps audio going with the Silent switch on and
  "To continue playing audio when your app transitions to the background
  (for example, when the screen locks), add the `audio` value to the
  UIBackgroundModes key"
  ([playback](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback),
  [Configuring your app for media playback](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback)).
  The same background mode is required for PiP. Apple's iOS sample sets
  `.playback` and activates the session at session start, deactivates it at
  the end, and observes interruptions (`IOSNowPlayableBehavior.swift`).
  The category is nonmixable by default: activating it interrupts other
  apps' audio.
- Automatic publishing: `AVPlayerViewController.updatesNowPlayingInfoCenter`
  (iOS 10, default true)
  ([doc](https://developer.apple.com/documentation/avkit/avplayerviewcontroller/updatesnowplayinginfocenter)).
  For a custom player: `MPNowPlayingSession(players:)` with
  `automaticallyPublishesNowPlayingInfo = true` (iOS 16), and then "don't
  use nowPlayingInfoCenter"
  ([automaticallyPublishesNowPlayingInfo](https://developer.apple.com/documentation/mediaplayer/mpnowplayingsession/automaticallypublishesnowplayinginfo)).
  "An AVPlayer object can have only one Now Playing session", and an
  AVPlayerViewController's player already has one.
- Hardware volume buttons change the SYSTEM output volume; the app cannot:
  "Only the user can directly set the system volume. Provide a volume
  control in your app, using MPVolumeView"
  ([outputVolume](https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume)),
  KVO-observable; MPVolumeView's slider tracks the buttons "while sound is
  playing" ([MPVolumeView](https://developer.apple.com/documentation/mediaplayer/mpvolumeview)).
  `AVPlayer.volume` is "relative to the system volume. There is no
  programmatic way to control the system volume in iOS"
  ([volume](https://developer.apple.com/documentation/avfoundation/avplayer/volume)).
  On macOS the volume keys likewise move the system output; there is no
  remote command for volume on either platform.

### Interaction with an app that draws its own controls
- The command handlers are plain closures; the app's own controls are
  untouched. The contract is that the app keeps ONE truth for play state
  and feeds it to both its UI and `nowPlayingInfo` / `playbackState`.
  react-native-video, which draws no system controls when `controls` is
  false, sets `controller.updatesNowPlayingInfoCenter = false` ("We manage
  this manually in NowPlayingInfoCenterManager") and runs its own
  MPRemoteCommandCenter handlers, including `togglePlayPauseCommand`
  "sent by Apple's Earpods wired headphones", and chooses the "last active
  player" by observing rates when several players exist
  ([VideoComponentView.swift](https://github.com/TheWidlarzGroup/react-native-video/blob/master/packages/react-native-video/ios/view/VideoComponentView.swift),
  [NowPlayingInfoCenterManager.swift](https://github.com/TheWidlarzGroup/react-native-video/blob/master/packages/react-native-video/ios/core/NowPlayingInfoCenterManager.swift)).
  MAUI does the same on iOS (`UpdatesNowPlayingInfoCenter = false`, own
  metadata) but leaves AVKit's publishing on for Mac Catalyst, sets
  `.playback` and activates the session unconditionally
  ([MediaManager.macios.cs](https://github.com/CommunityToolkit/Maui/blob/main/src/CommunityToolkit.Maui.MediaElement/Views/MediaManager.macios.cs)).
- For kaya this means: the remote commands are occurrences the app hears
  (play, pause, toggle, seek-to, skip, next/previous), not things the
  backend silently does to the player, because the editor's transport
  state is the app's. The singleton means ONE owner per process: a scene
  with several video widgets needs a rule for which one is "now playing"
  (react-native-video's last-active-player rule is one precedent).
  None of this depends on native view vs headless: it is player-level on
  both.

## 5. How other toolkits integrate Apple's native video

- Flutter `video_player` (video_player_avfoundation): the default is the
  Texture route, `AVPlayerItemVideoOutput` + a display link feeding
  `FlutterTexture`'s `copyPixelBuffer`
  ([FVPTextureBasedVideoPlayer.m](https://github.com/flutter/packages/blob/main/packages/video_player/video_player_avfoundation/darwin/video_player_avfoundation/Sources/video_player_avfoundation_objc/FVPTextureBasedVideoPlayer.m)).
  What they found hard, from their own code and changelog: encrypted HLS
  went blank on iOS 16 until an invisible AVPlayerLayer was added to the
  view's layer tree "to overwrite the protection of pixel buffers" (and to
  fix swapped width/height, flutter#109116); frame pacing needs its own
  heuristics because "the engine has undefined behavior when returning
  NULL" and the display-link timing is not the engine's (flutter#159087,
  #159162 TODOs in the same file); HDR was forced to SDR tone-mapping on iOS
  (2.9.7); AirPlay video needed an explicit flag (2.12.0); PiP is still
  missing (flutter#60048, open since 2020; a PR closed unmerged
  2026-06-02). Users reported Texture stutter and raster-thread blocking
  and asked for a platform view (flutter#86613). Flutter answered by adding
  an OPTIONAL platform-view mode that is simply an `AVPlayerLayer`-backed
  view: iOS 2.7.0 ("rendered on the native side, using AVPlayerLayer",
  [flutter/packages#8237](https://github.com/flutter/packages/pull/8237),
  merged 2025-02-07), macOS 2.8.0
  ([FVPNativeVideoView.m](https://github.com/flutter/packages/blob/main/packages/video_player/video_player_avfoundation/darwin/video_player_avfoundation/Sources/video_player_avfoundation_macos/FVPNativeVideoView.m):
  `makeBackingLayer` returns `[[AVPlayerLayer alloc] init]`), with the
  README warning that "on some platforms the use of platform views may have
  correctness issues ... due to limitations of Flutter's platform view
  system" ([README](https://github.com/flutter/packages/blob/main/packages/video_player/video_player/README.md)).
  Flutter's platform-view limits are its own compositor's (it must split
  its Skia/Impeller output around the native view); kaya's SwiftUI
  backend has no such split, since every kaya widget is already a native
  view in one Core Animation tree.
- React Native (`react-native-video` v7): always an `AVPlayerViewController`
  as a child view controller; `showsPlaybackControls = controls` prop;
  `updatesNowPlayingInfoCenter = false` with its own Now Playing manager;
  video frame analysis disabled; PiP through the controller
  ([VideoComponentView.swift](https://github.com/TheWidlarzGroup/react-native-video/blob/master/packages/react-native-video/ios/view/VideoComponentView.swift)).
  Its hard part is the view-controller parenting ("Find nearest
  UIViewController") and keep-awake restore across remounts.
- .NET MAUI `MediaElement` (CommunityToolkit): an `AVPlayerViewController`
  on iOS and Mac Catalyst. Hard part: it must be parented to a view
  controller on iOS 16+/macOS 13+ or its transport controls do not appear,
  including inside CollectionView/CarouselView templates where the page is
  not reachable
  ([MauiMediaElement.macios.cs](https://github.com/CommunityToolkit/Maui/blob/main/src/CommunityToolkit.Maui.MediaElement/Views/MauiMediaElement.macios.cs)).
  Now Playing hand-managed on iOS, AVKit's on Catalyst; `.playback`
  session set unconditionally.
- Qt Multimedia 6: FFmpeg is the default backend on macOS and iOS; the
  native AVFoundation ("Darwin") backend is "still available but with
  limited support" ([Qt Multimedia](https://doc.qt.io/qt-6/qtmultimedia-index.html)).
  The Darwin backend pulls frames with `AVPlayerItemVideoOutput`
  (`copyPixelBufferFromLayer`) into Qt's own `QVideoSink` rendering, i.e.
  the headless route, while still creating an `AVPlayerLayer`
  ([avfvideorenderercontrol.mm](https://github.com/qt/qtmultimedia/blob/dev/src/plugins/multimedia/darwin/mediaplayer/avfvideorenderercontrol.mm),
  [avfmediaplayer.mm](https://github.com/qt/qtmultimedia/blob/dev/src/plugins/multimedia/darwin/mediaplayer/avfmediaplayer.mm)).
  Qt thus sits at the far end (own decode by default) and is the toolkit
  the plan already cites as having retreated from four native backends.
- Compose Multiplatform: no first-party video component found. The
  community `ComposeMediaPlayer` uses an `AVPlayerLayer`-backed UIView in a
  `UIKitView` on iOS, with subtitles drawn by Compose on top
  ([VideoPlayerSurface.ios.kt](https://github.com/kdroidFilter/ComposeMediaPlayer/blob/master/mediaplayer/src/iosMain/kotlin/io/github/kdroidfilter/composemediaplayer/VideoPlayerSurface.ios.kt)),
  but on the JVM desktop target for macOS pulls `AVPlayerItemVideoOutput`
  frames and copies them "to the Skia bitmap" through JNI
  ([NativeVideoPlayer.swift](https://github.com/kdroidFilter/ComposeMediaPlayer/blob/master/mediaplayer/src/jvmMain/native/macos/NativeVideoPlayer.swift)),
  because Skiko's desktop window has no native-view embedding for it.
  Pattern: a toolkit that owns its own raster falls back to frames; one
  that can host a native layer hosts it.

## What this means for kaya (Apple half)

The plan's case against a hosted player view was that it is "a hole in
kaya's surface" and "a rectangle kaya may not draw on anywhere"
(docs/video-editor-plan.md §2). ON APPLE THAT IS FALSE, measured: a bare
`AVPlayerLayer` hosted in a representable is clipped by an ancestor's
rounded mask and by SwiftUI's `clipShape`, scrolls inside a scroll view, and
is drawn over by a later sibling, exactly like any kaya widget. kaya's
SwiftUI backend is already native views in one Core Animation tree, so the
video layer is one more node in it, not a hole. (Whether Android's native
view is a hole, a SurfaceView, is the other half of the question and not
this report's.)

Recommended shape on macOS and iOS: the `video` kind lowers to a
representable whose backing layer is a BARE `AVPlayerLayer`, never
`AVPlayerView`, `AVPlayerViewController` or SwiftUI `VideoPlayer`.
- It brings, with no kaya code: subtitle/caption drawing in the user's
  MediaAccessibility style, EDR/HDR, protected-content presentation, and
  the layer PiP needs (`AVPictureInPictureController(playerLayer:)`,
  measured possible on this Mac).
- It brings no controls, no keyboard shortcuts (AVPlayerView keeps
  Space/arrows/J K L even at `.none`), no Live Text, no Now Playing
  ownership, and no view-controller parenting (the MAUI and
  react-native-video pain). kaya's editor keeps drawing its own transport,
  as ruled.
- `fit` maps 1:1 to `videoGravity`. `isReadyForDisplay` is the first-frame
  signal for the `state` mirror.
- The headless route's frames bought kaya nothing on Apple that the layer
  does not have: the plan already refused "give me the frame playing now"
  in v1 and does thumbnails offline. `AVPlayerItemVideoOutput` stays
  available ADDITIVELY on the same item if a later feature needs live
  frames (the plan's own table says so).
- The image widget's high-rate path stops being needed for VIDEO on Apple.
  It stays the answer for a camera or an external engine, where there is no
  platform view with services to lose.

What it costs, honestly:
- Tests: the video's pixels are not in the process's own snapshots
  (measured), so RULING 5's one ink read per lane must use the window
  server (macOS: `screencapture -l<id>`, measured to see them,
  colour-managed so compare in a stated space with a tolerance) or the
  layer's own paused read-back (`displayedPixelBuffer` /
  `displayedReadOnlyPixelBuffer`, macOS 13+ / iOS 16+, unmeasured). The
  paused read-back is the one that works identically on macOS and iOS and
  needs no permission.
- Captions drawn by the platform are not byte-comparable across platforms
  (by design: they follow the user's style), so a shared scene can assert
  WHICH option is selected, never how it looks.
- On iOS, becoming Now Playing, background audio and PiP need the `audio`
  UIBackgroundModes entry and a `.playback` session, which are app
  packaging and app-policy decisions (the session interrupts other apps'
  audio); kaya's packaging manifest would have to carry the first and the
  app would have to ask for the second.

Media keys and Now Playing are PLAYER-level on both platforms and do not
depend on the view choice. The Apple shape that fits kaya's rules: the
backend registers `MPRemoteCommandCenter` handlers and turns each command
into an occurrence the app hears (play, pause, toggle, seek-to, skip,
next/previous), because the transport state is the app's; the backend
publishes `nowPlayingInfo` from props the app declares (title, artwork,
duration) plus the mirrors it already has (position, rate), re-set on
seek/rate/item change, and on macOS sets `playbackState` on every
start/stop or the keys do not route. `MPRemoteCommandCenter` is a
process singleton, so kaya needs a rule for which of several video widgets
owns it (react-native-video: the last one that started playing). Volume
keys move the SYSTEM volume on both platforms; kaya's `volume` prop is
`AVPlayer.volume`, relative to it, and there is no remote volume command.
On iOS `MPNowPlayingSession` (16+) can auto-publish for a custom player;
on macOS nothing auto-publishes for a bare layer, so the hand-published
path is the one path that serves both.

## Not settled in this pass
- Whether `AVPlayerView`'s automatic Now Playing publishing is visible to
  `MPNowPlayingInfoCenter.default()` (read empty for a silent clip; cannot
  tell "published elsewhere" from "not published"). Irrelevant if kaya
  uses a bare layer and publishes by hand.
- FairPlay: whether `AVPlayerItemVideoOutput` returns NULL (forum report
  only) and whether a window capture of protected content is black; no
  FPS key server here.
- iOS: nothing was run on the simulator; the composition, snapshot and
  read-back claims for iOS rest on the docs and on the macOS measurement of
  the same Core Animation layer.
- Power beyond this process: decoder and WindowServer cost, and hardware
  overlay promotion, for either route. The in-process difference measured
  (1.4-1.5% vs 2.5-5.0% of a core at 1080p60) is small.
