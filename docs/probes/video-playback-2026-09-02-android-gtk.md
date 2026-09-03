# Video widget research — ANDROID (Compose/media3) and LINUX (GTK4)

Research date: 2026-09-02. Every claim carries a URL. Primary sources preferred.

---

# PART A — ANDROID

## A1. State of androidx.media3 in 2026

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

### The Compose story (this is the important part for kaya)

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

## A2. SurfaceView vs TextureView vs SurfaceTexture

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

### The mechanism (why the z-order trap exists)

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

### Has modern Android fixed it?

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

### Compose 1.7+ `AndroidExternalSurface` / `AndroidEmbeddedExternalSurface`

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

## A3. The Player API surface (what kaya's `video` kind can expose)

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

### Seek precision — this is a real semantic divergence risk

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

## A4. Codec coverage on Android, and the emulator question

### What the platform guarantees

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

### What ExoPlayer adds in software

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

### The emulator (this project's CI lane)

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

## A5. Frame extraction / thumbnails

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

## A6. Android traps

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

# PART B — LINUX / GTK4

## B7. GtkVideo / GtkMediaFile / GtkMediaStream / GtkMediaControls

### GtkVideo — read the class description before designing anything

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

### GtkMediaStream — the whole app-facing control surface

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

### GtkMediaFile

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

### GtkMediaControls
https://docs.gtk.org/gtk4/class.MediaControls.html — "Shows controls for video
playback", `gtk_media_controls_new(stream)`, `media-stream` property. "Usually,
GtkMediaControls is used as part of GtkVideo." It is a separate widget, so kaya
can attach it deliberately or never.

---

## B8. The GStreamer dependency, and what happens in a minimal container

### Backend selection

`GTK_MEDIA` (https://docs.gtk.org/gtk4/running.html):

> "Specifies what backend to load for `GtkMediaFile`. The possible values depend
> on what options GTK was built with, and can include 'gstreamer' and 'none'.
> **If set to 'none', media playback will be unavailable.** The special value
> 'help' can be used to obtain a list of all supported media backends."

Note the current doc lists only **gstreamer** and **none** — `ffmpeg` is gone.

### `gtk4-media-ffmpeg` is REMOVED

GNOME/gtk MR **!6872 "Drop ffmpeg support"**, opened by Matthias Clasen
2024-02-10, closing issue #5581:
> "The experimental ffmpeg media backend hasn't been building for a year, and
> nobody showed up with a patch to make it build again."
https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/6872
It landed for **GTK 4.14** (packagers' notes for 4.14.1 record the backend as
removed upstream, e.g.
https://git.openembedded.org/openembedded-core/commit/?id=9d6923da5564d45bbf80fd722184e87b4a2be867).
**GStreamer is the only media backend GTK4 ships today.**

### What the app sees when the module is missing — GOOD NEWS, it is not silent

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

### Which pieces the container actually needs

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

## B9. Codec coverage on Linux

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

### Hardware decode

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

## B10. Embedding — GtkVideo is a NORMAL WIDGET (the good news)

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

### The one place a hole reappears: graphics offload

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

## B11. The alternative Rust-native route: gstreamer-rs + gtk4paintablesink

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

# PART C — SYNTHESIS FOR THE `video` KIND (my slice's view)

## C1. The two platforms are architecturally OPPOSITE, and that is the design's hardest fact

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

## C2. The property/verb surface that exists on BOTH

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

## C3. CI / harness implications (the part most likely to burn a matrix)

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

## C4. New dependencies each platform adds

- **Android**: `androidx.media3:media3-exoplayer:1.11.0` +
  `androidx.media3:media3-ui-compose:1.11.0`. That is all — no NDK decoder
  extensions, no material3 module (kaya draws its own controls, if any),
  no media3-session, no foreground service. Two Maven coordinates.
- **Linux**: GTK's `libgtk-4-media-gstreamer` module plus GStreamer core +
  plugins-base + plugins-good (and libav or openh264 only if H.264 is wanted).
  If kaya takes the gstreamer-rs route instead: the `gstreamer` /
  `gstreamer-video` crates in the Rust core (behind the linux cfg) plus
  `gst-plugin-gtk4`'s `libgstgtk4.so`.

## C5. Open questions worth putting to the maintainer

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
