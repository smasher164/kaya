# Media: the player, the video view, the surface and the session (design pass, 2026-09-29)

Status: DESIGNED 2026-09-29; the DEPTH slice BUILT 2026-09-30 on the mac
(the player, the video view, the session, the capability query, the tracks
and captions with kaya's caption renderer, a video view in a collection row
with its visibility, the `resources` reason, and the media_formats,
media_delivery, media_session, media_tracks and media_feed scenes), and the
BREADTH BUILT 2026-09-30: GTK, WinUI and Compose arms, the iOS legs, the
http(s) sidecar (§3) and the other eight bindings, the five scenes on all
five lanes (docs/deferred.md's struck "BUILD — media" entry; what no lane
settles is its "WATCH — media" entry), and the bound on an open and a seek
RULED and BUILT 2026-10-01 (§7c). The surface in frames mode is next
(§7). It replaces the headless design of
docs/video-editor-plan.md §2 and §3, and it answers that plan's rulings 2
and 3 and the roadmap's audio-playback question. The five pieces of shape
in §0 are RULED by the maintainer, and so are §8's six (2026-09-29), the
fourth as a research pass before its final ruling. The research behind every platform claim is
docs/probes/video-native-2026-09-29/ (apple.md, android-linux.md,
windows-survey.md), and for the test suite (§7a)
docs/probes/media-suite-2026-09-29.md; "measured" below means measured
there, on this tree's hosts and lanes.

The reference shape is the web's: `HTMLMediaElement` plays, a `<video>`
box shows it in ordinary layout, `navigator.mediaSession` talks to the
operating system, and a WebGPU `<canvas>` takes a page's own renderer.
kaya splits playing from showing, keeps the session separate, and makes
an app's renderer a producer for the surface widget.

## §0. The rulings of 2026-09-29

1. RULED 2026-09-29 (the maintainer): the video editor is written in
   Rust (docs/video-editor-plan.md ruling 1).
2. RULED 2026-09-29: a MEDIA PLAYER OBJECT, not a widget (§2). An
   audio-only player is the same object with no picture, which answers
   the audio-playback question: a player object, not a kind.
3. RULED 2026-09-29: THE VIDEO VIEW is the default way to show a player,
   on every platform, through the platform's own DRM-capable view with
   its built-in controls off (§3).
4. RULED 2026-09-29: THE SURFACE WIDGET, a rectangle whose pixels come
   from a producer as GPU textures, fully composited (§4). "Frames mode"
   is the surface with a player as its producer. The app as a producer is
   designed here and not built.
5. RULED 2026-09-29: THE MEDIA SESSION, one per app, shaped like the
   web's Media Session API and shared by video and audio players (§5).
   Keep-awake belongs to the player (§2, rule 5), as the ruling's own
   recommendation says.

## §1. What the research found

The headless design had the platform's player hand frames to kaya's image
widget, because a native player view was taken to be "a hole in kaya's
surface". Measured on 2026-09-29, it is not a hole on four of the five
platforms, and the native view brings services the frames route loses:

| | native view | composites with kaya's widgets | captions in the user's style | DRM | PiP | HDR | test read of the picture |
|---|---|---|---|---|---|---|---|
| macOS, iOS | bare `AVPlayerLayer` | yes: rounded clip, scroll, overlay, measured on macOS; iOS by the same Core Animation model, unmeasured | yes, drawn by the layer from MediaAccessibility | FairPlay | `AVPictureInPictureController(playerLayer:)`, measured possible | EDR, automatic | not in `cacheDisplay` or `CALayer.render`; yes in a window-server capture by window id, colour-managed (sRGB C83C1E read as P3 BE4E2F) |
| GTK 4 | `GtkPicture` over a media stream or `gtk4paintablesink`'s paintable | yes, and it is the same object the headless design used | no system caption style exists; playbin draws subtitles | none on the desktop | none | no | yes, through GTK's own renderer (2B374D for 2C3B4F) |
| WinUI 3 | `MediaPlayerElement`, transport controls off | a leaf visual in the XAML tree: scrolls, moves, clipped by a rectangular or rounded ancestor (measured, §6), drawn over; nothing behind it, no see-through, no acrylic sampling | yes, `CueStyler` reads the system caption settings | PlayReady | window-level only (CompactOverlay) | yes | yes, `PrintWindow(PW_RENDERFULLCONTENT)` includes the swap chain (measured, §6) |
| Android | media3 `PlayerSurface`, SurfaceView type | a hole punched by SurfaceFlinger that still follows scroll, move and a rectangular clip (from API 24), a rounded clip only over an opaque ground (measured), views on top | no: `SubtitleView` is View-only; kaya draws cues | Widevine L1 (SurfaceView only) | whole-activity | yes, overlay plane | not in-process (kaya's window `PixelCopy` reads the hole, 000000); yes in the device's own screencap, read by the host (measured 2026-09-30) |

The frames route gives up captions in the user's style, DRM, PiP and
HDR on Apple and Windows (Windows' frame-server mode is reported broken
for subtitles, HDR and fit, microsoft-ui-xaml#6610). Flutter, whose
texture route was kaya's old design, added an `AVPlayerLayer` platform
view in 2025 (flutter/packages#8237) for these reasons. Media keys and
Now Playing do not depend on the view on any platform (§5).

## §2. The media player

A player is an app-held object with an id, created and released in a
transaction like any other scene entity, with no place in the layout. It
decodes on the platform, in hardware where the platform does, plays the
audio and keeps audio and video in sync.

| backend | player | notes |
|---|---|---|
| macOS, iOS | `AVPlayer` over an `AVPlayerItem` | rate, volume relative to the system volume |
| GTK 4 | `GstPlay` / `playbin3` driven by kaya with `gtk4paintablesink` as its video sink | `GtkMediaFile` has no rate, tracks or subtitles, so it is not used |
| WinUI 3 | `Windows.Media.Playback.MediaPlayer`; an HLS or DASH source opens as an `AdaptiveMediaSource` on its own `HttpClient` (docs/traps.md, the WinUI adaptive pipeline that goes idle) | the app must close a player it set on an element; kaya does |
| Android | media3 `ExoPlayer` 1.10.1 | the highest media3 kaya's Kotlin 2.0.21 / compileSdk 36 pins take; resolved and built against them |

**Props** (the app writes): `source` (an asset name, an http(s) URL or a
picked-file handle; never a stream, since AVFoundation has no in-memory
initializer), `speed`, `volume` (0..1, relative to the system volume everywhere),
`muted`, `loop`.

**Commands:** `play`, `pause`, `seek(ms)`.

**Readings** (mirrors the app reads): `position` (ms), `duration` (ms),
`state` (`idle`, `loading`, `ready`, `playing`, `paused`, `ended`,
`failed`), `media_width`, `media_height` (0 for audio).

**Occurrences:** `ended`, `failed(reason)`, `seek_completed`, and
`position` ticking at a fixed rate kaya states (a playhead slider binds
to it).

**Rules.**

1. One state machine, whatever the platform reports: GStreamer's clean
   EOS after a missing-codec warning is `failed` with the platform's
   sentence (docs/traps.md, "A GStreamer pipeline missing its codec
   reaches EOS with status 0").
2. The player never draws. A player with no view is audio only; a player
   shown by a video view or feeding a surface has a picture.
3. The app owns play state. Nothing outside the app moves the player
   except through occurrences the app hears or the session's default
   handlers the app left in place (§5).
4. Several players may exist and play at once (the editor's program and
   clip monitors). Only the one attached to the session speaks to the
   operating system (§5).
5. **Keep-awake is the player's.** While a player is playing and a video
   view or surface on screen shows it, kaya keeps the display awake:
   `AVPlayer.preventsDisplaySleepDuringVideoPlayback` (default true on
   iOS, false on macOS, so kaya sets it on both), `keepScreenOn` on the
   Android view (neither `PlayerView` nor `PlayerSurface` sets it),
   `GtkApplication.inhibit(IDLE)` as GNOME's Showtime does, and on Windows
   a display request (`PowerSetRequest(PowerRequestDisplayRequired)`) held
   by kaya, since the item's display type set to video was measured putting
   none in the power manager's record (§6). An audio-only player keeps
   nothing awake. This is each platform's own behaviour for a video
   player, so no prop is needed.
6. On iOS a playing player activates the `.playback` audio category,
   which keeps sound on with the Silent switch on and interrupts other
   apps' audio (MAUI's MediaElement sets it unconditionally). Android's audio
   focus and becoming-noisy handling are the two ExoPlayer builder calls,
   both on; what the other platforms do on a headphone unplug is measured
   before a rule is written for it.

Every lane asserts a player's state, position within a tolerance,
duration, media size and occurrences; what else a scene may assert is
ruling 2 (§8).

## §3. The video view

A widget kind, `video`, showing one player. It lays out, scrolls and
hit-tests as any kaya widget, carries kaya's accessibility props (no
platform view contributes anything to a screen reader: measured on macOS
and Android, and WinUI's peer names only the control type), and takes
`fit` (`contain`, `cover`, `fill`, the image widget's words).

Its natural size is its picture's (320x180 until a player knows its media
size; a self-view's is docs/capture-plan.md §3's) and it takes no minimum:
it is no wider than its natural width unless it grows, narrower where its
room is, and its height always follows its width at its natural aspect, so
a shrunk view is a smaller picture rather than a letterbox. One rule for the
player and the self-view, `crate::media::video_view_height`, which GTK's
height-for-width layout calls; SwiftUI spells it `.aspectRatio(.fit)`,
Compose `Modifier.aspectRatio` and WinUI a `Viewbox` around the natural
extent. tools/check-verbs.py's video view clause holds all five.

| backend | lowering | `fit` | first-frame signal |
|---|---|---|---|
| macOS, iOS | a representable backed by a bare `AVPlayerLayer`; never `AVPlayerView` (it keeps Space, arrows and J/K/L at every controls style), `AVPlayerViewController` (child view controller parenting, its own Now Playing session) or SwiftUI `VideoPlayer` (no way to hide its controls; dims a paused picture) | `videoGravity` | `isReadyForDisplay` |
| GTK 4 | `GtkPicture` holding the sink's paintable; never `GtkVideo`, which has no property to turn its controls off | `content-fit` | the paintable's size leaving 0x0 |
| WinUI 3 | `MediaPlayerElement` with `AreTransportControlsEnabled` false and the player set by `SetMediaPlayer` | `Stretch` | `NaturalVideoSizeChanged` (an HLS or DASH source states a placeholder size until its first frame, measured) |
| Android | media3 `PlayerSurface` with `SURFACE_TYPE_SURFACE_VIEW` | the containing frame's resize mode | `onRenderedFirstFrame` |

**The box's aspect, RULED 2026-10-03 (the maintainer).** The video view takes
`aspect`, a width:height ratio the app chooses for the view's BOX, whatever
the picture's own shape. Unset (the default) the box is the picture's natural
aspect as above. Set, the box is the natural width at that ratio, its height
following its width at that ratio as it shrinks, still with no minimum, and
`fit` places the picture in it as CSS's `object-fit` does inside an element
given an `aspect-ratio` (and CameraX's `PreviewView.ScaleType` inside its
view): `cover` scales the picture to fill the box and crops it about its
centre, `contain` scales it to fit inside with bars beside it, `fill` stretches
it to the box. It applies to the player and to a capture's self-view alike, so
an app can make Android's upright front camera (3:4) a 16:9 tile as the other
four platforms show it.

*The box's width with an aspect set, RULED 2026-10-04 (the maintainer, so that
an aspect makes every platform look the same).* The box's natural width is the
picture's LONGER side at its natural scale, whatever its rotation, and the
height follows at the chosen ratio: a 640x480 camera at half size gives 320 on
every platform, so its 16:9 tile is 320x180 on Android too, where the box first
took the upright picture's fitted width (180, a 180x101 tile against the
desktops' 320x180). A player's natural scale is its picture's natural size, so
a portrait 1080x1920 video's 16:9 box is 1920 wide before its room shrinks it.
Unset, nothing changes: the box is the picture's natural size as above.

One rule in the core, `crate::media::video_view_box`, answers the box before
layout from a `VideoPicture` (a player's natural size, or a self-view's frames
and rotation, from which it takes both the fitted natural size and the
half-size scale) and `video_view_height` lays it out; GTK and WinUI call it,
SwiftUI through `kaya_video_view_box` and `kaya_capture_self_view_box` (the
host table) and Compose through `KayaPresent.videoViewBox` and
`KayaPresent.captureSelfViewBox` (JNI). Each arm keeps the PICTURE's natural size for
placing the picture, never the box's: Compose's player scales its surface by
the picture's size, and Android's preview is a frames-shaped view placed by
`fit` inside the box (a stretch for `fill` is the view's own scale).

*The wire shape, and why.* `PropKind::Aspect`, one I64: the width in the high
32 bits and the height in the low 32, each a SIGNED 32-bit integer, so the app
says two whole numbers (`aspect(16, 9)`) and the root sees both parts exactly
as given. A ratio carried as one F64 could not refuse a zero or negative part:
`-16:-9` would arrive as 16:9 and `16:0` as infinity, and 16/9 is inexact,
while two integers keep the arithmetic exact in the one rule. A packer
saturates a part outside the signed 32-bit range (JS writes a packed value
past a safe integer, a width of 2^21 or more, in `tx_set_aspect`'s own record
layout rather than through the wire's safe-integer I64, so the refusal names
the width given there too) and the root
refuses any part outside 1 to 65535 as a scene error naming the prop
(`kaya: Aspect on Video: aspect 16:0 has a height of 0; ...`). There is no
"unset" value and no clear spelling: 0 is the pair 0:0 and is refused, the
`max_width` precedent, so a view that has taken an aspect keeps one.
tools/scenes/capture.steps reads it on all five lanes (`expect_video_box`
reads the laid-out box's size, `"320x180"`, each side within one unit in the
platform's own units, or its ratio, `"16:9"`; `expect_video_corner` the box's
top-left corner four points in, `"bars"` a corner the picture leaves), and
tools/check-verbs.py's aspect clause holds the rule, the three doors and the
five arms.

**What each platform cannot do, stated once.** On Apple and GTK the video
view is an ordinary composited widget: see-through, rounded over anything,
animated, drawn over. On WinUI it is "external content": kaya can draw
over it, scroll, move and clip it to a rectangle, but nothing of kaya's
can show behind or through it, and acrylic over it samples transparent
black; a rounded ancestor clip applies (measured, §6). On Android the
SurfaceView is a hole: no see-through before API 34 (kaya's minSdk is
26), a rounded clip only over a solid colour, no interleaving between
kaya layers (the video is behind the whole window or above all of it),
no post-layout transforms of views over it, and no in-process test
read-back (the device's screencap, taken by the host, holds it). An
app that needs any of these asks for the surface (§4).

**Captions.** On Apple and WinUI the platform draws the selected caption
track in the user's system style with no kaya code. On Android kaya draws
cues from the player's text track (`Player.Listener.onCues`), styled from
`CaptioningManager`'s user style and font scale; the track is already
chosen from the system preference by media3. On GTK kaya draws cues from
playbin's text track, scaled with the GTK text-scale setting as Showtime
does, since GNOME has no system caption style. A SIDECAR WebVTT file
(RULED 2026-09-29, the maintainer): AVFoundation takes WebVTT only inside
HLS, so on Apple kaya parses the sidecar's cues and draws them with the
same caption renderer it builds for Android and GTK; sidecar captions
work on all five platforms. A shared scene asserts
which caption track is selected and what cue text is current, never how
the caption looks.

**Built at depth (2026-09-30).** A player lists its tracks as BCP 47 tags
(the platform's own canonicalizer, `und` for a track that names none) in
the platform's order, audio and captions apart, with which of each is
selected; the app selects by position, and captions off. A sidecar file is
a player prop (`captions`, an asset, a picked file or an http(s) URL, with
`captions_language`), listed as the last caption track and selected like any
other; a stream carries its captions inside it. AN HTTP(S) SIDECAR, RULED
2026-09-30 (the maintainer): the backend fetches it with the platform's own
networking, the stack its player uses for the video (URLSession on macOS and
iOS, media3's DataSource on Android, GStreamer's souphttpsrc or libsoup on
GTK, the platform's HTTP client on WinUI), never an HTTP client in the core;
the core hands the backend the URL as the `captions` player prop, the backend
hands the text back (`kaya_player_captions_text`) and it goes through the
core's one WebVTT parser and caption renderer as a local sidecar does, listed
once it has arrived. A fetch that fails (`kaya_player_captions_failed`) is a
player failure with the `network` or `not_found` reason, mapped by the failure
table, on all five; the media_tracks scene fetches the sidecar from the lane's
local server and expects a 404 there to fail the player. THE CAPTION RENDERER IS SPLIT at the core: the core
parses the WebVTT (crates/kaya/src/captions.rs), holds the cue timing and
hands the backend every boundary time (`caption_times`); the backend
watches its own clock for those times, asks the core what is current
(`kaya_caption_at`) at each and after every seek and load, and draws the
answer over each video view showing the player. On the mac the drawing is
a text overlay in the user's MediaAccessibility style (font, relative
size, colours, opacities, the drop-shadow edge), redrawn when that style
changes. The current cue reaches the app as one occurrence whoever draws
it: the core's timing for a sidecar, the platform's legible output for its
own track. AVFoundation's forced-only companion options (it synthesizes one
per subtitle track and selects it by default; it shows only cues marked
forced) are not listed, being display policy rather than a track
(docs/probes/media-mac-2026-09-30.md).

**Picture in Picture** is a later follow-on: direct on the Apple layer,
a window feature on Android and WinUI, absent on GTK.

## §4. The surface widget

A widget kind, `surface`: a rectangle in kaya's layout whose pixels
arrive from a PRODUCER as GPU textures, zero-copy, and are composited
like kaya's own content: see-through, rounded over anything, animated,
layered between widgets and readable by a test.

**The contract.** The surface tells its producer its size in pixels, its
pixel scale, its colour space, and when a frame is due, in step with the
display (`CADisplayLink` / the view's display link, `GdkFrameClock`,
`Choreographer`, `CompositionTarget.Rendering`). The producer answers
with a texture of that size, or with nothing, and the surface keeps its
last frame.

| backend | the texture | how the backend composites it |
|---|---|---|
| macOS, iOS | an `IOSurface` (a `CVPixelBuffer` or a Metal texture's backing) | a layer's `contents`, inside the SwiftUI tree |
| GTK 4 | a dmabuf, or a GL texture in GDK's context | `GdkDmabufTexture` or `GdkGLTexture` in a `GtkPicture` |
| WinUI 3 | a Direct3D 11 texture (DXGI) | a `CompositionDrawingSurface` from the compositor's graphics device: internal content, so clipping, effects and read-back work (a `SwapChainPanel` is external content and is not used) |
| Android | an `AHardwareBuffer`, or a `Surface` over a `SurfaceTexture` | drawn by HWUI inside Compose; the 2026-09-03 probe read a clip's own bytes off this route through kaya's window `PixelCopy` |

**Frames mode** is the surface with a player as its producer:
`AVPlayerItemVideoOutput` (additive: the player keeps its clock), the
GStreamer sink's buffers, `MediaPlayer` in frame-server mode, ExoPlayer
rendering into the surface's own `Surface`. It gives up DRM (protected
frames never reach an app texture on any platform), and captions and PiP
become kaya's to provide: kaya draws cues as in §3 on every platform, and
PiP is not offered. Frames mode is SDR; HDR through it is a later
measurement (Windows' frame-server HDR is reported broken, and Apple's
needs an EDR-opted layer).

**The app as a producer** (designed, NOT built). The same contract, with
the app's own renderer (Metal, Direct3D, Vulkan or GL, wgpu from Rust)
answering each frame-due with a texture. Handing GPU handles to nine
languages safely needs its own research pass, which must answer: who
frees a texture and when the producer may reuse it, and how a
garbage-collected binding is kept from holding a handle past its
release; the fence that says a frame is finished (`MTLSharedEvent`, a
DXGI keyed mutex or fence, a dmabuf `sync_file`, an `AHardwareBuffer`
fence descriptor); keeping producer and compositor on one adapter (the
LUID on Windows, the registry id on the mac) and surviving device loss;
how a frame-due on the display clock fits the app-thread transaction
rules every binding enforces; format and colour space negotiation; the
C floor's spelling and each binding's handle type; and wgpu's hal-level
import and export for a Rust app.

The ledger entry is docs/deferred.md's "RESEARCH: the app as a
surface's producer".

**Canvas ruling 16, restated.** Ruling 16 said the zero-copy arm is the
IMAGE widget's high-rate path, with video as its first producer. The
split it made stands (the canvas is pixels kaya rasterized, the other
widget is pixels someone else produced), and the widget on the second
side is now the surface: the image widget stays the byte-copy arm (the
blob channel), and the high-rate zero-copy arm is the surface. Video's
default route is the video view, so the surface's first producer is a
player in frames mode, then a camera, then the app. canvas-gpu-plan's G6
("dmabuf stays the Image widget's") now reads "the surface's"; G4's one
device owner in the core is unchanged, and the surface names texture
handles only, never a renderer type.

## §5. The media session

One per app, separate from every player, shaped like the web's Media
Session API:

- `metadata`: title, artist, album, artwork (an asset name);
- `playback_state`: `none`, `playing`, `paused`;
- `position_state`: duration, rate, position, taken from the attached
  player when one is attached;
- action handlers, each an occurrence the app hears: `play`, `pause`,
  `stop`, `seek_to(ms)`, `seek_forward`, `seek_backward`, `next`,
  `previous`. An action with no handler is not offered to the system.

**The attach rule (recommended in the ruling, taken).** The app attaches
one player to the session explicitly; a player never takes it by itself.
When a player is attached and the app registers no `play`, `pause` or
`seek_to` handler, the session applies those to the attached player,
which is the web's RECOMMENDED default and Windows' own default command
manager. Detaching, or attaching none, withdraws the app from the
system's controls.

| platform | mapping |
|---|---|
| macOS, iOS | `MPNowPlayingInfoCenter` published by hand (nothing auto-publishes for a bare layer on macOS), re-set on seek, rate and item change; `MPRemoteCommandCenter` handlers, disabled when the app has none. macOS: `playbackState` set on every start and stop, or the media keys do not route. iOS: the `.playback` category and the `audio` background mode, written into the bundle's Info.plist for an app that uses a session (tools/ios/run-sim.py `make_bundle`, the only iOS Info.plist writer); the interpreter refuses a session in a bundle without it. |
| WinUI 3 | the attached player's own `MediaPlayer.SystemMediaTransportControls`; every unattached player has its command manager off, since Windows shows a tab per active `MediaPlayer`. A session with no player uses `ISystemMediaTransportControlsInterop::GetForWindow` on kaya's top-level window (`GetForCurrentView` throws in WinUI 3). |
| GTK 4 | MPRIS2 on the session bus through the `mpris-server` crate: `org.mpris.MediaPlayer2.<app id>`, `DesktopEntry` from the declared identity (GNOME Shell names the card from it), `CanPlay` true while a player is attached, since the Shell shows only players with `CanPlay`. |
| Android | media3 `MediaSession` over the attached player; `MediaSessionService` as a `mediaPlayback` foreground service for background play and the `MediaStyle` notification, with `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK` and, from Android 13, `POST_NOTIFICATIONS`. |

**Stated limits.** On Android the media keys reach only an app playing
audio: a session over a clip with no audio track was measured never
chosen as the media button session, so a silent preview receives no
keys. Volume keys change the system volume on every platform (Android's
media stream once audio plays); a player's `volume` is relative to it and
no platform routes the keys to the app.

## §6. What is measured first

The mac arm's questions were measured with the depth slice
(docs/probes/media-mac-2026-09-30.md): the picture is read by a window capture
by id, in-process through ScreenCaptureKit, converted to sRGB and compared
within 2 per channel, once the clip carries the sRGB transfer tag (a BT.709
transfer reads CF4421 for C83C1E); an `.accessory` guest becomes Now Playing
muted, and a command reaches it through the system only when sent from
Apple-signed `/usr/bin/perl` (one sent from the guest is dropped while
answered true), so `session_send` does that and refuses unless the system
names the guest; and `preventsDisplaySleepDuringVideoPlayback` holds the
display assertion exactly while playing.


1. WinUI, MEASURED 2026-09-30 (the lane VM, Windows 11 25H2 arm64, the
   interactive session, a temporary probe in the arm since deleted): a
   rounded ancestor clip APPLIES to `MediaPlayerElement` (a host Grid with
   CornerRadius 40 over a 160x90 view: its corner pixel reads the window's
   ground F3F3F3 while the top and left edges' middles read C83C1E, and the
   picture shows as a pill); `PrintWindow(PW_RENDERFULLCONTENT)` DOES include
   its picture (C83C1E, the same bytes a screen BitBlt of its box reads), so
   `expect_video_ink` reads the window's print like every other WinUI ink
   read, and reads the ground F3F3F3 until the first frame; and the media
   flyout names an unpackaged process "Unknown app" even with the declared
   app id registered under HKCU AppUserModelId (the system's session manager
   names the session by that id, `dev.kaya.aurora.notes`), under the title
   and artist kaya published. The item's display type set to video put no
   display request in `powercfg /requests`, so the arm holds
   `PowerSetRequest(PowerRequestDisplayRequired)` itself (§2 rule 5).
2. iOS simulator, MEASURED 2026-09-30 (iOS 26.5 simulator on an M5 Pro,
   Xcode 26.6): a rounded ancestor clip, a scroll view's offset and clip,
   and a view drawn over it all apply to the bare `AVPlayerLayer`'s
   picture; `simctl io screenshot` holds that picture, tagged sRGB, and
   reads the clip's C83C1E exactly, so the iOS `expect_video_ink` is the
   host's screenshot of the device; `displayedPixelBuffer()` answers while
   paused (160x90, `420v`) and is nil while playing. MediaRemote's command
   sent from a process `simctl spawn` starts in the simulator reaches the
   app's `MPRemoteCommandCenter`, while every Now Playing read answers an
   unentitled process nothing, so `session_send` proves arrival by the
   app's own handler. The simulator keeps no record of a display-sleep hold
   (no idle-timer change, no power assertion: its video renders in-process,
   and AVFoundation's hold is a device's remote video queue), so the iOS
   `expect_display_awake` reads the shown player's
   `preventsDisplaySleepDuringVideoPlayback` while it plays. AV1 in MP4
   reaches ready there with its video track `isPlayable` and `isDecodable`
   false, plays the audio and draws nothing; the decodability check fails
   it `unsupported_codec` (with the check cut, the leg reads "ready 2.0s
   0x0, played past 1s, ended").
3. Android: the chosen clip decoding on the emulator pool (ruling 5,
   §8), and the `MediaStyle` notification on the pool.
4. Linux: `mpris-server` on the lane's session bus, read back with
   `busctl`, since the lane image has no GNOME Shell.
5. Each platform's first-frame signal and headphone-unplug behaviour.

## §7. Sequencing and bindings

Depth on the mac: the player, the video view and the session in the
core, SwiftUI and Rust, with one scene; then the breadth to GTK, WinUI and
Compose, the iOS legs and the other eight bindings (the player is an
object handle, the session one per app; every binding does, the C floor
spells it through kaya.h); then the surface in frames mode, depth then
breadth; then the media test suite (§7a) green on all five lanes, its
formats scene written with the depth slice and filled at breadth; then the
editor. The app as a producer waits for its research.

Not promised here: kaya decoding video or FFmpeg in the core; DRM
licence acquisition (FairPlay, Widevine and PlayReady key servers are
the app's); composition and export (docs/video-editor-plan.md §8);
Picture in Picture in the first slices.

## §7a. The media test suite

Asked by the maintainer on 2026-09-29: before the editor, examples that
prove the player and the video view over a spread of formats, codecs and
streams; not exhaustive, and independent of the editor. Measured with each
platform's own player and no kaya code (docs/probes/media-suite-2026-09-29.md).

**What each platform plays.** macOS 26.6 (M5 Pro) and the iOS 26.5
simulator through AVPlayer; the Windows VM through `MediaPlayer` with the
HEVC, AV1, VP9 and Web Media extensions installed and, measured
2026-09-30, with those four removed for the user; the lane image's GStreamer 1.26.2, naming the
package each item needs beyond the `-base` and `-good` the image already
has; the API 35 pool through media3 1.10.1 with `media3-exoplayer-hls` and
`-dash`. "container" is AVFoundation -11828, "This media format is not
supported.".

| item | macOS | iOS sim | Windows (with / without) | Linux | Android |
|---|---|---|---|---|---|
| H.264 + AAC, MP4 | plays | plays | plays / plays | `-libav` or `-bad` | plays |
| HEVC, MP4 and MOV | plays | plays | plays / audio only, QUIET | `-libav` or `-bad` | plays (software) |
| VP9 + Opus, WebM | fails: container | fails: container | plays / audio only, QUIET | plays | plays |
| AV1, MP4 | plays (M3 and later) | no picture, NO error | plays / audio only, QUIET | `-bad` | plays (dav1d) |
| AV1, WebM | fails: container | fails: container | plays / audio only, QUIET | `-bad`; without it, audio only, silently | plays |
| MP3, FLAC, WAV | plays | plays | plays | plays | plays |
| AAC (M4A) | plays | plays | plays | `-libav` or `-bad` | plays |
| Opus in Ogg | plays | plays | plays / fails: `SourceNotSupported` | plays | plays |
| Opus in WebM | fails: container | fails: container | plays / plays | plays | plays |
| progressive HTTP | plays, Range required | plays | plays | plays | plays |
| HLS, fMP4 segments | plays | plays | plays | plays with the decoders; one missing HANGS | plays |
| HLS, TS segments | plays | plays | plays | `-bad` (`tsdemux`); without it HANGS | plays |
| DASH | fails: container | fails: container | plays | plays with the decoders | plays |
| sidecar WebVTT | not taken outside HLS; kaya draws (ruled) | same | `TimedTextSource`, 2 cues | `suburi`, 2 cues | 2 cues |
| WebVTT in HLS | listed | listed | listed | 2 cues | 2 cues |
| tx3g in MP4 | listed | listed | not exposed by the MP4 source | 2 cues | 2 cues |
| two audio tracks, switch | `en, fr`, switched | same | `en, fr` listed | `en, fr` read | switched |

The headline: every platform but Apple plays the whole set once Linux has
`gstreamer1.0-plugins-bad`, and Apple refuses WebM and DASH outright. The
dangerous cells are the quiet ones: the iOS simulator reaches ready on
AV1 with no picture and no error, GStreamer plays the audio of a file
whose video decoder is missing, and an HLS stream missing an element hangs
with no error. Windows without the Store packages is quiet too: HEVC, VP9
and AV1 files reach `Playing` with the audio and no picture, and only the
video track's `SupportInfo.DecoderStatus` (`UnsupportedSubtype`) says so.
Measured by the DLLs each file loads, Windows' WebM container and Opus
decoder are in-box, VP9 is the VP9 package's, and the Ogg container is Web
Media Extensions'. Two further traps: AVPlayer refuses an HTTP server that
ignores `Range` (-11850, "The server is not correctly configured."), which
public DASH servers showed it reports BEFORE reading the format, so an
unsupported manifest from such a server reads as a server error; and on the
Windows VM an ssh login runs in session 0, which has no display, where
`MediaPlayer`'s own presentation fails (`DecodingError`,
`DXGI_ERROR_NOT_CURRENTLY_AVAILABLE`) for H.264 whose height is not a
multiple of 16 and for all HEVC, although the decoders decode every frame
there and frame-server mode plays everything. The lanes run in the
interactive session and are unaffected; deploy-win's guest unit tests run
over ssh, so a unit test that plays video there uses frame-server mode.
CEA-608 is left out: FFmpeg has no encoder for it.

**Failure semantics, one in nine bindings.** A player that cannot play
publishes `failed(reason)` and reads `state` `failed`. `reason` is closed:
`unsupported_codec`, `unsupported_container`, `not_found`, `network`,
`decode_error`, `resources` (§7b), `timeout` (§7c), and `no_track`, which only
a reader's read answers (§8 ruling 4) and no player row below maps to; each binding spells it as its own enum, and the platform's
sentence rides beside it as `detail`, which no scene compares. Rule: a track
the platform cannot decode is `failed(unsupported_codec)` even when the
rest plays, and a missing element is `failed` even when the pipeline only
stalls. kaya checks a local source exists before handing it over, since
AVFoundation reports a missing file as -17913, which names nothing.

| reason | Apple | WinUI | GStreamer | media3 |
|---|---|---|---|---|
| `unsupported_codec` | a track whose `isPlayable` or `isDecodable` is false, the item ready (-11821 decode failure on open is `decode_error`) | a track's `SupportInfo.DecoderStatus` not `FullySupported` | a missing-plugin message whose caps are a codec's; `STREAM_ERROR_CODEC_NOT_FOUND` | 4004, 4005, or a `Tracks` group with no supported track |
| `unsupported_container` | -11828 / -12847 | `SourceNotSupported` with 0xC00D36C4 (`MF_E_UNSUPPORTED_BYTESTREAM_TYPE`), 0xC00D6591 (an unsupported manifest profile) | a missing-plugin message whose caps are a container's or a manifest's; `STREAM_ERROR_TYPE_NOT_FOUND`, `_WRONG_TYPE`, `_DEMUX` | 3003, 3004 |
| `not_found` | NSURLErrorDomain -1100, HTTP 404/410 | `SourceNotSupported` with 0xC00D001A (`NS_E_FILE_NOT_FOUND`), HTTP 404 | `RESOURCE_ERROR_NOT_FOUND` | 2005; 2004 with 404 or 410 |
| `network` | other NSURLErrorDomain; -11850 | `SourceNotSupported` with 0xC00D0035 (`NS_E_SERVER_NOT_FOUND`), refused or unresolvable; `NetworkError` | a `STREAM_ERROR_FAILED` or resource error from the HTTP source element (refused, unresolvable and unroutable are stream errors) | 2001, 2002, other 2004 |
| `decode_error` | -11821 | `MediaPlayerError.DecodingError` | `STREAM_ERROR_DECODE` | 4001, 4003, 3001, 3002 |
| `resources` | -11839 ("The decoder required for this media is busy."), underlying -12913 (`kVTVideoDecoderNotAvailableNowErr`); measured at the 257th AV1 player on an M5 Pro, where H.264 and HEVC opened 1024 | not reached: no hardware decoder on the lane's VM | not reached: the lane's decoders are software with no instance cap (256 AV1 players prerolled in 1.1 s; 256 H.264 or HEVC ran out of CPU and memory with no error), so no GStreamer row maps to it | 4001 or 4003 over 1100/1101, 4006; and (RULED 2026-09-30) 4001 or 4003 from a player that never readied while other players are open, which is how the emulator pool reports running out (4003 over CodecException 14 or -19 at the 15th player, docs/traps.md) |

Measured 2026-09-30: WinUI's `MediaPlayerError` is `SourceNotSupported` for a
refused port, an unresolvable host, a 404 and an unknown container alike, so
its reason comes from `ExtendedErrorCode`. On Apple a DASH manifest from a
server that ignores `Range` reports -11850, a `network` code, so a `.mpd` or
`application/dash+xml` source is `unsupported_container` from the capability
query before it is loaded.

**The capability query answers from the same knowledge.**
`can_play(mime, codecs)` (ruling 1, §8) is true exactly when loading that
media would not publish `unsupported_codec` or `unsupported_container`:
Apple asks `AVURLAsset.isPlayableExtendedMIMEType` and, for AV1,
`VTIsHardwareDecodeSupported`; WinUI `CodecQuery` for the decoder and a
fixed container list; GTK the GStreamer registry for a demuxer and a
decoder that sink the caps a missing-plugin message would name; Android
`MediaCodecList` for the decoder and media3's extractors and modules for
the container. Every leg asserts the query against its own outcome, so the
two cannot drift.

**The test assets.** A python generator in tools (the kaya_gate prelude,
FFmpeg run inside the dev shell as a development tool only; no FFmpeg in
any shipped artifact) writes the files the probe used: 160x90 at 25 fps
of the flat asymmetric colour C83C1E, a 440 Hz tone, a second audio track
at 660 Hz tagged `fra` beside the first tagged `eng` (so a later audio
check can tell the tracks apart by pitch), 2 s each, the two-cue
`captions.vtt`, and the HLS and DASH trees with hand-written master
playlists. About 830 KB, bytes deterministic only with `+bitexact` given as
OUTPUT options and the Ogg serial pinned (measured). The bytes are
committed as a new `media` family under guests/assets with its README, and
the generator's `--check` regenerates and compares against the flake-pinned
FFmpeg. check-assets' census must include the family, so
tools/scenes/assets.steps' frozen listing and the root floor move with it,
and every lane stages it by hash like the rest of the root. On Android the
local items are APK assets (`asset:///`).

**The local server.** One python script in tools, never the internet,
honouring `Range` and serving the manifest and segment MIME types. Each
lane runner starts it before its media legs and stops it after, showing the
process gone. The mac and the iOS simulator reach it at 127.0.0.1 (the
simulator shares the host's network; loopback needs no App Transport
Security key, measured 2026-09-30 for AVPlayer and URLSession alike); the emulator at 10.0.2.2, the host's loopback,
with cleartext allowed for that host alone in the test app's network
security config; the Windows VM at the host's bridge address 192.168.64.1,
the server bound there; the linux lane runs it inside the container on
127.0.0.1, or reaches the host's loopback-bound server as
`host.docker.internal`. Each route measured 2026-09-30 with a full fetch
and a Range fetch; neither binding is reachable from the LAN, and this
host's application firewall is off, so no prompt appears.

**The scenes**, shared verbatim by every lane:

- `media_formats`: every file as a local source. Each step loads, expects
  `ready`, duration 2000 ms and media size 160x90 (0x0 for audio) within a
  stated tolerance, plays, expects the position past 1000 ms and `ended`.
- `media_delivery`: `h264_aac.mp4` over progressive HTTP, both HLS trees,
  DASH; then a 404 expecting `failed(not_found)`, a missing local file
  expecting the same, and a refused port expecting `failed(network)`.
  Measured 2026-09-30, the refused port fails in 0.1 s on Apple, under
  0.2 s on GStreamer, 4.7 s on media3 and 16.3 to 16.6 s on WinUI (its HTTP
  source retrying; the TCP stack alone refuses in 2 s), past the harness's
  15 s expect window, so that step's shape is unsettled (below).
- `media_tracks`: the two-track files and HLS expect audio `en, fr`,
  select `fr` and read it back; the tx3g, sidecar and HLS subtitle items
  select the caption track and expect cue text "first cue" at 500 ms and
  "second cue" at 1500 ms, never the look (§3). Built: the player paused at
  each time (the platform's own cues arrive after a paused seek, measured),
  the sidecar also played through, and `expect_caption` reading what kaya's
  renderer drew; `{captions:<item>|<line>}` expands to `captions none` where
  a lane's table says the item's embedded track is not exposed (the tx3g
  item on Windows).
- `media_feed` (§7b): a scroll of stamped rows, each a video view bound to
  its row's player, its first and last rows' visibility read as the app
  hears it, and the picture read in the first and last rows.

Per mode, following ruling 2 (§8): on the video view, the colour by window
capture where the picture is readable (Apple, GTK; WinUI after §6.1), and
on Android the device's own screencap (amended 2026-09-30, ruling 2 below);
on the surface, the colour read
back as a canvas is, with a tolerance stated for video (iOS decoded C93C1E,
GTK 2B374D for 2C3B4F). Audio items assert state, position and `ended`.

**The depth's scenes read the tables this way.** A summary line per item,
written by the guest from its readings, and `{media:<item>|<the line where it
plays>}` in the expectation: each harness expands it to `failed <reason>,
can_play no` where its own lane table names the item, and to the scene's text
everywhere else, so one scene serves five lanes and the table lives with the
platform. The suite gained `vp9_aac.mp4` (VP9 in MP4), the mac's own quiet
case: AVFoundation reaches ready and plays its audio with no picture, and the
decodability check fails it (measured, docs/traps.md).

**Lane tables: an item a platform cannot play is a tested failure, never
a drop.** Each lane's table names the items it expects to fail, with the
reason, and there the leg asserts that `failed(reason)` and a false
`can_play` instead of playback:

- macOS and iOS: the four WebM files and DASH, `unsupported_container`,
  and `vp9_aac.mp4`, `unsupported_codec`;
  on the simulator also `av1_aac.mp4`, `unsupported_codec` (the one kaya
  must synthesize). The sidecar WebVTT plays, its cues drawn by kaya
  (§3).
- Windows: none. The runner reads the installed Store packages and refuses
  naming a missing extension, so a rebuilt VM is not read as a kaya bug
  (without them the video items play their audio alone, silently). The
  tx3g item's caption track is expected absent (settled below).
- Linux: none once the image adds `gstreamer1.0-plugins-bad`,
  `gstreamer1.0-libav` (`avdec_h264` and `avdec_h265` over openh264 and
  libde265) and `gstreamer1.0-gtk4` for the sink; `-ugly` adds nothing.
  Two negative legs demote an element with `GST_PLUGIN_FEATURE_RANK`
  (`av1dec` on the AV1 WebM, `tsdemux` on the TS stream) and must see
  `failed`, the watched red for the audio-only and stall cases.
- Android: none.

**Settled 2026-09-30.** tx3g, RULED by the maintainer (option a): captions
embedded in an MP4 (tx3g, a 3GP or QuickTime text track) are NOT in the
guaranteed set. Media Foundation's MP4 source exposes no text track for them,
while a sidecar WebVTT or SRT through `TimedTextSource` delivers cues; so the
capability query answers no for MP4-embedded captions on Windows, the Windows
table expects the tx3g item's caption track absent, and an app wanting
captions everywhere ships them as a sidecar file or inside HLS. kaya does not
parse MP4 text samples itself. The refused-port step waits longer than an
ordinary expect (WinUI takes about 16.5 s, past the 15 s window), rather than
depending on a resolver answering for an `.invalid` host. Public streams (docs/probes/media-suite-2026-09-29.md) add one
Windows caution beyond the suite: Apple's TS bipbop HLS never starts and its
fMP4 HLS opens only after 12 s, while the local trees play at once.

**It grows into the player demo.** The suite's guest (Rust at depth, every
binding at breadth) is a small player: the item list, a video view, play,
pause, audio and caption pickers and the `failed(reason)` line.

## §7b. A video view in a collection row (RULED 2026-09-30)

A row binds a player through a player-valued field, as it binds a picked
file; each row's video view shows its own player. A player is shown by at
most one video view at a time on every platform: the root refuses a second
view naming both, so media3's and WinUI's one-surface players and AVPlayer's
many-layer one behave alike. The video view reports its visibility (entering
and leaving the viewport, and the fraction shown), so an app keeps players
only for the rows on screen and plays the most visible one, the feed-app
pattern; kaya chooses nothing for the app. Running out of hardware decoders,
which phones reach at a handful of players, fails with the reason
`resources` rather than a black view.

**A picked file (RULED 2026-09-30, built).** `source` and `captions` take a
picked file as its handle, an I64 on the wire, which the core resolves where
the picked table lives, the clipboard's rule: a picked path is checked like
any path, and a file the platform names only by its own reference (an Android
`content://` URI, the iOS picker's URL) is handed to the player as that
reference. media3 reads a content URI through its DataSource; the iOS arm
opens the picker's own URL object with its security scope held until the item
is replaced. A platform that cannot open it fails the player with its reason.
A picked sidecar is read through the picked file's own open. media_picked
picks a clip through each platform's picker and plays it.

**Built at depth (2026-09-30).** The player is a video view's `player`
prop (PropKind::Player, an id, 0 for none) in both zones: a constant, or a
row's player field (in Rust a `PlayerId` or `Option<PlayerId>` field). The
core lowers it to the backend's `set_video_player` and holds the one-view
rule on each transaction's END state, so rows trading players in one
transaction is one move; the refusal names both views, a stamped one by its
template node and keys. A row still naming a released player shows nothing
(the app replaces it when the row comes back into view); an id never created
is refused. A view whose player has no picture (no item, or an item with
no video track) shows nothing, as a released player's does, on all five;
`expect_video_ink <video> "none"` reads its centre against the window's
ground 8 points right of it. Visibility is reported by the backend as often as the view's
geometry moves (on SwiftUI its frame against every scroll viewport it sits
in) and coalesced by the core into bands: entering, each tenth shown,
shown whole, leaving; a copy torn down while shown is heard leaving.

## §7c. The bound on an open and a seek (RULED 2026-10-01)

The maintainer's ruling on the WinUI adaptive stall (docs/traps.md, the WinUI
adaptive pipeline that goes idle; docs/deferred.md's media WATCH):

(a) TESTS: on the Windows lane every media_delivery and media_tracks leg runs
alone between drains (tools/lib/lanes/win.py, the reason beside the blocks),
since the stall was measured only with media guests running beside each other:
about 1 in 12 legs six wide, 1 in 48 two wide, 0 in 48 one at a time.

(c) PRODUCT: an open that has not readied, or an app's seek that has not
completed, `TIMEOUT_MS` after it was asked FAILS THE PLAYER with the reason
`timeout`, the same on all five platforms and in all nine bindings; the app
decides whether to retry, and kaya never rebuilds a player by itself. What was
chosen, and why:

AMENDED 2026-10-05 (the maintainer): on WinUI alone, the one shape Media
Foundation was measured losing — an adaptive source whose every download has
answered, whose MediaSource reads Opened and whose session still reads Opening
5 s after the hand-over — is rebuilt ONCE by the arm, inside the same 30 s
bound, and the leg's log says so (crates/kaya/src/winui/media.rs,
`rebuild_stalled`; tools/check-verbs.py holds the shape, the once and the
bound). It recurred with the delivery legs already serial (docs/traps.md).
The app still sees only `loading` then `ready`, or `timeout` at the bound;
every other stall stays the app's to retry.

AMENDED 2026-10-06 (the maintainer), (a) TESTS: the Windows lane runs the
media_delivery legs two at a time, since an open lost under that pairing is
rebuilt; media_tracks stays alone, its lost paused seek having no recovery.

- THE REASON is a new entry, `timeout` (7), in the closed vocabulary. None of
  the six fits honestly: the depth's ceiling had called a stall `network` for
  a remote source and `unsupported_container` for a local one, and the WinUI
  stall had every byte in the process while GStreamer's missing demuxer is a
  container problem whatever the URL. kaya knows only that the platform said
  neither yes nor no; `detail` names the open or the seek and the bound.
- THE BOUND is 30 s (`KAYA_MEDIA_TIMEOUT_MS`), a plain deadline from the ask.
  The slowest real open measured is 12 s (Apple's public fMP4 HLS on Windows,
  §7a's settled paragraph), and the slowest platform failure the suite relies
  on is WinUI's refused port at 16.5 s, which must stay `network`; the
  depth's 20 s left that 3.5 s. "No progress for N seconds" is not
  measurable on every backend (Media Foundation's progressive source and
  AVFoundation raise no live download events), so it is not offered. A
  server that accepts and never answers is a transport failure the platforms
  name themselves, at different times: GStreamer's souphttpsrc failed it
  `network` before the bound (measured on both linux protocols, 2026-10-01),
  while media3, WinUI and AVFoundation said nothing for 30 s (AVFoundation
  nothing for 60 s). That is the platform's answer and stands.
- NO PROP. An app that wants less watches `loading` with its own timer and
  releases or replaces the source; no app can ask for more, which is stated
  here rather than surfaced in nine bindings.
- THE SEEK HALF is the stall's second face (a paused seek that never
  completes, the media_tracks "missing cue"). The clock runs from the LATEST
  app seek and any seek report stops it, because AVFoundation reports only a
  seek that finished, so a superseded seek's report never comes. A seek asked
  while the item still opens is covered by the open's bound first.
- THE CORE DECIDES (crates/kaya/src/media.rs): it stamps the source's
  hand-over and each app seek with its own clock. Each backend arms one timer
  of the bound after handing over a source and after every seek, which only
  wakes the core (`kaya_player_overdue`), and the core answers 1 when that
  wake failed the player; the backend then tears its item down through its
  own empty-source path: AVPlayer's item replaced and its asset's loading
  cancelled (AVFoundation opens no next item on a host while one hangs,
  measured, docs/traps.md), ExoPlayer stopped and cleared, the playbin set to
  NULL, and on WinUI the source cleared and closed.

media_timeout (Rust, all five lanes) loads a source tools/media-server.py
sends one byte every 2 s (its `/trickle/` prefix: no transport times out,
and the log says when the client lets the connection go), reads `failed
timeout`, and plays the floor file on the same player, the app's retry. tools/check-verbs.py holds each arm's wake
and teardown; the core's unit tests hold the clock.

## §8. The follow-on rulings

All six were RULED by the maintainer on 2026-09-29 as recommended below;
the fourth is ruled "research first", so its final ruling waits for that
pass.

1. **The codec floor.** RULED 2026-09-29, as recommended: state H.264 video with AAC audio in
   MP4 as the floor every platform plays with no extra install, and ship
   a capability query (`can_play(mime, codecs)`, the web's
   `canPlayType`) so an app can offer more where the platform has it
   (Apple plays no VP9 or WebM; Windows lacks HEVC without a Store
   extension).
2. **What a video scene may assert per mode.** RULED 2026-09-29, as
   recommended: geometry,
   state and timing everywhere; on the video view a pixel check by window
   capture where the picture is readable (Apple by window id, compared in
   a stated colour space with a tolerance wider than ±1; GTK through its
   own renderer; WinUI only if §6.1 says `PrintWindow` sees it); on
   Android's video view a frames-arriving signal instead; on the surface
   the pixels exactly, as a canvas. AMENDED 2026-09-30: Android's video
   view is read from the device's own screencap, as iOS's is, within the
   emulator's measured 14; frames arriving passed a feed whose every row
   was black (docs/traps.md) and stays as the read's diagnostic line.
3. **Filmstrips.** RULED 2026-09-29, as recommended: a canvas `draw_image` op, so a timeline
   draws its filmstrip, waveform and playhead in one canvas; a row of
   image widgets remains the fallback that works today.
4. **Thumbnail and waveform extraction.** RULED 2026-09-29: RESEARCH
   FIRST. A short research pass comes before the ruling, pricing the platform APIs per backend
   (`AVAssetImageGenerator`, media3's frame extraction, a GStreamer
   `appsink`, `MediaComposition.GetThumbnailsAsync`, and the audio
   decode each needs for peaks) against FFmpeg, whose licence depends on
   the build: LGPL 2.1 without `--enable-gpl`, GPL with it, not
   redistributable with `--enable-nonfree`, and on iOS the LGPL's
   relinking clause is hard to meet (docs/probes/video-playback-2026-09-02-decoders.md §B6).
   RULED 2026-10-02 after the research (docs/probes/media-extraction-2026-10-01.md):
   one kaya call over each platform's own frameworks, no FFmpeg, through a
   READER object separate from the player: `frames(times, max size,
   keyframe|exact)` answers each time with the requested and the actual time
   and a kaya-held premultiplied RGBA8 image the canvas `draw_image` op
   draws (ruling 3), and `peaks(samples_per_pair)` decodes on the platform
   and computes min/max pairs in the core; cancellation through the
   binding's own async cancel or closing the reader; failures from the
   player's closed vocabulary.
   **Built at depth (2026-10-02, docs/deferred.md's reader BUILD entry).** The
   op is the draw_op enum's `image` (8; every member of that enum is a draw
   op), `i64 image, f64 x, f64 y, f64 w, f64 h` in the viewbox, rasterized by
   the core into the canonical raster like every other op. An image is a
   core-held premultiplied RGBA8 picture with a guest-chosen id: a
   `read_frames` reserves one per time (`first_image + i`), and `load_image`
   decodes an asset or a picked file IN THE CORE (PNG and JPEG), because one
   decoder on five platforms is what keeps a drawing naming it one hash; a
   load that fails answers `image_loaded` with a reason, never a refusal, so a
   user's file cannot crash the app. `release_image` frees the id; a drawing
   declared earlier keeps its pixels until it is declared again, and a drawing
   naming a released, failed, still-pending or unknown image is refused with
   the sentence for which. The bound (§7c) runs from the ask or the latest
   answer, so a long exact read is not cut off while it answers. The peaks'
   pairs are pulled with `kaya_reader_peaks` (a ring record holds 32 KB; ten
   minutes of stereo at 480 samples a pair is 240 KB).
   **Built on all five and in all nine bindings (2026-10-02, the breadth
   slice).** GTK runs a playbin3 per read whose flags select the one stream
   type before any decoder; WinUI Media Foundation's source reader with the
   video edit list applied by kaya; Compose MediaExtractor's sample times and
   MediaMetadataRetriever's picture. GTK and WinUI hand kaya the decoded
   YCbCr and kaya converts it through the stream's own matrix and range
   (GStreamer's videoconvert read the 505050 band as 4E4E4E), and the
   frames the platform hands at full size are fitted to `max_size` by one
   core rule. A read for a track the source lacks (frames from tone.mp3,
   peaks from h264_noaudio.mp4) answers `no_track`, RULED by the maintainer
   2026-10-02: the eighth reason in the closed vocabulary, decided in the
   core (crates/kaya/src/reader.rs's `NO_TRACK`) from the one site per
   backend that reports the case, while a decode that fails on a track that
   is there still answers `decode_error`. THE PLAYER NEVER ANSWERS IT: a
   player plays whatever tracks its source has, so a video view on an
   audio-only source shows nothing and plays the sound, and a video with no
   audio plays silently (§7b), neither a failure; a source with no track the
   platform can play at all is already `unsupported_codec` or
   `unsupported_container`. So no row of §7a's table maps a platform code
   to `no_track`, and the vocabulary stays one enum the two objects share
   rather than two. After a cancel or a
   close the app hears only `reader_done(cancelled)`: the core drops later
   reports and the binding drops answers already in its channel, releasing
   the images they carried. On Apple the frames come from
   `generateCGImagesAsynchronously` with tolerance-after zero for `keyframe`
   (the default is the nearest, measured), the PCM from AVAssetReader at the
   track's own channel count. tools/scenes/media_reader.steps draws a
   filmstrip and a waveform; the waveform's hash is derived from the core.
5. **The one test clip.** RULED 2026-09-29, as recommended: one short H.264/AAC MP4, a flat
   asymmetric colour with an audio track (Android's media keys need one),
   shared by all five lanes under guests/assets, after checking the
   emulator pool plays it with the audio track present.
6. **The name of the choice between the view and the surface.**
   RULED 2026-09-29, as recommended: no setting on `video` at all; the kind is the choice, so
   an app writes `video(player)` for the view and `surface(player)` for
   frames mode, and the surface's other producers read the same way.
