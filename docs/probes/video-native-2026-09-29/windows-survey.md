# Native video views and system media controls: Windows (WinUI 3) and a cross-toolkit survey

Research pass, 2026-09-29. Scope: (A) Windows with WinUI 3; (B) how other toolkits and the web
solve a native video view plus media keys. Read against docs/video-editor-plan.md §2-§3 and
docs/canvas-plan.md §16 (the headless-player-into-the-image-widget design).

kaya pins Windows App SDK packages in tools/fetch-winappsdk.sh: WinUI 2.2.1, Foundation 2.1.0,
Base 2.0.4, InteractiveExperiences 2.0.15, Runtime 2.2.0 (the 2.x line; learn.microsoft.com's
MediaPlayerElement page carries monikers windows-app-sdk-1.2 through windows-app-sdk-2.0, so the
control exists in the version kaya pins). The kaya WinUI backend currently presents image/canvas
pixels through a `WriteableBitmap` (crates/kaya/src/winui/mod.rs, around line 14239) and binds
no Windows.Media type today.

Source code note: the WinUI 3 XAML source is public in microsoft/microsoft-ui-xaml under
dxaml/xcp/, so several claims below are read from the implementation, not only from docs.

## A1. The native view: MediaPlayerElement / MediaPlayerPresenter

API (WinUI 3): `Microsoft.UI.Xaml.Controls.MediaPlayerElement` with `SetMediaPlayer(MediaPlayer)`,
`AreTransportControlsEnabled` ("whether the standard transport controls are enabled"), `Stretch`,
`PosterSource`, `IsFullWindow`, `AutoPlay`.
Source: https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.mediaplayerelement
The player object is the OS's `Windows.Media.Playback.MediaPlayer` (not a Windows App SDK type).

### How the video is put on screen (read from the WinUI source)

1. `CMediaPlayerPresenter::SetMediaPlayerSwapChain()` asks the media stack for a swap-chain HANDLE:
   `MediaPlayerExtension_GetVideoSwapchainHandle(m_spMediaPlayer.Get(), &swapChainHandle)`, and marks
   the element `SetRequiresComposition(CompositionRequirement::SwapChainContent, ...)`.
   https://github.com/microsoft/microsoft-ui-xaml/blob/main/dxaml/xcp/core/native/media/MediaPlayerPresenter.cpp (lines ~90-125)
2. On layout, `CalculateDCompParameters` computes destination rect, stretch transform and stretch
   clip, then calls `MediaPlayer.SetSurfaceSize(destSize)` "immediately to avoid producing frames of
   the wrong size", and sets `PlaybackSession.NormalizedSourceRect` for cropping (same file, ~130-215).
   So the decoder renders at the element's size; the swap chain is not a fixed-size texture scaled
   by XAML.
3. The render walk (`HWWalk`, dxaml/xcp/core/hw/hwwalk.cpp ~2507-2535) makes the presenter's content
   node an `HWCompMediaNode`, and `HWCompMediaNode::SetMedia` (dxaml/xcp/core/hw/hwcompnode.cpp
   ~1053-1130) wraps the handle with `CreateCompositionSurfaceForHandle`, puts it in a
   `CompositionSurfaceBrush` on a `SpriteVisual`, sets the visual's Size, TransformMatrix (stretch) and
   an `InsetClip` (stretch clip). The comment in hwwalk notes "An animating media element that
   switches from drawing its PosterSource to drawing a media swap chain will transition from a render
   data node to a media node".

So structurally the video IS a leaf visual in the element's own composition subtree: it inherits
ancestor transforms, offsets, rectangular clips and animations like any XAML element, and siblings
later in z-order draw above it.

### The catch: it is "external content"

Microsoft's own Visual layer overview, section "External content" (quoted):
> "An example of external content is the (Microsoft.UI.Xaml.Controls) MediaPlayerElement. The Windows
> media stack provides to XAML an opaque media swap chain handle. XAML gives that handle to the
> compositor, which in turn hands it off to Windows (via Windows.UI.Composition) to display. Since the
> compositor can't see any of the pixels in the media swap chain, it can't composite that as part of
> the overall rendering for the window. Instead, it gives the media swap chain to Windows to render it
> below the compositor's rendering, with a hole cut out of the compositor's rendering in order to
> allow the media swap chain below it to be visible."
Limitations it lists: nothing drawn by the app's compositor can be BEHIND external content ("The only
things that can be behind external content are other external content and the window background ...
we discourage/disable transparency for external content"); compositor content cannot SAMPLE it
(AcrylicBrush over a MediaPlayerElement blurs "transparent black"); destination-invert effects (the
text caret) are affected. SwapChainPanel and WebView2 are external content too.
https://learn.microsoft.com/en-us/windows/apps/develop/composition/visual-layer

What that means for kaya's contract ("clips, scrolls, rounds, can be drawn over"):
- Drawn over by opaque or alpha-blended siblings: YES (the app's compositor output sits above the
  hole; ordinary XAML overlays over video are the MediaTransportControls' own design).
- Scrolled, moved, animated transform, rectangular clip: YES by construction (visual inherits the
  tree's transforms; the presenter recomputes the hole). Source: the hwwalk/hwcompnode code above.
- Rounded corners via an ancestor's rounded clip / CornerRadius: NOT DOCUMENTED either way. The
  media node applies only an `InsetClip`; whether a `CompositionGeometricClip` on an ancestor is
  honoured for the system-composited swap chain is exactly what the "external content" model makes
  uncertain. UNSETTLED; needs a measurement on the lane VM (one MediaPlayerElement in a Border with
  CornerRadius, window capture).
- Translucent overlay that blurs the video (acrylic scrubber bar), video under a translucent kaya
  surface, or kaya drawing BEHIND a transparent video: NO (documented above).

### Frame-server mode (kaya's current plan) vs the element

`MediaPlayer.IsVideoFrameServerEnabled` remarks: "When frame server mode is enabled, the media player
does not render video content. Instead, your app should register for the VideoFrameAvailable event
and call CopyFrameToVideoSurface when the event is raised to get the video frame data."
https://learn.microsoft.com/en-us/uwp/api/windows.media.playback.mediaplayer.isvideoframeserverenabled
In frame-server mode the frames land in an app-owned `IDirect3DSurface`, which kaya can put in a
`CompositionDrawingSurface` or `WriteableBitmap`, i.e. INTERNAL compositor content: full effects,
rounding, acrylic sampling and pixel readback work, at the price of a GPU copy per frame on the app's
side and of everything the element does for free (A2).
There is a known-limitations report on frame-server mode in WinUI:
https://github.com/microsoft/microsoft-ui-xaml/issues/6610 ("MediaPlayer in frame server mode quite
limited and has some bugs") and a MediaPlayerElement crash report for the early WinUI 3 port:
https://github.com/microsoft/microsoft-ui-xaml/issues/7702.

Chromium's Windows answer to the same fork, for comparison: its `MediaFoundationRenderer` (used for
PlayReady / Media Foundation playback) calls `IMFMediaEngineEx::EnableWindowlessSwapchainMode(true)`
and passes a DComp surface handle to the GPU process (`SetDCompModeInternal`,
`GetDCompSurfaceInternal`), positioning a virtual video window from "the video element's
compositor-transformed rect (scrolling, fullscreen, CSS transforms, responsive layout, etc.)".
https://github.com/chromium/chromium/blob/main/media/renderers/win/media_foundation_renderer.cc
(~lines 797, 855-870, 1181-1330). For clear video Chromium decodes itself and presents video
through DirectComposition overlay swap chains, with MPO for YUV formats (`kP010MPOForSDR`, "attempts
to enable MPO for P010 SDR video content"):
https://github.com/chromium/chromium/blob/main/ui/gl/swap_chain_presenter.cc
So the browser, whose own contract is "video is an ordinary element that scrolls, transforms and is
drawn over", uses exactly the opaque-swap-chain-in-the-compositor model on Windows when it must.

## A2. What the element gives for free

| feature | MediaPlayerElement (native view) | frame-server mode (kaya's plan) | source |
|---|---|---|---|
| Captions from in-band / TimedTextSource tracks | Rendered by XAML's own `CCueRenderer` as a Grid/Border/TextBlock tree over the video | Not rendered; app must call `RenderSubtitlesToSurface` (requires a PlatformPresented timed-metadata track) or draw cues itself. Reported crashing/throwing in practice | WinUI dxaml/xcp/dxaml/lib/CueRenderer.cpp; https://learn.microsoft.com/en-us/uwp/api/windows.media.playback.mediaplayer.rendersubtitlestosurface ; https://github.com/microsoft/microsoft-ui-xaml/issues/6610 item 1 |
| System caption style (Settings > Accessibility > Captions) | Honoured automatically: `CueStyler.cpp` reads `IClosedCaptionPropertiesStatics` (font colour, opacity, size, edge effect, background, region), tolerating `E_ACCESSDENIED`; CueRenderer's comment names "the Raised/Depressed/Uniform/Drop Shadow setting selectable from the Captions page in the Settings app" | App must read `Windows.Media.ClosedCaptioning.ClosedCaptionProperties` itself ("the closed caption formatting settings that the user can set through the system's closed captioning settings page") and listen to `PropertiesChanged` | WinUI CueStyler.cpp ~50-65, 288-310, 477-490; https://learn.microsoft.com/en-us/uwp/api/windows.media.closedcaptioning.closedcaptionproperties |
| Audio description / alternate audio tracks | Player-level (`MediaPlaybackItem.AudioTracks`), same in both modes; the element adds no AD UI once transport controls are off | same | https://learn.microsoft.com/en-us/windows/apps/develop/media-playback/play-audio-and-video-with-mediaplayer (MediaPlaybackItem, tracks) |
| Picture-in-picture | Window-level on Windows: `AppWindow` with the CompactOverlay presenter; independent of element vs frame server. No per-element PiP exists on Windows desktop | same | https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.windowing.appwindowpresenterkind |
| Casting | Presenter subscribes to `CastingRenderLocationChanged` and drops its swap chain when rendering moves to a cast target | Frame-server app must handle the same itself | MediaPlayerPresenter.cpp ~392, 653-690 |
| HDR | Media stack owns the swap chain and its colour space | Frame-server HDR reported broken: 16-bit float targets throw or look "washed out", no way to detect HDR content | https://github.com/microsoft/microsoft-ui-xaml/issues/6610 item 4 |
| PlayReady / hardware DRM | Supported: the protected path is exactly the opaque swap chain handed to the system compositor | Protected frames cannot be copied into an app surface (the point of the protected path); Microsoft does not document CopyFrameToVideoSurface for protected content. Chromium also uses the DComp swap chain mode, not frame copying, for PlayReady | https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/hardware-drm ; Chromium media_foundation_renderer.cc |
| Power (overlay / MPO) | Swap-chain content handed to the system compositor is eligible for direct scanout or an overlay plane | Every frame is a GPU copy into an app surface, then composed by the app's compositor: no overlay promotion of the video layer | https://learn.microsoft.com/en-us/windows/win32/comp_swapchain/comp-swapchain ; Chromium swap_chain_presenter.cc (MPO for video) |
| Size-correct decode | Presenter calls `MediaPlayer.SetSurfaceSize(dest)` on layout so the decoder produces frames at the displayed size; `NormalizedSourceRect` crops | App chooses the surface size; issue 6610 item 3 reports CopyFrameToVideoSurface's fit inside the target is undocumented and odd | MediaPlayerPresenter.cpp ~160-215 |
| Screen saver / display sleep | `MediaItemDisplayProperties.Type` set to video "helps the system handle your media content correctly, including preventing the screen saver from activating during playback" (applies to MediaPlayer, both modes) | same | https://learn.microsoft.com/en-us/windows/apps/develop/media-playback/integrate-with-systemmediatransportcontrols |
| Narrator | `MediaPlayerElementAutomationPeer` (class name "MediaPlayerElementAutomationPeer", localized control type UIA_AP_MEDIAPLAYERELEMENT); caption TextBlocks are real XAML text elements; the transport controls (when enabled) are ordinary buttons/sliders | An Image showing frames: kaya's own peer, nothing about media | WinUI dxaml/xcp/dxaml/lib/MediaPlayerElementAutomationPeer_Partial.cpp |

One caveat stated by Microsoft about mixing the two: "Setting MediaPlayerElement properties will set
the corresponding properties on its underlying MediaPlayer ... you must be consistent in using
MediaPlayerElement properties or directly using the underlying MediaPlayer", and a player set with
`SetMediaPlayer` must be closed by the app ("Failing to do so may result in fatal playback errors").
https://learn.microsoft.com/en-us/windows/apps/develop/media-playback/play-audio-and-video-with-mediaplayer
Early WinUI 3 port stability: https://github.com/microsoft/microsoft-ui-xaml/issues/7702 (1.2 preview:
transport-control buttons FailFast'd in FrameworkUdk; closed).

## A3. Can a test read the pixels?

- kaya's WinUI harness captures with `PrintWindow(hwnd, ..., PW_RENDERFULLCONTENT)`
  (crates/kaya/src/winui/mod.rs ~14368-14380); the lane's shots also use tools/guest/shot-window.ps1.
- The swap chain is external content composed by the system compositor BELOW the app's compositor
  output (A1). A DWM-level capture (Windows.Graphics.Capture, PrintWindow with PW_RENDERFULLCONTENT,
  which asks DWM for the composed window) should include clear video; a GDI BitBlt of the window DC
  would not. Whether PW_RENDERFULLCONTENT includes a MediaPlayerElement's swap chain is NOT documented.
  UNSETTLED: this is the one measurement worth making before a ruling (a single-element WinUI test app
  on the lane VM, PrintWindow read of a flat-colour clip).
- Protected (PlayReady hardware DRM) content is widely reported to capture as black (the protected
  path never exposes decrypted frames to the compositor's readable output); Microsoft's hardware-DRM
  page (https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/hardware-drm) describes the
  protected path but this pass did not find a Microsoft sentence stating the capture result.
  kaya's scenes use clear synthetic clips, so this does not bite the lanes.
- Frame-server mode keeps kaya's current guarantee (kaya owns the surface, so it can read it).

## A4. Media keys and system transport controls

Automatic integration. "Starting with Windows 10, version 1607, apps that use the MediaPlayer class to
play media are automatically integrated with the SMTC by default ... the user will see your app name in
the SMTC and can play, pause, and move through your playback lists". "For each active MediaPlayer
instance in your app, a separate tab is created in the SMTC". The SMTC is "a set of controls that are
common to all Windows 10 devices".
https://learn.microsoft.com/en-us/windows/apps/develop/media-playback/integrate-with-systemmediatransportcontrols
This is independent of MediaPlayerElement and of AreTransportControlsEnabled: it is a property of the
MediaPlayer, so it holds equally for kaya's headless (frame-server) player. What the element changes is
only the in-window chrome.

Keeping it while drawing your own controls. Two supported shapes:
1. Keep `MediaPlayer.CommandManager` enabled (default). SMTC presses and hardware media keys drive the
   player directly; the app observes `PlaybackSession` state changes and redraws its own UI, and can
   intercept per command with `PlayReceived`/`PauseReceived`/`NextReceived`/`PositionReceived`
   (set `Handled`, use a deferral), and gate buttons with `EnablingRule` (Auto/Always/Never). Its
   `IsEnabledChanged` exists precisely so "your own UI" can "match the SMTC".
   Same page as above, section "Use CommandManager to modify or override the default SMTC commands".
2. Manual: `mediaPlayer.CommandManager.IsEnabled = false`, then drive `MediaPlayer.SystemMediaTransportControls`
   yourself: `IsPlayEnabled`/`IsPauseEnabled`/..., `ButtonPressed` (raised OFF the UI thread; marshal via
   DispatcherQueue), `PlaybackStatus`, `DisplayUpdater` (Type, title, thumbnail, `Update()`),
   `UpdateTimelineProperties` (Start/End/Position required; MinSeek/MaxSeek required for
   `PlaybackPositionChangeRequested`; update "approximately every 5 seconds" and on state change),
   `PlaybackRateChangeRequested`, `ShuffleEnabledChangeRequested`, `AutoRepeatModeChangeRequested`
   (each raised only after the app first sets the property). Manual control is REQUIRED with a
   `MediaTimelineController` (attaching one with the command manager on throws "Attaching Media
   Timeline Controller is blocked because of the current state of the object.") and when an app
   wants one SMTC entry for several players.
   https://learn.microsoft.com/en-us/windows/apps/develop/media-playback/system-media-transport-controls
   https://learn.microsoft.com/en-us/windows/apps/develop/media-playback/play-audio-and-video-with-mediaplayer

Getting an SMTC in a desktop (non-UWP) process without a MediaPlayer:
`SystemMediaTransportControls.GetForCurrentView()` throws 0x80070578 "Invalid window handle" in WinUI 3
(https://github.com/microsoft/WindowsAppSDK/issues/6740, open; a maintainer reply: "All
GetForCurrentView functions only works in UWP ... Scroll to the bottom to see
ISystemMediaTransportControlsInterop"). The Win32 route is
`ISystemMediaTransportControlsInterop::GetForWindow(HWND appWindow, REFIID, void**)`; "The appWindow
parameter must refer to a top-level window that belongs to the calling process."
https://learn.microsoft.com/en-us/windows/win32/api/systemmediatransportcontrolsinterop/nf-systemmediatransportcontrolsinterop-isystemmediatransportcontrolsinterop-getforwindow
Both browsers use it with a HIDDEN window they create for the purpose: Chromium passes the PWA window
or `gfx::SingletonHwnd::GetInstance()->hwnd()` (components/system_media_controls/win/system_media_controls_win.cc
~lines 104-140), Firefox creates `CreateWindowExW(0, L"Firefox-MediaKeys", L"Firefox Media Keys", ...)`
(widget/windows/WindowsSMTCProvider.cpp ~102-125, 454). The WindowsAppSDK proposal for a
`GetForWindowId` wrapper (https://github.com/microsoft/WindowsAppSDK/issues/127) was closed without one
shipping; the interop is still the route. (For a MediaPlayer-backed player none of this is needed:
`MediaPlayer.SystemMediaTransportControls` is the per-player instance.)

Media keys, the flyout, headsets. Hardware play/pause/next/previous keys reach the app as SMTC
`ButtonPressed` / command-manager events for the session the shell considers current (this is how the
browsers receive media keys on Windows: both register only an SMTC, no keyboard hook, per the source
files cited above). Bluetooth headset (AVRCP) buttons are delivered the same way in practice, but this
pass found no Microsoft sentence saying so: UNCITED; the Windows 10 volume-key flyout and the Windows 11 Quick
Settings media controls are the SMTC's UI (the WindowsAppSDK #127 thread describes exactly this: the
controls that appear "when you press the volume up or volume down key ... or when locked it shows on the
lock screen"). Other processes see sessions through
`Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager`
(https://learn.microsoft.com/en-us/uwp/api/windows.media.control.globalsystemmediatransportcontrolssessionmanager).
Background audio: "If you are not using the automatic SMTC integration ... your app must enable the
play and pause buttons ... and handle the ButtonPressed event. If your app does not meet these
requirements, audio playback will stop when your app moves to the background" (manual-control page;
this is a UWP/packaged lifecycle rule, it does not apply to an unpackaged desktop process).

Volume. The hardware volume keys change the SYSTEM endpoint volume and show the flyout; they are not
routed to the app. `MediaPlayer.Volume` / `IsMuted` are per-player stream levels (the app's slider),
and the system can duck or mute a player, observable through `MediaPlayer.AudioStateMonitor.SoundLevelChanged`.
`AudioCategory = Media/Movie` tells the system what kind of stream it is.
https://learn.microsoft.com/en-us/windows/apps/develop/media-playback/play-audio-and-video-with-mediaplayer

## B5. The web as the reference model

The `<video>` element is an ordinary box in layout (it clips, transforms, scrolls, sits under
overlays), custom controls are ordinary DOM over it with `controls` absent, and system integration is
a SEPARATE object, `navigator.mediaSession`, not a property of the element.

W3C Media Session (https://w3c.github.io/mediasession/):
- `MediaMetadata`: title, artist, album, artwork[] (src/sizes/type), chapterInfo.
- `playbackState`: "none" | "playing" | "paused".
- `setPositionState({duration, playbackRate = 1.0, position = 0})`.
- `setActionHandler(action, handler)`, actions: play, pause, seekbackward, seekforward,
  previoustrack, nexttrack, skipad, stop, seekto, togglemicrophone, togglecamera,
  togglescreenshare, hangup, previousslide, nextslide, enterpictureinpicture, voiceactivity.
- "The user agent MUST select at most one of the MediaSession objects to present to the user, which is
  called the active media session ... The selection is up to the user agent".
- "It is RECOMMENDED for user agents to implement a default handler for the play and pause media
  session actions if none was provided for the active media session."
So: the element plays; the page opts into OS integration by publishing metadata/position and
registering handlers; without handlers the UA still wires play/pause to the playing element.

How the browsers map it to each OS:
| OS surface | Chromium | Firefox |
|---|---|---|
| Windows SMTC | components/system_media_controls/win/system_media_controls_win.cc: `ISystemMediaTransportControlsInterop::GetForWindow` on the PWA window or `gfx::SingletonHwnd`, `ButtonPressed`, `DisplayUpdater`, `UpdateTimelineProperties`, `PlaybackPositionChangeRequested` | widget/windows/WindowsSMTCProvider.cpp: hidden `Firefox-MediaKeys` window + `GetForWindow` |
| macOS Now Playing | components/system_media_controls/mac/ (MPNowPlayingInfoCenter + MPRemoteCommandCenter; README says so; instanced per PWA since M130 via an app-shim bridge) | widget/cocoa/MediaHardwareKeysEventSourceMacMediaCenter.mm |
| Linux MPRIS | components/system_media_controls/linux/system_media_controls_linux.cc (`org.mpris.MediaPlayer2`) | widget/gtk/MPRISServiceHandler.cpp |
| Android | components/browser_ui/media/android/.../MediaNotificationController.java (MediaSessionCompat + media notification) | mobile/android/android-components/components/feature/media/ (MediaSessionCallback.kt, MediaNotification.kt, MediaSessionServiceDelegate.kt) |
Chromium's own cross-platform seam is small and is the natural shape for kaya:
components/system_media_controls/system_media_controls.h has `SetEnabled`, `SetIsNext/Previous/
PlayPause/Stop/SeekToEnabled`, `SetPlaybackStatus(kPlaying|kPaused|kStopped)`, `SetTitle/Artist/Album`,
`SetThumbnail(SkBitmap)`, `SetPosition(MediaPosition)`, `UpdateDisplay()`; the observer receives
`OnNext/OnPrevious/OnPlay/OnPause/OnPlayPause/OnStop/OnSeek/OnSeekTo`. Its README explains the
two-way path (renderer <-> browser <-> OS) and that SMC is normally a process singleton, instanced per
desktop PWA on macOS and Windows since M130 (content/browser/media/system_media_controls/README.md).
Firefox source: https://github.com/mozilla-firefox/firefox (paths above). Chromium: https://github.com/chromium/chromium.

## B6. Toolkit survey

| toolkit | video surface | custom controls / overlays | system media controls | source |
|---|---|---|---|---|
| Web / Chromium | Own decode + compositor layer; on Windows DirectComposition overlay swap chains (MPO for YUV), and the MF media engine's DComp swap chain for PlayReady | Ordinary DOM over the element | Built in: Media Session -> SMTC / Now Playing / MPRIS / Android MediaSession (B5) | chromium ui/gl/swap_chain_presenter.cc; media/renderers/win/media_foundation_renderer.cc |
| Electron | Chromium's | DOM | Inherits Chromium's; gated by Chromium's `HardwareMediaKeyHandling` feature, which apps toggle with `--disable-features` | https://github.com/electron/electron/issues/21731 |
| Tauri / webview apps | The system webview's `<video>` (WebView2, WKWebView, WebKitGTK) | DOM | Whatever the webview implements: WebView2 is Chromium; WebKitGTK enabled MediaSession with MPRIS by default in 2.38 | https://webkitgtk.org/2022/09/16/webkitgtk2.38.0-released.html |
| Flutter video_player | `Texture` (external texture) by default; since 2.10.0 `VideoViewType.platformView` "on Android and iOS"; docs warn platform views "may have correctness issues in certain circumstances" | Flutter widgets over the Texture | Absent in the plugin; separate `audio_service` (Android, iOS, macOS, web; Linux via audio_service_mpris; no Windows listed) | https://pub.dev/packages/video_player ; video_player CHANGELOG 2.10.0; https://pub.dev/packages/audio_service |
| Flutter media_kit | libmpv, frames into Flutter's Texture Registry via libmpv's OpenGL render API; Android `--vo=mediacodec_embed` to a Surface; web uses `<video>` | Flutter widgets | Not in the package | https://github.com/media-kit/media-kit |
| Qt Multimedia | Qt renders frames itself (QVideoSink / VideoOutput / QVideoWidget); FFmpeg backend "is the default on all platforms except WebAssembly and embedded Linux"; WMF backend deprecated since 6.10, Android MediaCodec since 6.8 | Qt Quick / widgets over it | None documented (no MPRIS/SMTC/Now Playing in Qt Multimedia) | https://doc.qt.io/qt-6/qtmultimedia-index.html |
| .NET MAUI MediaElement (Community Toolkit) | Native player per platform: ExoPlayer (Android; SurfaceView default, TextureView opt-in "to allow transparencies and other effects", not recommended), AVPlayer (iOS/macOS), `MediaPlayer` in a WinUI `MediaPlayerElement` (Windows), Tizen | Platform controls off by default (`ShouldShowPlaybackControls`), app draws its own and binds `CurrentState` | Built in, opt-in: `MetadataTitle/Artist/ArtworkUrl` shown "on lockscreen controls for Windows, Mac Catalyst, iOS, and Android"; Android needs `enableForegroundService` | https://learn.microsoft.com/en-us/dotnet/communitytoolkit/maui/views/mediaelement ; src/CommunityToolkit.Maui.MediaElement/Views/MauiMediaElement.windows.cs |
| Avalonia | No built-in video. LibVLCSharp.Avalonia's `VideoView` is a native child/"detached window over your video control" | Airspace: "you cannot easily draw things over the video"; overlay content goes in a separate floating window | None | https://github.com/videolan/libvlcsharp/blob/3.x/src/LibVLCSharp.Avalonia/README.md ; https://github.com/AvaloniaUI/Avalonia/issues/6605 |
| Uno Platform | `MediaPlayerElement` via AVPlayer (iOS), Android MediaPlayer, browser media (Wasm), libVLC (Skia/Linux) | WinUI-style | Absent: "Player controls on locked screen support" unavailable on all platforms; no subtitles | https://platform.uno/docs/articles/controls/MediaPlayerElement.html |
| React Native (react-native-video) | Native views: ExoPlayer (Android; `viewType` textureView / surfaceView (default) / secureView; "textureView ... DRM playback isn't supported"), AVPlayer (iOS) | RN views over the native view | Built in, opt-in: `showNotificationControls` (Android, iOS, web); on iOS "only one notification control will be shown for the last active Video component" | https://docs.thewidlarzgroup.com/react-native-video/docs/v6/component/props |
| React Native (react-native-track-player) | Audio only | n/a | Its reason to exist: lock screen / notification / remote controls | https://github.com/doublesymmetry/react-native-track-player |
| Slint | No video widget; examples decode (FFmpeg, GStreamer with a `slint_video_sink`) and push frames into a Slint image | Slint over it | None | https://github.com/slint-ui/slint/tree/master/examples/gstreamer-player ; examples/ffmpeg |
| Compose Multiplatform | No official player; community libs wrap natives: mediamp (ExoPlayer Android, VLC on JVM desktop, AVKit iOS, HTMLVideoElement web), ComposeMediaPlayer (JNI native backends since 0.9.0) | Compose over it | Not built in | https://github.com/open-ani/mediamp ; https://klibs.io/project/kdroidFilter/ComposeMediaPlayer |

What they found hard (cited):
- Airspace: any toolkit that hosts a native video WINDOW (Avalonia NativeControlHost, WPF HwndHost,
  LibVLCSharp) cannot draw over it (Avalonia #6605). WinUI's element is NOT that: it is external
  content in the same composition tree, so opaque overlays work and only sampling/transparency fail (A1).
- Android SurfaceView vs TextureView: MAUI and react-native-video both default to SurfaceView for power
  and DRM and make TextureView an opt-in with warnings (MAUI: "possible performance related issues";
  RN: DRM unsupported on textureView). kaya's plan already chose the texture route on Android (§3).
- Flutter's platform-view mode "may have correctness issues" (video_player docs).
- Frame-server on Windows: subtitles, HDR and fit are all reported broken or undocumented
  (microsoft-ui-xaml #6610).
- MAUI's Windows handler, read at HEAD: sets `MediaPlayer.SystemMediaTransportControls.IsEnabled = false`
  (Views/MediaManager.windows.cs line 75) and writes `MusicProperties.Artist = MetadataTitle`,
  `MusicProperties.Title = MetadataArtist` (Primitives/Metadata.windows.cs lines 37-38): the title and
  artist are crossed. A small illustration that the "system integration" half is where wrappers rot,
  since nothing in a test run looks at the OS flyout.
- Electron apps that register media keys as global shortcuts lose SMTC/MPRIS publishing, and the
  feature flag itself has flipped defaults across Chromium versions (electron #21731).

## What this means for kaya

1. On Windows the native view is viable for kaya's own contract more than the old §2 assumed.
   MediaPlayerElement's video is a leaf visual in the XAML composition tree (hwwalk.cpp,
   hwcompnode.cpp): it scrolls, moves, clips rectangularly, animates and is drawn over by kaya's own
   siblings. It is not an airspace hole of the Avalonia/WPF kind. What it cannot do: be translucent,
   have kaya content behind it, be sampled by acrylic, or (unverified) take a rounded ancestor clip.
   Frame-server keeps those, but loses captions with the user's caption style, HDR, PlayReady, overlay
   power savings and size-correct decode, all of which the element gets for free.
2. System media controls on Windows do NOT depend on the view choice. SMTC integration belongs to
   `MediaPlayer` (automatic since 1607, per player), so kaya's headless player already has it; the
   choice kaya must make is the COMMAND model: keep `CommandManager` on (the OS drives the player,
   kaya mirrors state) or turn it off and route `ButtonPressed` to the app as occurrences (needed for
   one entry across several players, a MediaTimelineController, or an app-defined next/previous).
   A process with no MediaPlayer uses `ISystemMediaTransportControlsInterop::GetForWindow` on a
   top-level HWND it owns (the browsers use a hidden window).
3. The cross-platform shape the evidence points to is the WEB's split, which Chromium's own
   system_media_controls.h already reduces to one small interface over SMTC, MPNowPlayingInfoCenter/
   MPRemoteCommandCenter, MPRIS and Android MediaSession: the video widget plays and presents; a
   separate app-level (or window-level) "media session" carries metadata (title/artist/album/artwork),
   playback state, position state (duration, rate, position), enabled actions, and delivers action
   occurrences (play, pause, stop, seekto, seekforward/backward, next/previous). Default: when the app
   registers no handler, play/pause go to the playing video (the spec's RECOMMENDED default), which on
   Windows is exactly `CommandManager` left enabled.
4. Among toolkits, only MAUI MediaElement and react-native-video build system controls into the video
   control; Flutter, Qt, Uno, Avalonia, Slint and Compose MP leave it absent or to a separate plugin.
   Nobody in the survey besides the browsers has a single uniform API across all five of kaya's
   platforms; that is the gap.
5. Testing: the element keeps geometry/state/timing assertions; pixel reads of the video need the one
   measurement below. Protected content is out of scope for the lanes either way.

## Unsettled (would each take one measurement on the lane VM)

- Does `PrintWindow(PW_RENDERFULLCONTENT)` (kaya's WinUI capture) include a MediaPlayerElement's swap
  chain? Microsoft documents neither answer.
- Does a rounded ancestor clip (Border CornerRadius / CompositionGeometricClip) apply to the media
  visual, given the external-content model?
- In an UNPACKAGED process, what name/icon does the SMTC flyout show for automatic MediaPlayer
  integration (the docs say "your app name" but describe packaged apps)?
Not measured in this pass: building a WinUI XAML test app on the VM was not cheap (kaya's WinUI
backend is Rust over generated bindings with no Windows.Media types bound today), so nothing was
started or changed on 192.168.64.2.
