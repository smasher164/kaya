# Video widget research — APPLE (macOS/iOS) and WINDOWS (WinUI 3)

Research date: 2026-09-02. Every claim carries a URL. Primary sources preferred.

STATUS: COMPLETE.

## APPLE 1 — The three hosting options, and who owns the chrome

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

## APPLE 2 — The app-controllable `AVPlayer` surface

All from https://developer.apple.com/documentation/avfoundation/avplayer (iOS 4+/macOS 10.7+ unless noted).

- **Transport:** `func play()`, `func pause()`, `var rate: Float`, `var defaultRate: Float` (iOS 16+/macOS 13+ — "A default rate at which to begin playback"; this is the one to set so `play()` resumes at your chosen speed rather than 1.0). https://developer.apple.com/documentation/avfoundation/avplayer/defaultrate
- **Seek, four spellings:** `seek(to:)`, `seek(to:completionHandler:)`, `seek(to:toleranceBefore:toleranceAfter:)`, `seek(to:toleranceBefore:toleranceAfter:completionHandler:)`, plus two `Date`-based forms for live streams. **Frame-accurate seeking = pass `.zero` for both tolerances** (documented: "the seek is achieved as efficiently as possible … pass `kCMTimeZero` for both to request sample accurate seeking, which may incur additional decoding delay"). https://developer.apple.com/documentation/avfoundation/avplayer/seek(to:tolerancebefore:toleranceafter:)
- **Audio:** `var volume: Float` (0.0–1.0), `var isMuted: Bool`. Both are per-player, independent of system volume. https://developer.apple.com/documentation/avfoundation/avplayer/volume
- **Position:** `func currentTime() -> CMTime` (a snapshot), `addPeriodicTimeObserver(forInterval:queue:using:)` (returns an opaque token; you MUST hold the token and call `removeTimeObserver(_:)`), `addBoundaryTimeObserver(forTimes:queue:using:)`. https://developer.apple.com/documentation/avfoundation/avplayer/addperiodictimeobserver(forinterval:queue:using:)
- **State:** `var timeControlStatus` (`.paused` / `.waitingToPlayAtSpecifiedRate` / `.playing`) — this is the property to mirror, NOT `rate == 0`, because a stalled player has rate 0 but status `.waitingToPlayAtSpecifiedRate`; `var reasonForWaitingToPlay`; `var status`; `var error`. https://developer.apple.com/documentation/avfoundation/avplayer/timecontrolstatus
- **End of playback:** `var actionAtItemEnd` (`.advance` / `.pause` / `.none`) and the notification `AVPlayerItem.didPlayToEndTimeNotification` (Obj-C `AVPlayerItemDidPlayToEndTimeNotification`), posted by the **item**, not the player. Siblings worth wiring: `failedToPlayToEndTimeNotification`, `playbackStalledNotification`, `timeJumpedNotification`. https://developer.apple.com/documentation/avfoundation/avplayeritem/didplaytoendtimenotification
- **Duration:** on the **item** (`AVPlayerItem.duration`) or the asset. Since iOS 16/macOS 13 the synchronous `AVAsset.duration` is deprecated in favour of the async `try await asset.load(.duration)`; the whole `AVAsset` surface moved to async property loading and `AVURLAsset` is the concrete class to construct. https://developer.apple.com/documentation/avfoundation/avasset/load(_:) and https://developer.apple.com/documentation/avfoundation/loading-media-data-asynchronously
- **Looping:** two mechanisms. (1) `AVPlayerLooper` over an `AVQueuePlayer` — the supported, gapless one; it internally enqueues copies of the item. (2) hand-rolled: observe `didPlayToEndTimeNotification` and `seek(to: .zero)` — simpler, but has a visible hitch at the wrap. https://developer.apple.com/documentation/avfoundation/avplayerlooper (iOS 10+, macOS 10.12+)

### APPLE 2b — Frame extraction

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

## APPLE 3 — Hardware decode and codec coverage

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

## APPLE 4 — Embedding in an arbitrary SwiftUI hierarchy

**Yes, and it is the normal thing to do.** `NSViewRepresentable` / `UIViewRepresentable` wrap an AppKit/UIKit view; SwiftUI hosts it as a real subview of the hosting view, so it obeys the parent's frame, participates in z-order (`.zIndex`, ZStack ordering) and is clipped by ancestor clips. https://developer.apple.com/documentation/swiftui/nsviewrepresentable and https://developer.apple.com/documentation/swiftui/uiviewrepresentable
`AVPlayerViewController` needs `UIViewControllerRepresentable` (it is a view controller, and AVKit documents that subclassing it is unsupported — embed it as a child). https://developer.apple.com/documentation/swiftui/uiviewcontrollerrepresentable

**Known limits worth designing around:**
1. **Rounded-corner clipping of a layer-backed representable is unreliable.** `.clipShape(RoundedRectangle(...))` over a `UIViewRepresentable` hosting an `AVPlayerLayer` is reported not to clip; the working spellings are `.mask(RoundedRectangle(...))`, or setting `cornerRadius` + `masksToBounds` on the AVPlayerLayer itself. Reported at https://developer.apple.com/forums/thread/707915 and https://chris-mash.medium.com/avplayer-swiftui-b87af6d0553 . (Mechanism: SwiftUI's clip is applied to the host view's layer; a sublayer with its own `masksToBounds == false` and a non-integral corner is the case that leaks.)
2. **`ScrollView` clips its content by default** — that is normally what you want, but it also means a video that overflows the scroll bounds is cut, not overdrawn. https://developer.apple.com/forums/thread/653827
3. **`.drawingGroup()` must not be applied above a video.** It flattens the subtree into a single offscreen Metal-rendered image (documented as "Composites this view's contents into an offscreen image before final display"); a live `AVPlayerLayer` beneath it will not composite correctly. https://developer.apple.com/documentation/swiftui/view/drawinggroup(opaque:colormode:)
4. **Cost of the representable**: `updateNSView`/`updateUIView` is called on every SwiftUI invalidation. Constructing an `AVPlayer` in `makeUIView` and never in `update` is the rule; the documented SwiftUI idiom on the `VideoPlayer` page itself is `@State` + `.task` so the player is created exactly once. https://developer.apple.com/documentation/avkit/videoplayer
5. **`AVPlayerLayer` in a `layerClass` override is the cheapest hosting** — one layer, no extra view, no AVKit. Apple's own documented pattern. https://developer.apple.com/documentation/avfoundation/avplayerlayer

## APPLE 5 — The traps

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

# WINDOWS (WinUI 3 / Windows App SDK)

## WINUI 6 — Is `MediaPlayerElement` really shipped and supported?

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

## WINUI 7 — The `MediaPlayer` API surface

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

### Frame server mode — what it is, what it costs

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

## WINUI 8 — Codec coverage on Windows 11 in 2026

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

## WINUI 9 — Embedding traps: airspace, z-order, clipping

**There is no airspace problem for `MediaPlayerElement`, and this is a structural difference from WPF.**
- WPF's airspace rule, in Microsoft's own words: "each HWND that comprises one of the technologies of an interoperation application has its own region (also called 'airspace'). **Each pixel within the window belongs to exactly one HWND** … all layers or other windows that attempt to render above that pixel … must be part of the same render-level technology"; and specifically "if you try to use transparency/alpha blending between different technologies … pixels in that WPF box are semi-transparent, they would have to be owned jointly by both DirectX and WPF, which is not possible. So this is another violation and cannot be built." https://learn.microsoft.com/en-us/dotnet/desktop/wpf/advanced/technology-regions-overview
- In WinUI 3, `MediaPlayerElement`'s video is drawn by `MediaPlayerPresenter`, declared `class MediaPlayerPresenter : FrameworkElement` — an ordinary XAML element inside the ordinary XAML visual tree, composited by the same Windows.UI.Composition/DirectComposition pass as everything else in the window. https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.mediaplayerpresenter So it takes part in normal XAML z-order (`Canvas.ZIndex`, panel child order), normal clipping (`UIElement.Clip`, `ScrollViewer`, `Grid` cell bounds), `Opacity`, and `RenderTransform`. It is not a child HWND.
- **The one reported compositing anomaly**: microsoft/microsoft-ui-xaml#9648 — an Acrylic brush over a `MediaPlayerElement` renders as a solid tint plus texture rather than blurring the video behind it (WinAppSDK 1.5). Closed with no technical explanation on the thread. https://github.com/microsoft/microsoft-ui-xaml/issues/9648 Practical reading: video pixels are not available to the backdrop-sampling brushes. Anything that samples what is *behind* it (Acrylic, Mica, `BackdropBrush`) should not be layered over a video; ordinary opaque or alpha-blended XAML on top is fine.
- **The real airspace offender in WinUI 3 is `SwapChainPanel` and `WebView2`, not `MediaPlayerElement`.** SwapChainPanel has its own reported geometry bugs — wrong position at non-100% display scaling (https://github.com/microsoft/microsoft-ui-xaml/issues/5888) and distortion when scaled small (https://github.com/microsoft/microsoft-ui-xaml/issues/6919). A "SwapChainPanel + Media Foundation" video widget would inherit those; `MediaPlayerElement` does not.
- **Inside a `ScrollViewer`**: no documented special case; it is a `Control` and clips like any other. Worth a kaya lane assertion rather than a claim (see the open questions at the end).
- **`Stretch`** (`None` / `Uniform` / `UniformToFill` / `Fill`) is the layout knob, the direct analogue of `AVLayerVideoGravity`. https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/media-playback

## WINUI 9b — Other Windows traps a framework must handle

- **Keeping the screen awake is the app's job.** `DisplayRequest.RequestActive()` while playing, `RequestRelease()` on pause/stop/error; Microsoft's sample keys this off `PlaybackSession.PlaybackStateChanged` and checks `NaturalVideoHeight != 0` so audio-only files don't hold the display on. Windows auto-deactivates the app's requests when it goes off screen. Same doc as above. macOS/iOS have separate mechanisms (AVKit does it for you there; a bare `AVPlayerLayer` does not).
- **Internet capability**: a packaged app needs the `internetClient` capability declared to open a media URL.
- **`MediaPlayer` must be `Close()`d.** It is `IClosable`/`IDisposable`; a widget destroy path that just drops the reference leaks the pipeline and can keep audio focus.
- **Every `MediaPlayerElement` touch is UI-thread only** even though `MediaPlayer` is agile — `dispatcherQueue.TryEnqueue(...)`, exactly as Microsoft's own `DisplayRequest` sample does.

---

# HEADLESS / CI: what an automated lane actually gets

## macOS
- **A logged-in GUI session gets full hardware decode.** AVFoundation/VideoToolbox use the same decoders any app does; nothing about being driven by a test harness changes that. kaya's mac lane already requires a logged-in GUI session (`tools/validate-mac.py`), so it is in the good case.
- **Over plain SSH with no GUI session, expect failures that are not about video at all.** Apple's forums document `.app` bundles failing at runtime under a non-GUI ssh session with NSXPCSharedListener endpoint errors, and the guidance is to stick to daemon-safe frameworks outside a GUI login context. https://developer.apple.com/forums/thread/749314 AVKit/AppKit are not daemon-safe.
- **AV1 will not decode on a pre-M3 mac runner at all** (no working software fallback; `VTDecompressionSessionCreate` fails with `kVTCouldNotFindVideoDecoderErr`) — https://developer.apple.com/forums/thread/722933 . A CI fixture must be H.264 if it is to be codec-portable across mac hardware generations.
- The honest runtime probe from inside the harness is `VTIsHardwareDecodeSupported(_:)` plus `AVURLAsset.audiovisualTypes()`; both are cheap and give a lane a real answer instead of a guess. https://developer.apple.com/documentation/videotoolbox/vtishardwaredecodesupported(_:)

## iOS Simulator
- H.264 in MP4 plays in the Simulator; **HEVC in the Simulator has a documented history of NOT rendering** while the same stream plays on device (reports across iOS 11 → iOS 14 simulators: https://developer.apple.com/forums/thread/92184 , https://developer.apple.com/forums/thread/712230 ), and there are reports of video simply not working in specific simulator runtimes (https://developer.apple.com/forums/thread/727288).
- Modern Apple-silicon simulators share the host's decoders, so today's behaviour is probably better than those reports — but **this is the single item in this document I would insist on measuring rather than believing**, since kaya's iOS lane is a simulator pool.
- Practical rule: make the CI fixture **H.264 Baseline/Main in an MP4**, small, short, and the same file on all five platforms.

## Windows (a VM with no discrete GPU — kaya's lane)
- **Software decode is documented and automatic.** Microsoft, for the H.264 decoder: "decoding is done with DXVA, if it is supported by the underlying hardware, **otherwise, decoding is done with software**." https://learn.microsoft.com/en-us/windows/win32/medfound/h-264-video-decoder So a UTM/Hyper-V Windows 11 guest with no GPU passthrough still decodes H.264. VP8/VP9 are likewise in-box.
- **HEVC and AV1 will NOT be present on a clean VM** unless the Store extension is installed — HEVC's free "from Device Manufacturer" listing is gated to OEM machines, so a VM sees only the paid $0.99 one. A CI fixture must not be HEVC or AV1.
- **`MediaPlayerElement` needs the XAML compositor, which needs D3D**; Windows falls back to WARP (software rasterizer) with no GPU, so a WinUI 3 app renders in a VM — kaya's Windows lane already proves this by rendering everything else.
- **Media Foundation is not present on all SKUs**: the H.264 decoder page lists "Minimum supported server: **None supported**", and the supported-codecs page notes AMR-NB is unavailable on Server SKUs. A Windows Server CI image (or Server Core) is the wrong runner for a video lane; Windows 11 desktop is the right one.
- **Audio has no device in a headless VM.** `MediaPlayer.Volume`/`IsMuted` still behave, and `PlaybackSession.PlaybackState` still advances, but any assertion that depends on real audio output will be flaky. Assert on position/state, never on sound.

## What a kaya scene can actually observe (synthesis, not sourced)
kaya's harness already has `expect_ink` (pixel sampling with a ±1-per-channel tolerance) and byte-compared verdicts. That makes a **deterministic fixture video** the natural observable: e.g. 3 seconds of solid colour changing at exact second boundaries, H.264/MP4, a few KB. Then a scene can assert, identically on all five backends:
- `expect_ink` after `seek(to: 1.5s)` + a settle → proves decode, colour pipeline, and geometry in one shot, and would catch a channel swap the way `check-canvas-blit` does for the canvas.
- a `duration` readback (Apple `AVPlayerItem.duration` / async `asset.load(.duration)`; Windows `PlaybackSession.NaturalDuration`) → proves the demuxer opened it.
- a `position` readback after a seek → proves seeking; **use tolerance `.zero` on Apple or the frame you land on is not the frame you asked for**.
- a playback-state readback (`AVPlayer.timeControlStatus` / `MediaPlaybackSession.PlaybackState`) rather than "is rate 0", because both platforms have a distinct buffering/waiting state.
Note the two APIs' end-of-media differ in shape (Apple: a notification on the *item*; Windows: `MediaPlayer.MediaEnded`) but not in semantics, so one `on_ended` handler is spellable uniformly.

---

# CROSS-PLATFORM SUMMARY FOR A `video` WIDGET (Apple + Windows halves)

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

## Consequences worth a ruling before anything is built
1. **Codec floor.** The intersection of "plays with no extra install on every target" is essentially **H.264 in MP4/MOV, AAC audio**. Everything else diverges: VP9/VP8/MKV are Windows-and-Linux-only, HEVC is Apple-free/Windows-paid, AV1 is Apple-silicon-gated/Windows-free-extension. A `video` widget should state its floor and expose a per-platform capability query rather than pretend uniformity.
2. **Chrome.** Both platforms let the host draw its own transport, but only by refusing the system player view (`AVPlayerLayer` / `AreTransportControlsEnabled=false`). Taking that route means kaya also inherits the responsibilities AVKit/MediaPlayerElement were quietly discharging: Now Playing on Apple, `DisplayRequest` on Windows, PiP on neither.
3. **The source is a path, not a stream.** Windows would allow bytes; Apple would need a resource-loader shim per platform. Uniform semantics argues for a path/URL.
4. **Frame extraction is not one feature.** "Poster frame" and "every frame during playback" have different APIs, different costs, and on Windows the second one *turns off* the first.

---

# CONFIDENCE AND OPEN QUESTIONS

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
