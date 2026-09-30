# Native video views and system transport — Android (Compose) and Linux (GTK 4)

Research date 2026-09-29. Scope: reconsidering docs/video-editor-plan.md §2-§3
(headless player -> kaya image widget) in favour of THE PLATFORM'S OWN VIDEO
VIEW plus native media keys / system transport controls. Builds on, and does
not repeat, docs/probes/video-playback-2026-09-02-android-gtk.md and
docs/probes/video-probe-android-2026-09-03.md; where this file re-checks a
claim from those, it says so.

Written progressively; sections fill in as they are researched.

---

## 0. What kaya's pins can reach (measured from the artifacts, not assumed)

kaya's Android library (android/kaya/build.gradle.kts, android/build.gradle.kts):
compileSdk 36, minSdk 26, AGP 8.7.3, Kotlin 2.0.21, compose-bom 2024.10.01 with
foundation pinned at 1.11.4. (The video probe app is older: compileSdk 35,
media3-exoplayer 1.6.1.)

media3 release line (https://developer.android.com/jetpack/androidx/releases/media3):
1.10.0 (2026-03-26), 1.10.1 (2026-05-12), 1.11.0 (2026-08-05), 1.11.1 (2026-09-10).

Read out of the published AARs/POMs on https://dl.google.com/android/maven2/androidx/media3/
and the tagged sources (github.com/androidx/media, tags 1.9.4 / 1.10.1 / 1.11.0):

| media3 | minCompileSdk (aar-metadata) | Kotlin it is built with / stdlib it pulls | compose BOM ui-compose pulls | build AGP |
|---|---|---|---|---|
| 1.9.4 | 35 | 2.0.20 | — | 8.12.3 |
| 1.10.1 | **36** | **2.0.20** (kotlin-stdlib 2.0.20) | 2024.12.01 (foundation 1.7.6) | 8.12.3 |
| 1.11.x | 36 | **2.2.0** (kotlin-stdlib 2.2.10) | 2026.05.00 | 9.0.1 (libs.versions.toml) |

**Verdict: 1.10.1 is the highest media3 the kaya pin can take as it stands.**
compileSdk 36 satisfies its minCompileSdk, its Kotlin metadata (2.0) is readable
by kaya's 2.0.21 compiler, and its foundation 1.7.6 is below kaya's pinned
1.11.4, so Gradle resolves up and nothing drags the Compose stack. 1.11 is a
toolchain migration: Kotlin 2.2 metadata cannot be read by a 2.0.21 compiler
(https://kotlinlang.org/docs/kotlin-evolution-principles.html: "the binary
format is mostly forwards compatible with the next language release, but not
later ones … 1.9 can understand most binaries from 2.0, but not 2.1"; so 2.0.21
reading 2.2 binaries is outside even the best-effort promise), and BOM 2026.05 would
move compose-ui, which the rich-text pin keeps still. So the Compose `Player`
composable and `ProgressSlider` (1.10) are reachable; `MiniController`,
`ErrorState`, `PlayerPool` (1.11) are not without the migration. (Not built;
this is read off the artifacts' metadata. A resolve/compile of 1.10.1 against
kaya's toolchain is the confirming step and is cheap.)

**No Compose caption composable exists in media3 at 1.10.1 or 1.11.0**: a grep of
libraries/ui_compose and libraries/ui_compose_material3 at both tags for
subtitle/Cue finds nothing; captions are rendered only by the View-based
`androidx.media3.ui.SubtitleView` in media3-ui
(libraries/ui/src/main/java/androidx/media3/ui/SubtitleView.java).

**Measured, not only read:** a copy of tools/android/videoprobe (scratch dir
`androidprobe/`, the repo untouched) moved to compileSdk 36 with
`media3-exoplayer`, `media3-ui-compose` and `media3-session` 1.10.1 and
foundation 1.11.4 builds with kaya's AGP 8.7.3 / Kotlin 2.0.21 in 22 s, and
`:app:dependencies` resolves foundation and compose-ui to 1.11.4 (up from
ui-compose's 1.7.6), material3 1.3.1 (the version kaya already ships),
kotlin-stdlib 2.1.20 (already what foundation 1.11.4 pulls). So 1.10.1 costs
kaya no toolchain move.

---

# ANDROID

## 1. The native views: which are composited, which are holes

### The four candidates

| view | what it is | composited by the app's renderer (HWUI)? |
|---|---|---|
| media3 `PlayerView` (media3-ui) | a View: `AspectRatioFrameLayout` + surface + `SubtitleView` + controller; `surface_type` = `surface_view` (default) / `texture_view` / `spherical_gl_surface_view` / `video_decoder_gl_surface_view` / `none` (https://developer.android.com/media/media3/ui/surface) | depends on surface_type |
| media3-ui-compose `PlayerSurface(player, modifier, surfaceType)` | `AndroidView` wrapping a real `SurfaceView` (default `SURFACE_TYPE_SURFACE_VIEW`=1) or `TextureView` (`SURFACE_TYPE_TEXTURE_VIEW`=2), plus a SurfaceSyncGroup workaround on API 34 only (source, tag 1.10.1: libraries/ui_compose/src/main/java/androidx/media3/ui/compose/PlayerSurface.kt) | SurfaceView: no; TextureView: yes |
| Compose `AndroidExternalSurface` | "a dedicated drawing Surface as a separate layer positioned by default behind the window" — a SurfaceView; `zOrder` Behind/MediaOverlay/OnTop, `isSecure` | no (a hole) |
| Compose `AndroidEmbeddedExternalSurface` | "positions its surface as a regular element inside the composable hierarchy … graphics composition is handled like any other UI widget, using the GPU" — a TextureView | yes |

(The two Compose surfaces: https://developer.android.com/reference/kotlin/androidx/compose/foundation/package-summary ,
mirrored at https://composables.com/docs/androidx.compose.foundation/foundation/composable-functions/AndroidExternalSurface .)
media3 itself says not to hand ExoPlayer the Compose proxies: "Those views are
needed by the Player to handle a full lifecycle of the surface (creation and
size updates)" (https://developer.android.com/media/media3/ui/surface) — which
is why kaya's own §2 design passed a raw `Surface` from a `SurfaceTexture`
instead; `PlayerSurface` is the supported route for a platform view.

**Controls are separable on every route.** `PlayerSurface` carries none (the
source above has no controller); `PlayerView.setUseController(false)` hides
PlayerView's. So "use the platform's video view, draw kaya's own controls" is
directly supported on Android: the view is `PlayerSurface`, the controls are
kaya widgets. (media3's own Compose controls — `Player`, `ProgressSlider`,
material3 buttons — are optional state-holder composables, not part of the
surface.)

### SurfaceView: what the synchronisation fixes and what it still does not allow

From the class javadoc (AOSP core/java/android/view/SurfaceView.java,
https://raw.githubusercontent.com/aosp-mirror/platform_frameworks_base/main/core/java/android/view/SurfaceView.java ; the
aosp-mirror "main" is a snapshot, so newer-than-16 behaviour may be missing):

- The model: "The surface is Z ordered so that it is behind the window holding
  its SurfaceView; the SurfaceView punches a hole in its window … The view
  hierarchy will take care of correctly compositing with the Surface any
  siblings of the SurfaceView that would normally appear on top of it … though
  … a full alpha-blended composite will be performed each time the Surface
  changes." And: "If the post-layout transform properties are used to draw a
  sibling view on top of the SurfaceView, the view may not be properly
  composited with the surface."
- **API 24 (N):** "SurfaceView's window position is updated synchronously with
  other View rendering. This means that translating and scaling a SurfaceView on
  screen will not cause rendering artifacts." (This is what media3's surface
  page means by "not properly synchronized with view animations until Android
  7.0".) So SCROLLING and MOVING a SurfaceView are fine from 24; kaya's minSdk is 26.
- **API 34 (U):** "SurfaceView will support arbitrary alpha blending. Prior
  platform versions ignored alpha values … between 0 and 1 … If … Z-below, then
  the alpha is applied to the hole punch directly." So a fade works from 34, not 26-33.
- **API 34:** `setSurfaceLifecycle(SURFACE_LIFECYCLE_FOLLOWS_ATTACHMENT)` keeps
  the surface across visibility changes; PlayerView uses it from 14 "to improve
  surface availability in scrolling UIs"; before 14 the surface is torn down on
  invisibility, so playback in a recycled list row "can take longer"
  (https://developer.android.com/media/media3/ui/surface). `PlayerSurface` at
  1.10.1 does NOT set it (no call in the source).
- **Render-thread driven clipping** (current source, behind the hwui flag
  `clipSurfaceviews`): the RenderThread computes the SurfaceView layer's crop
  from the view's clip each frame and applies overscroll stretch
  (`setCrop`/`setStretchEffect` in `SurfaceView.java`'s position-update callback),
  so rectangular clips (a scroll viewport) follow the surface. A rounded corner
  on the surface itself is `setCornerRadius`, which is `@hide`.
- **Still not allowed:** interleaving (the surface is either behind the whole
  window or above it; `setZOrderOnTop` puts it above EVERY view in the window,
  `setZOrderMediaOverlay` orders only among SurfaceViews; the flagged
  `setCompositionOrder(int)` in current source is the same two-bucket model with
  an order among peers); a sibling drawn with a post-layout transform over it;
  any effect that must read the video's pixels (blur, colour filter, a
  `graphicsLayer` render effect) — the video is not in the app's buffer.

### MEASURED on the lane's pool (api 35 arm64 `sdk_gphone64_arm64`, swiftshader via ANGLE; emulator-5562, one phone, nothing rebooted)

Probe: `PlayerSurface` at media3 1.10.1, both surface types, inside a 288x216 dp
box with `Modifier.clip(RoundedCornerShape(72.dp))`, on a magenta ground, with an
opaque green Compose box drawn OVER the centre of the video.

- **Rounded clip and a view drawn over it work with the SurfaceView route** in
  the SurfaceFlinger composite (screencap, android-runs/ps-surface-round-crop.png):
  the clip's colour inside a correctly rounded rectangle, the green box on top,
  magenta in the corners. Mechanism (read off `clearSurfaceViewPort` in the
  source): the hole is a `canvas.punchHole` draw op, so it obeys the canvas clip
  — the corners stay the window's opaque magenta, which hides the surface behind
  them. It works because the content under the corners is OPAQUE; over a
  translucent ground the video would show through the corners.
- **The same layout on the TextureView routes** (`PlayerSurface` TEXTURE_VIEW
  and `AndroidEmbeddedExternalSurface`) shows the same rounded shape and green
  overlay, composited by HWUI.
- **Presentation on this pool is unreliable on EVERY route** (20 screencaps, 0.5 s
  apart, pixel inside the video): `AndroidEmbeddedExternalSurface` 13/20 showed
  the clip (`2D3B50`), `PlayerSurface` TEXTURE_VIEW 0/20, `PlayerSurface`
  SURFACE_VIEW 0/20 in that batch, a hand-made SurfaceView 2/20 — and those two
  read `3D4A5F`, not the clip's `2C3B4F`: about +17 per channel, the signature of
  limited-range YUV shown without expansion (the emulator's composer path, not
  kaya). An earlier single SurfaceView screencap in the same session did show
  the clip. The decoder ran on every run (`c2.goldfish.h264.decoder`, first frame
  268-616 ms). This extends the 2026-09-03 probe's finding (presentation, not
  decode, is what the software-GPU pool cannot do) to `PlayerSurface` at 1.10.1.

## 3. Can a test read the pixels?

Measured on the same phone, same probe (android-runs/*.log):

- **kaya's window `PixelCopy.request(window, …)`** over a SurfaceView route:
  every sample inside the video read `000000` while the green Compose overlay
  read `00FF00` and the clipped corner `FF00FF` — the window copy sees the app's
  own layer (the punched hole plus whatever is drawn over it), never the video.
  Confirms the 2026-09-03 finding on `PlayerSurface` (the earlier probe
  measured alpha 0 at the hole; this run sampled alpha only at the overlay).
- **`PixelCopy.request(SurfaceView, bitmap, …)`** (the SurfaceView overload,
  API 24, which reads the surface's own buffer): 5/5 answered SUCCESS with opaque
  `000000` on this pool — so on the lane it is no better. Whether it reads a real
  device's decoder output is not measured here (and for DRM content it cannot:
  a secure surface is excluded from screenshots, SurfaceView.setSecure javadoc).
- **TextureView routes, window copy:** `2D3B50` (the clip, within kaya's ±1
  tolerance of `2C3B4F`) in 2 of 4 samples of one run and 0 of 5 in another —
  the same "only when a frame happens to be presented" rate as 2026-09-03.

**So on the emulator pool no route gives a deterministic ink read; a
SurfaceView route gives none at all through kaya's window copy.** A lane that
wants a pixel assertion needs `-gpu host` or a device, and then the TextureView
route or the SurfaceView-overload copy. State, timing and geometry remain
the assertable observables, as §3/§6 already concluded.

## 2. What the platform view gives for free, and what it does not

- **Captions.** Only media3-ui's View `SubtitleView` renders cues, and only
  `PlayerView` wires it; it styles from the system caption settings:
  `setUserDefaultStyle()` uses `CaptioningManager.getUserStyle()` and
  `setUserDefaultTextSize()` uses `CaptioningManager.getFontScale()`, each only
  "if CaptioningManager is available and enabled" (SubtitleView.java at tag
  1.11.0, lines 220-340; PlayerView calls both at construction, PlayerView.java
  ~552-555). `media3-ui-compose` has **no caption composable** at 1.10.1 or 1.11
  (grep, §0). Track SELECTION follows the system too:
  `TrackSelectionParameters` defaults
  `usePreferredTextLanguagesAndRoleFlagsFromCaptioningManager = true`
  (TrackSelectionParameters.java). So a Compose app that uses `PlayerSurface`
  gets the right caption TRACK selected but must render cues itself — either an
  `AndroidView(SubtitleView)` over the surface fed from
  `Player.Listener.onCues`, or kaya's own text drawing styled from
  `CaptioningManager`. A kaya overlay on top of a SurfaceView is legal (siblings
  on top composite, above).
- **Audio description.** media3 selects a `C.ROLE_FLAG_DESCRIBES_VIDEO` audio
  track only if the app asks (preferred audio role flags); nothing in media3's
  main sources calls `AccessibilityManager.isAudioDescriptionRequested()`
  (grep at 1.11.0 finds none). That platform API ("The method provides the
  preference value to content provider apps to select the default sound track
  during playing a video or movie", with
  `addAudioDescriptionRequestedChangeListener`; AOSP
  core/java/android/view/accessibility/AccessibilityManager.java, API 33) is the
  app's to read and feed into `setPreferredAudioRoleFlags`.
- **Picture in Picture** is WHOLE-ACTIVITY: "the entire activity window enters
  PiP, not individual views", API 26, `setSourceRectHint` (26),
  `setAutoEnterEnabled` and `setSeamlessResizeEnabled` (31),
  `onPictureInPictureUiStateChanged` (35); with an active MediaSession
  "play/pause/next/previous controls appear automatically", custom
  `RemoteAction`s otherwise
  (https://developer.android.com/develop/ui/views/picture-in-picture). So PiP
  is a property of kaya's WINDOW (hide everything but the video, hint the video's
  rect), not of the video view; it works the same whichever surface draws the
  video, and needs the MediaSession for its buttons.
- **DRM.** SurfaceView is the route media3 names for "secure output when playing
  DRM-protected content" (surface page). The mechanism: protected decoder
  buffers may be sent to a consumer only if it sets the protected usage bit;
  GPU composition of them needs `EGL_EXT_protected_content` +
  `GL_EXT_protected_textures` and a PROTECTED GL context
  (https://source.android.com/docs/core/graphics/arch-st, "Secure texture video
  playback"). A `TextureView`'s `SurfaceTexture` is consumed by the app's own
  (unprotected) HWUI context, so L1/secure-path content does not render there —
  ExoPlayer users report black TextureViews for Widevine
  (https://github.com/google/ExoPlayer/issues/9825 "drm with textureView not
  working"). media3's own `PlaceholderSurface` builds a protected EGL surface
  only "if isSecureSupported" (PlaceholderSurface.java). So: **L1 protected video
  is a SurfaceView (or a protected-EGL pipeline kaya would own), never a
  TextureView/external-texture route.** Clear (non-DRM) content and L3 software
  DRM work on both. kaya's editor has no DRM need; a media-app kaya would.
- **HDR, power, frame timing, TV full resolution:** SurfaceView gives
  "significantly lower power consumption", "more accurate frame timing",
  "higher quality HDR video output", and is required for full display resolution
  on TVs whose UI layer is upscaled (surface page). The power/HDR advantage is
  SurfaceFlinger/HWC composing the video buffer directly as an overlay plane
  (the AOSP arch page above: SurfaceView "directly composes buffers to the
  screen", https://source.android.com/docs/core/graphics/arch-sv-glsv).
- **Cast** is not a view feature: media3-cast's `CastPlayer` is a `Player`, and
  the session/UI are shared (https://developer.android.com/media/media3/cast is
  the entry point; not researched further).
- **What TalkBack sees:** measured with `uiautomator dump` on the pool: both
  `PlayerSurface` types appear only as an unnamed, non-focusable
  `androidx.compose.ui.viewinterop.ViewFactoryHolder` with bounds and empty
  `content-desc`; the SurfaceView/TextureView themselves are not in the dump.
  The platform view contributes NOTHING to accessibility; kaya's own a11y props
  on the video node (label, role) are what a screen reader would read, whichever
  route draws it.

## 4. Media keys and system transport controls

### How a key reaches a player (source)

1. The focused window gets the key FIRST (`Activity.dispatchKeyEvent`). If no
   view consumes it, the platform's fallback handler forwards media and volume
   keys to `MediaSessionManager` (AOSP
   core/java/com/android/internal/policy/PhoneFallbackEventHandler.java:
   `KEYCODE_MEDIA_PLAY_PAUSE` … → `handleMediaKeyEvent(event)`; `KEYCODE_VOLUME_UP`
   … → the session volume path).
2. `MediaSessionService` hands it to the **media button session**, chosen from
   AUDIO playback: "We send the media button events to the lastly played app. If
   the app has the media session, the session will receive the media button
   events" — the candidates are `AudioPlayerStateMonitor.getSortedAudioPlaybackClientUids()`
   (AOSP services/core/java/com/android/server/media/MediaSessionStack.java,
   `updateMediaButtonSessionIfNeeded`/`findMediaButtonSession`).
3. media3's `MediaSession` "automatically handles media button events and calls
   the appropriate Player method"; `MediaSession.Callback.onMediaButtonEvent(Intent)`
   intercepts (https://developer.android.com/media/media3/session/control-playback).
   Headsets, Bluetooth AVRCP, Assistant, Wear, the system media carousel, Auto and
   TV remotes all arrive through the session (same page's list).

### MEASURED (emulator-5562, probe with `MediaSession.Builder(this, player).build()` on a media3 1.10.1 ExoPlayer, keys injected with `adb shell input keyevent`; transcripts android-runs/keys*.txt)

| setup | `dumpsys media_session` "Media button session" | PLAY_PAUSE in foreground | PAUSE then PLAY with the app backgrounded (Home) |
|---|---|---|---|
| video with NO audio track, no session | null | reaches the Activity unhandled; player unchanged | nothing |
| video with NO audio track, session | **null** (session listed, never chosen) | reaches the Activity unhandled; **player unchanged** | nothing |
| video + (silent) AAC track, no session | null | unhandled; unchanged | nothing |
| video + AAC track, session | **the probe's session** | unhandled by the Activity, then **paused (isPlaying false at 2718 ms) and resumed (3969 ms)** | **paused (3917 ms), resumed (5147 ms)** |

- **A silent video never receives media keys**, even with a session: the button
  session is chosen by audio playback, so a clip with no audio track (or,
  presumably, a player that renders no audio) is invisible to it. An editor
  previewing a muted timeline would have to keep an audio track playing (silence)
  for the keys to work — worth stating as a platform limitation.
- **No notification** was posted in any case (`dumpsys notification --noredact`,
  0 records for the package): a bare `MediaSession` gives keys but no system
  controls. The system media controls (Android 13+ quick settings carousel)
  require one: "To make your player app appear in the quick setting settings
  area, you must create a `MediaStyle` notification with a valid `MediaSession`
  token" (https://developer.android.com/media/implement/surfaces/mobile). From
  13 their buttons are "derived from the Player state" (play/pause, previous/next
  from `COMMAND_SEEK_TO_PREVIOUS/NEXT`, custom buttons).
- **Volume keys** with the session active moved STREAM_MUSIC 5 → 6 → 5
  (`cmd media_session volume --stream 3 --get`; restored to 5, the value found),
  with the Activity not handling them. So volume keys adjust the media stream
  with no app code once audio plays.

### What media3 gives, and what an app drawing its own controls must still do

- **Session:** `MediaSession.Builder(context, player)` — keys, headset/AVRCP,
  Assistant, Wear, PiP buttons (PiP page). Must be `release()`d.
- **Background playback + the media notification + quick-settings controls:**
  a `MediaSessionService` running as a foreground service of type
  `mediaPlayback`, permissions `FOREGROUND_SERVICE` and
  `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, the service declared with the
  `androidx.media3.session.MediaSessionService` action;
  `DefaultMediaNotificationProvider` then posts and updates the `MediaStyle`
  notification automatically, and it "cannot be removed while the foreground
  service is running" (https://developer.android.com/media/media3/session/background-playback).
  On Android 13+ the notification itself needs the `POST_NOTIFICATIONS` runtime
  permission (not quoted by that page; https://developer.android.com/develop/ui/views/notifications/notification-permission).
  Playback resumption after reboot: `MediaButtonReceiver` +
  `onPlaybackResumption` (same page).
- **Audio focus:** `setAudioAttributes(attrs, handleAudioFocus = true)` and ExoPlayer
  requests/abandons focus and reacts to loss; the app "shouldn't include any code
  for requesting or responding to audio focus changes"; Android 12+ fades out the
  previous player on a `AUDIOFOCUS_GAIN` request
  (https://developer.android.com/media/optimize/audio-focus). Headphones
  unplugged: `setHandleAudioBecomingNoisy(true)` (ExoPlayer.Builder; same
  guidance). Neither is on by default — they are two builder calls.
- **Metadata:** title/artist/artwork come from the `MediaItem`'s `MediaMetadata`,
  which is what the notification, lock screen and carousel show.
- **Custom controls do not remove any of this.** The session is independent of
  who draws the transport UI: kaya's own scrubber calls the same `Player` the
  session wraps, and the system sees the same state. This is the Android answer
  to "integrate native media keys": a session over the player, plus a service if
  the app wants background audio and the system controls.

### What this means for kaya on Android

- The "platform view" on Android is `PlayerSurface` (media3-ui-compose, reachable
  at 1.10.1 on the current pins, no toolchain move), and the choice INSIDE it is
  SurfaceView vs TextureView — which is the same trade kaya already made in §3,
  now with the facts sharpened: SurfaceView brings power/HDR/DRM/frame timing and
  still honours scroll, move, rectangular clip, a rounded clip over an opaque
  ground (measured), views on top, and alpha from API 34; it breaks kaya's window
  PixelCopy (measured: reads the hole), anything that must process the video's
  pixels, and translucent grounds under rounded corners. TextureView keeps kaya's
  "a video is an ordinary widget" rule and gives up L1 DRM and the overlay-plane
  power win.
- Nothing about system integration depends on the view: MediaSession, the
  notification, PiP, audio focus and captions' track selection all attach to the
  PLAYER and the ACTIVITY. kaya can adopt all of them under the current headless
  design (§2) unchanged, or under a PlayerSurface design; the view decision and
  the transport decision are independent.
- Captions are the one place the "native view" would buy a real feature — and in
  Compose it does not: `SubtitleView` is View-only. Using `PlayerView` (View) via
  `AndroidView` is the only way to get platform-styled captions for free; with
  `PlayerSurface` kaya renders cues itself, styled from `CaptioningManager`.
- A kaya rule would be needed for silent video and media keys (measured above),
  and for what a `video` node's accessibility label is (the view contributes none).

---

# LINUX (GTK 4)

## 5. The native views, and what GTK's own backend gives

### The three candidates are all GdkPaintables; none is a hole

- **`GtkVideo`** — "Shows a `GtkMediaStream` with media controls" and "does not
  have support for video overlays, multichannel audio, device selection, or input.
  If you are writing a full-fledged video player, you may want to use the
  `GdkPaintable` API and a media framework such as Gstreamer directly"
  (https://docs.gtk.org/gtk4/class.Video.html). Its controls: a
  `GtkMediaControls` inside a `GtkRevealer`, revealed on pointer motion and hidden
  by a 3-second timeout; in fullscreen the cursor also hides after 3 s (GTK main,
  gtk/gtkvideo.c `gtk_video_reveal_controls`/`gtk_video_hide_controls`,
  `g_timeout_add_once (3 * 1000, …)`). Its properties are `autoplay`, `file`,
  `loop`, `media-stream`, `graphics-offload` — **there is no property to turn the
  controls off** (same file's property table). The documented control-free route
  is to put the stream in a `GtkPicture`: "If you just want to display a video
  without controls, you can treat it like any other paintable and for example put
  it into a GtkPicture" (class page above).
- **`GtkPicture` + `GtkMediaStream`/`GtkMediaFile`** — `GtkMediaStream` "is a
  `GdkPaintable`" (https://docs.gtk.org/gtk4/class.MediaStream.html); its API is
  play/pause/seek/loop/volume/muted/ended/error/timestamp/duration, and **no rate,
  no track or subtitle selection** (the same page; confirmed absent in GTK main's
  gtk/gtkmediastream.c).
- **`gtk4paintablesink`** (gst-plugins-rs) — a GStreamer sink whose `paintable`
  property is a `GdkPaintable` for a `GtkPicture`; GL and dmabuf zero-copy paths
  (https://gstreamer.freedesktop.org/documentation/gtk4/index.html). This is what
  GNOME's own video player uses (below).

**GTK's built-in backend is GstPlay, not a raw playbin.** GTK main's
gtk/media/gtkgstmediafile.c builds `gst_play_new (GST_PLAY_VIDEO_RENDERER (paintable))`
over its own sink (gtk/media/gtkgstsink.c: dmabuf, GL-memory and system-memory
caps), and maps GtkMediaStream onto `gst_play_play/pause/seek/set_volume/
set_mute` and the play config's loop — nothing else of GstPlay is reachable from
the public API. Driving `GstPlay`/`playbin3` yourself (with gtk4paintablesink)
adds: rate, accurate vs key-unit seek, audio/subtitle track selection, external
subtitle URIs (`suburi`), subtitle font, buffering and bus errors with detail. On
Debian the module is a separate package: `libgtk-4-media-gstreamer` — without it
`GtkMediaFile` resolves to `GtkNoMediaFile` and reports "GTK could not find a
media module. Check your installation." (measured below: with plugins-base, -good, -libav and
gstreamer1.0-gtk4 installed `--no-install-recommends`, `GtkMediaFile` was still
`GtkNoMediaFile` until `libgtk-4-media-gstreamer` was added; the 2026-09-03 linux
probe's list does not name it, so it probably arrived there as a Recommends —
not checked).

### MEASURED in the lane image (kaya-linux:latest, GTK 4.18.6, GStreamer 1.26.2, gstreamer1.0-gtk4 0.13.5; Xvfb, X11 backend; container `kaya-videonative-probe`, `--rm`)

A `GtkPicture(GtkMediaFile)` and, separately, a `GtkVideo`, each inside a
`GtkOverlay` with `border-radius: 60px` and `overflow: hidden`, a green box as an
overlay child, in a `GtkScrolledWindow`, on a magenta window; after 2.5 s the
window was rendered through its own renderer (`Gtk.WidgetPaintable` →
`GskRenderer.render_texture`) and read back:

| widget | renderer | inside the video | overlay centre | clipped corner |
|---|---|---|---|---|
| GtkPicture + GtkGstMediaFile (playing, ts 406888 µs) | GL | `2B374D` | `00FF00` | `FF00FF` |
| GtkPicture + GtkGstMediaFile | cairo (`GSK_RENDERER=cairo`) | `2B374D` | `00FF00` | `FF00FF` |
| GtkVideo (autoplay; reported playing=false ts 0 at the read, first frame shown) | GL | `2B374D` | `00FF00` | `FF00FF` |

So on GTK the platform's video view clips (rounded), is drawn over, sits in a
scroller, and **its pixels are readable by the app's own renderer** — the
property Android's SurfaceView lacks. (The value is `2B374D` against the host
ffmpeg decode `2C3B4F`: GTK/GStreamer's YUV→RGB conversion differs by up to 4
in green, so an ink assertion across platforms would need a wider tolerance
than kaya's ±1 for video, or a per-platform expected value.) GtkVideo showed no
controls in the capture because no pointer motion occurred — their visibility
is motion-driven, not a setting.

### The one hole: graphics offload (opt-in)

`GtkGraphicsOffload` (4.14) "Bypasses gsk rendering by passing the content of
its child directly to the compositor", Wayland subsurfaces only, and falls back
silently to normal rendering when clipped, rounded, transformed, filtered or
translucent (https://docs.gtk.org/gtk4/class.GraphicsOffload.html; detailed in
docs/probes/video-playback-2026-09-02-android-gtk.md B10). GNOME's player uses
it: Showtime's window is `GraphicsOffload { child: Picture picture {}; black-background: true; }`
(GNOME/showtime, showtime/gtk/window.blp). It is GTK's analogue of SurfaceView
with the difference that it degrades to composition instead of to a hole.

### Captions and DRM on Linux

- **Captions:** GStreamer's playbin renders subtitle tracks (embedded or from
  `suburi`) itself, styled by its `subtitle-font-desc`; GtkMediaStream exposes no
  track API, so captions need the direct GstPlay/playbin route. GNOME has **no
  system caption style**: gsettings-desktop-schemas (GNOME's settings schemas,
  HEAD 2026-09-29) contains no key mentioning caption or subtitle (grep). What
  Showtime does instead: `pipeline.props.subtitle_font_desc` from the GTK font
  name, rescaled on `notify::gtk-xft-dpi` so captions follow the Large Text
  setting (showtime/play.py, showtime/utils.py `get_subtitle_font_desc`);
  external subtitle files via `play.props.suburi`, track choice via
  `set_subtitle_track` / `set_subtitle_track_enabled` (showtime/widgets/window.py).
- **DRM:** GStreamer provides only the metadata framework — GstProtection lets
  "the information needed to decrypt a GstBuffer … be attached to that buffer"
  for a separate decryptor element
  (https://gstreamer.freedesktop.org/documentation/gstreamer/gstprotection.html);
  no CDM ships with it. There is no platform DRM path for a desktop GTK app.

## 6. MPRIS2 and media keys on GNOME

- **The spec (MPRIS 2.2):** "Each media player must request a unique bus name
  which begins with org.mpris.MediaPlayer2" (instances append a dot and an id),
  and expose `/org/mpris/MediaPlayer2` implementing `org.mpris.MediaPlayer2` and
  `org.mpris.MediaPlayer2.Player`; `TrackList` and `Playlists` optional
  (https://specifications.freedesktop.org/mpris/latest/). Properties change via
  `org.freedesktop.DBus.Properties.PropertiesChanged`; positions are µs.
- **GNOME Shell's media controls** (GNOME/gnome-shell main, js/ui/mpris.js,
  js/ui/messageList.js): Shell watches bus names starting `org.mpris.MediaPlayer2.`;
  a player is SHOWN only while `CanPlay` is true (`get players()` filters on
  `canPlay`); the title and icon come from the app found by `DesktopEntry`
  (`lookup_app(DesktopEntry + '.desktop')`), falling back to `Identity`; the card
  shows `xesam:title`, `xesam:artist` (must be a string array), `mpris:artUrl`,
  previous/next per `CanGoPrevious`/`CanGoNext`, and clicking raises the app via
  the desktop file before `Raise()` (focus-stealing prevention). The same source
  feeds the lock screen (js/ui/unlockDialog.js).
- **Keyboard media keys** (gnome-settings-daemon main, plugins/media-keys):
  `do_multimedia_player_action` sends play/pause/next/previous/stop to the MPRIS
  controller when it has an active player, `Rewind`/`FastForward` become `Seek`,
  `Repeat`/`Shuffle` toggle `LoopStatus`/`Shuffle`; with no player it shows the
  "action unavailable" OSD. The controller prefers a player whose
  `PlaybackStatus` is `Playing`, else the most recently appeared
  (mpris-controller.c). The legacy `org.gnome.SettingsDaemon.MediaKeys`
  `GrabMediaPlayerKeys` API is gone from the plugin (grep finds no
  `GrabMediaPlayerKeys`), so MPRIS is the only way to receive media keys that the
  focused window does not see.
- **Bluetooth headset buttons:** BlueZ turns AVRCP pass-through commands into
  kernel key events through uinput — PLAY → `KEY_PLAYCD`, PAUSE →
  `KEY_PAUSECD`, FORWARD → `KEY_NEXTSONG` (bluez master,
  profiles/audio/avctp.c `key_map`) — which then travel the keyboard path above
  to MPRIS. No app work beyond MPRIS.
- **Volume keys** change the SYSTEM output: gsd's `VOLUME_UP_KEY` →
  `do_sound_action(…, SOUND_ACTION_FLAG_IS_OUTPUT)` on the default sink
  (gsd-media-keys-manager.c). There is no per-app media stream the keys target as
  Android's STREAM_MUSIC; MPRIS's `Volume` property exists but gsd does not use it.
- **No toolkit helper.** Every GNOME app implements MPRIS itself: Showtime's
  mpris.py is copied from gnome-music's (its header cites
  gnome-music/gnomemusic/mpris.py), Decibels has src/mpris.ts, Amberol uses the
  `mpris-server` 0.8 crate (Cargo.toml; src/audio/mpris_controller.rs). Neither
  GTK nor libadwaita ships one (no MPRIS symbol in either API reference; inferred
  from these three apps each carrying their own). For a Rust host: `mpris-server`
  (zbus-based) is what a GNOME Rust app uses.
- **Flatpak:** the default session-bus policy lets an app own
  `org.mpris.MediaPlayer2.$FLATPAK_ID` without `--own-name`
  (https://docs.flatpak.org/en/latest/sandbox-permissions.html); Amberol's
  manifest indeed has no own-name arg.
- **Keep-awake:** Showtime calls `Gtk.Application.inhibit(win, IDLE, "Playing a
  video")` while playing (showtime/main.py `inhibit_win`) — the GTK analogue of
  Android's keep-screen-on, which neither PlayerView nor PlayerSurface sets for
  you (no `keepScreenOn` in either source at 1.10.1/1.11.0).

### What this means for kaya on Linux

- On GTK the "native video view" and kaya's current §2 design are the SAME
  object: a `GdkPaintable` in a `GtkPicture`. There is nothing to reconsider
  about composition — clip, rounding, overlay, scrolling and pixel read-back all
  hold (measured). The only real choice is the producer: `GtkMediaFile` (GstPlay
  underneath, five calls, no rate/tracks/subtitles) vs GstPlay/playbin3 driven by
  kaya with `gtk4paintablesink` (what Showtime does; rate, tracks, captions).
  `GtkVideo` is not usable as kaya's video kind: its controls cannot be turned off.
- System transport on GNOME is MPRIS, and it is entirely the app's job: an
  `org.mpris.MediaPlayer2.<app id>` name, the two interfaces, `CanPlay` true for
  Shell to show it, `DesktopEntry` matching the .desktop file for the card's
  name and icon, metadata as the spec types it. That one export gives the Shell
  card, the lock screen card, keyboard media keys and Bluetooth buttons at once.
  It is independent of the view, like Android's MediaSession.
- Volume keys are system volume on GNOME; a kaya `volume` prop is the stream's
  own volume, never the keys'.

## 7. How other toolkits do it on these platforms

- **Flutter `video_player` (Android)** — default is a TEXTURE: frames go to a
  `TextureRegistry.SurfaceProducer` and Flutter draws them in its own scene
  (the headless-player-into-kaya-texture shape of kaya §2). Since 2.8.0 it
  "Adds support for platform views as an optional way of displaying a video"
  (flutter/packages, packages/video_player/video_player_android/CHANGELOG.md):
  `PlatformVideoView` is a plain `SurfaceView` bound to ExoPlayer, with
  `setZOrderMediaOverlay(true)` below API 26 "to avoid blank space instead of a
  video" (…/platformview/PlatformVideoView.java). Its README: "Using
  `VideoViewType.platformView` is not currently recommended on Android due to a
  known issue" — flutter/flutter#164899, OPEN, "Video gets on top of the UI when
  using platform view and the player is scrolled out of view": "as soon as it
  disappears from the visible viewport, it punches a hole in Flutter's UI until it
  gets disposed", mainly below API 34. Supported platforms: Android (SDK 24+),
  iOS, macOS, web; **not Linux or Windows** (https://pub.dev/packages/video_player).
  Media keys/notification are a separate package (not researched further).
- **Flutter platform views (the cost of hosting any native view)** —
  https://docs.flutter.dev/platform-integration/android/platform-views :
  Hybrid Composition gives "Correct accessibility and SurfaceView support" but
  "Causes thread merging of raster & platform, which degrades Flutter FPS" and,
  before Android 10, copies every Flutter frame through main memory; Texture
  Layer Hybrid Composition renders the native view into a texture (all transforms
  work) but has "Broken accessibility for SurfaceViews" and jank on fast
  scrolling; Hybrid Composition++ lets SurfaceFlinger composite both surfaces and
  needs API 34 and Impeller on Vulkan, with the limitation that "transparent
  platform views won't display correctly" in some stacks. This is the price of
  "native view inside a toolkit that draws its own UI" on Android; Compose pays
  none of it because a SurfaceView is an ordinary Android View beside Compose's
  own (kaya's backend IS Compose, so kaya is in Compose's position, not Flutter's).
- **React Native (`react-native-video` v6, Android)** — ExoPlayer; `viewType`
  textureView / surfaceView (default) / secureView; "DRM playback is not supported
  on textureView. If the DRM prop is provided, the surface will be transformed into
  a SurfaceView", and "SurfaceView is the only one that can be labeled as secure";
  `showNotificationControls` (default false) wires the media session and
  notification; `controls` default false; `subtitleStyle` is its own styling, not
  the system's (https://docs.thewidlarzgroup.com/react-native-video/docs/v6/component/props).
  The same three-way trade as media3's, exposed to the app as a prop.
- **Qt Multimedia (Qt 6)** — "The main media backend, built on FFmpeg … is the
  default on all platforms except WebAssembly and embedded Linux/Boot2Qt";
  GStreamer remains the Boot2Qt default; "MediaCodec on Android is deprecated as
  of Qt 6.8 and will be removed in the next major release"; "New features will only
  be implemented on the FFmpeg media backend"
  (https://doc.qt.io/qt-6/qtmultimedia-index.html). Qt went the other way from the
  maintainer's reconsideration: no platform view, its own decode feeding its own
  scene graph — the "kaya decodes in the core" route kaya §2 rejected.
- **media3's own Compose samples** — `ContentFrame` and the docs samples default
  to `SURFACE_TYPE_SURFACE_VIEW` with a black `shutter` composable until the first
  frame (libraries/ui_compose/…/ContentFrame.kt at 1.11.0,
  docsamples/…/ui/ComposeCustomization.kt). The `demos/surface` app shows the
  advanced move: "the MediaCodec always has the same surface attached to it, which
  can be freely 'reparented' to any SurfaceView (or off-screen) without any
  interruptions to playback", via `SurfaceControl` (API 29) — the way to move a
  playing video between a row, fullscreen and a new activity without a hiccup.
- **GNOME Showtime (GTK)** — GstPlay + gtk4paintablesink (in `glsinkbin` when GL
  is available) → `GtkPicture` inside `GtkGraphicsOffload` with
  `black-background: true`; captions via playbin's subtitle font scaled to the
  GTK font DPI; its own MPRIS (copied from gnome-music); idle inhibit while
  playing (GNOME/showtime sources cited in §5-§6).

What they found hard, in one line each: Flutter — hosting a SurfaceView inside
its own renderer (the #164899 hole, thread merging, broken a11y under TLHC);
React Native — DRM forcing SurfaceView regardless of the chosen view; Qt —
maintaining four native backends (it deprecated them for FFmpeg); media3 — the
API 34 SurfaceView/Compose size-sync bug (issue #1237, the SurfaceSyncGroup
workaround inside `PlayerSurface`).

---

# Summary: what this means for kaya

**Android.** "Use the platform's own view" means `PlayerSurface` (or
`PlayerView` for captions), and it is reachable on today's pins (media3 1.10.1,
built and resolved against kaya's toolchain). With `SURFACE_TYPE_SURFACE_VIEW` it
buys power, HDR, frame timing and L1 DRM, and — measured on api 35 — still honours
a rounded clip over an opaque ground, a kaya widget drawn on top, and (per the
javadoc) scrolling from API 24 and alpha from 34; it loses kaya's window pixel
read (measured: the hole), pixel effects, and translucent grounds under its
corners. With `SURFACE_TYPE_TEXTURE_VIEW` it is exactly the §3 external texture
under a supported API. Controls are separable either way; kaya keeps drawing its
own. Captions do not come free in Compose (View-only `SubtitleView`), PiP is a
window feature, and TalkBack sees nothing of the view.

**Linux.** The platform's view and kaya's current design are the same thing (a
paintable in a `GtkPicture`), composited and readable (measured). `GtkVideo`
itself cannot hide its controls, so kaya would not use it.

**System transport is independent of the view on both.** Android: a media3
`MediaSession` over the player gives media keys, headset/AVRCP and volume-key
routing (measured, including the catch that a video with no audio track is never
chosen as the media button session); a `MediaSessionService` adds background
playback, the notification and the Android 13+ quick-settings controls. Linux:
an MPRIS2 export gives GNOME Shell's card, the lock screen, keyboard media keys
and Bluetooth buttons (via BlueZ uinput); no GTK helper, `mpris-server` for Rust.
Keep-awake is the app's job on both (`FLAG_KEEP_SCREEN_ON` / `GtkApplication.inhibit`).

**Unsettled / not measured:** whether `PixelCopy.request(SurfaceView…)` reads a
real device's decoder output (the pool answered opaque black); a `-gpu host` or
device run of any route; the MediaSessionService notification and quick-settings
card on the pool; GNOME Shell's card with a real MPRIS export (the lane image has
no Shell); media3 1.11's Compose additions (need the Kotlin 2.2 / AGP 9 move).

---

## Artifacts and cleanup

Scratch (not the repo): `androidprobe/` (probe copy, media3 1.10.1, PlayerSurface
routes, MediaSession, key logging, `flat_av.mp4`), `android_drive.py`,
`android_caprate.py`, `android_keys.py`, `android-runs/` (logs, screencaps and
crops, keys*.txt), `linuxprobe/` (probe.py, clip, picture.png, video.png).
Cleanup record is appended below once done.

### Cleanup, proven (2026-09-29)

- `adb -s emulator-5562 uninstall dev.kaya.videoprobe` → `Success`;
  `pm list packages | grep -c videoprobe` → `0`; `dumpsys media_session` →
  "Media button session is null"; STREAM_MUSIC back at 5 of 15 (the value found);
  `adb devices` still lists all five pool phones; nothing erased, rebooted,
  cold-booted or killed; only emulator-5562 was addressed.
- No JVM left: every build was `gradle --no-daemon` with in-process Kotlin; a
  process listing for gradle/kotlin daemons after the run matched only the
  listing command itself.
- Docker: `docker ps -a --filter name=kaya-videonative` → empty (both runs were
  `--rm`; Xvfb ran inside the container).
- Disk: probe build outputs and clones deleted; `androidprobe/` 56K,
  `android-runs/` 3.3M, `linuxprobe/` 20K. The repo is untouched
  (`git status` clean for tools/android/videoprobe and docs).
