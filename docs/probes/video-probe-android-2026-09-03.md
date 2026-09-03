# Android probe: does kaya's window PixelCopy read a video back?

Settles docs/probes/video-playback-2026-09-02.md §1.0d, for
docs/video-editor-plan.md §3 and §6.1. Written progressively while the
probe ran; every number below is a logcat line from the run, quoted.

## Setup

- Host: darwin arm64, repo /Users/akhilindurti/Projects/kaya, all
  commands `nix develop -c ...`.
- Device: ONE phone of the already-booted pool, `emulator-5560`
  (avd `kaya`, `-read-only -snapshot default_boot`, api 35
  google_apis arm64, swiftshader_indirect GPU). The pool was booted
  before this probe and is left booted; nothing was erased, recreated
  or rebooted.
- Probe app: `tools/android/videoprobe`, a STANDALONE gradle project
  copying tools/android/pickerprobe's shape (its own settings.gradle.kts;
  android/settings.gradle.kts untouched).
  - AGP 8.7.3, Kotlin 2.0.21 + compose plugin 2.0.21, compileSdk 35,
    buildToolsVersion 37.0.0, minSdk 26, targetSdk 35 — android/kaya's
    own numbers.
  - compose BOM 2024.10.01, `androidx.activity:activity-compose:1.9.3` —
    again android/kaya's own.
  - **media3 pinned exact: `androidx.media3:media3-exoplayer:1.6.1`**.
- Clips, generated with the dev shell's ffmpeg 9.0 (`libx264`,
  `libvpx-vp9`), 2s of flat #2B3B4F at 320x240x30:
  - `flat_h264.mp4`, 2852 bytes, H.264 baseline L3.0 yuv420p
  - `flat_vp9.webm`, 2018 bytes, VP9 yuv420p
  - Host decode of BOTH, centre pixel: `2C3B4F` — the yuv420p round trip
    moves R by one from the requested 2B, which is inside kaya's own ±1
    per-channel ink tolerance. **`2C3B4F` is therefore what a successful
    read looks like.**

### The read is kaya's own, transcribed

`ProbeActivity.sample()` is `KayaCompose.kt:4024 kayaCanvasInk` copied:
the Compose `onGloballyPositioned { it.boundsInWindow() }` box, offset by
`decorView.getLocationInWindow`, intersected with the decor extent, an
`ARGB_8888` bitmap of exactly that rect, and
`PixelCopy.request(activity.window, src, bitmap, cb, mainHandler)` — the
**window overload**, which is the half of §1.0d in dispute. The only
change is that the result is read in the callback rather than behind a
`CountDownLatch`, because the probe samples from the main thread and
kaya's harness samples from its own.

### The three routes, and why the ground is magenta

The video box sits on an opaque magenta (`FF00FF`) Compose background,
so one hex tells three outcomes apart: `2C3B4F` is the clip, `FF00FF` is
the window content *behind* a punched hole, `000000` is a cleared hole.

- `route=embedded` — `androidx.compose.foundation.AndroidEmbeddedExternalSurface`,
  the Compose-idiomatic external texture (a `TextureView` underneath).
- `route=texture` — the same thing spelled by hand: `AndroidView` hosting
  a `TextureView`, `Surface(surfaceTexture)` handed to the player, so the
  reading cannot be an artifact of the Compose wrapper.
- `route=surfaceview` — THE CONTROL: `AndroidView` hosting a
  `SurfaceView`, `holder.surface` handed to the player.

## Measurement 1 — the SurfaceView control: the window copy reads THE HOLE

**Every SurfaceView sample, in every run, read `000000` at alpha 0.** 159
samples over 9 runs (7 H.264 runs at both cadences, 1 nudged, 1 VP9); not
one read the clip, and not one read the magenta ground either.

```
09-03 01:46:19.776 21682 21682 I kayavideoprobe: INK route=surfaceview clip=flat_h264.mp4 at=1200ms rect=Rect(16, 16 - 304, 232) ink=000000/000000/000000 alpha=0 tvink=<off> state=3 pos=1085 playing=true loops=0
09-03 01:46:20.566 21682 21682 I kayavideoprobe: INK route=surfaceview clip=flat_h264.mp4 at=2000ms rect=Rect(16, 16 - 304, 232) ink=000000/000000/000000 alpha=0 tvink=<off> state=3 pos=1869 playing=true loops=0
09-03 01:46:22.067 21682 21682 I kayavideoprobe: INK route=surfaceview clip=flat_h264.mp4 at=3500ms rect=Rect(16, 16 - 304, 232) ink=000000/000000/000000 alpha=0 tvink=<off> state=3 pos=1379 playing=true loops=1
```

**alpha 0 is the finding, not the black.** The video box sits on an opaque
magenta Compose background; the copy came back fully transparent, which
means the app's own window surface has nothing there at all — the
SurfaceView cleared the magenta out of it and the video went to a layer
the window copy never sees. The player was live throughout
(`state=3 playing=true`, `pos` advancing, `loops` climbing).

**And the video WAS on screen while the copy read the hole.** A
SurfaceFlinger `screencap` taken from the host at the same two instants as
the 3500ms and 5000ms samples of the run at 01:49:36:

```
  screencap-surfaceview.png  box centre = 3D4A5F   outside the box = FF00FF
  screencap2-surfaceview.png box centre = 3D4A5F   outside the box = FF00FF
09-03 01:49:36.457 22483 ... INK route=surfaceview ... at=3500ms ... ink=000000/000000/000000 alpha=0 ... pos=1370 playing=true loops=1
09-03 01:49:37.958 22483 ... INK route=surfaceview ... at=5000ms ... ink=000000/000000/000000 alpha=0 ... pos=872 playing=true loops=2
```

The device composite shows the clip (`3D4A5F` — SurfaceFlinger's own
YUV→RGB for a video layer, brighter than the GPU path's `2D3B50`); kaya's
window copy, at the same moment, shows the hole. **That is §1.0d settled
for the control: `PixelCopy.request(activity.window, …)` cannot read a
SurfaceView-hosted player.** The reading in the research that said it
*can* is about the OTHER overload, `PixelCopy.request(SurfaceView, …)`.

## Measurement 2 — the external texture: the copy CAN read the clip, and on this emulator almost never gets the chance

Both texture spellings put an `android.view.TextureView` in the tree, read
off the device rather than assumed:

```
TREE route=embedded  androidx.compose.ui.viewinterop.ViewFactoryHolder 288x216
TREE route=embedded   android.view.TextureView 288x216 [TextureView opaque=true available=true layer=2]
TREE route=texture   android.view.TextureView 288x216 [TextureView opaque=true available=true layer=2]
TREE route=surfaceview android.view.SurfaceView 288x216 [SurfaceView holderSurfaceValid=true]
```

**Alpha is 255 on every texture-route sample** — the texture layer is
inside the window's own surface, which is the structural half of the
answer and the opposite of the SurfaceView's alpha 0. When the texture has
a frame up, the copy returns the clip's exact bytes:

```
09-03 01:51:53.606 22883 22883 I kayavideoprobe: INK route=texture clip=flat_h264.mp4 at=2000ms rect=Rect(16, 16 - 304, 232) ink=2D3B50/2D3B50/2D3B50 alpha=255 tvink=<off> state=3 pos=1940 playing=true loops=0
09-03 01:51:59.606 22883 22883 I kayavideoprobe: INK route=texture clip=flat_h264.mp4 at=8000ms rect=Rect(16, 16 - 304, 232) ink=2D3B50/2D3B50/2D3B50 alpha=255 tvink=<off> state=3 pos=1938 playing=true loops=3
09-03 01:52:07.605 22883 22883 I kayavideoprobe: INK route=texture clip=flat_h264.mp4 at=16000ms rect=Rect(16, 16 - 304, 232) ink=2D3B50/2D3B50/2D3B50 alpha=255 tvink=<off> state=3 pos=1936 playing=true loops=7
```

`2D3B50` against the host's own decode of the same file, `2C3B4F`: R +1,
G 0, B +1 — **inside kaya's ±1 per-channel ink tolerance**, so a frozen
`expect_ink` string would match. The bytes are right when they come.

**The rate at which they come is the problem.** Across every run whose
logcat was dumped to a file:

| route | samples | read the clip | alpha |
|---|---|---|---|
| `embedded` (AndroidEmbeddedExternalSurface) | 159 | 1 | 255 on all |
| `texture` (AndroidView + TextureView) | 152 | 4 | 255 on all |
| `embedded`, VP9 twin | 7 | 0 | 255 on all |
| `surfaceview` (control) | 159 | **0** | **0 on all** |

**5 of 318 texture-route samples.** The exception, and it is a real one:
the very FIRST run of the session read the clip on all 7 of its samples
(`logcat-h264-embedded-run1-transcript.txt`, 01:36:44) — after which no
later run of either texture spelling managed better than 3 of 7. A fresh
uninstall/install did not bring it back (`logcat-h264-embedded-freshinstall.txt`,
0 of 7).

### The black is on the SCREEN, not in the copy

This is the part that keeps the finding honest: the copy is faithful, and
what it is faithful to is a black TextureView. At 01:49:16, `screencap`
and the copy disagree by 100ms and agree in kind — colour at 3.4s, black
at 4.9s, with the copy black at 3.5s:

```
  screencap-embedded.png   box centre = 2D3B50  outside = FF00FF   (t ≈ 3.4s)
  screencap2-embedded.png  box centre = 000000  outside = FF00FF   (t ≈ 4.9s)
09-03 01:49:16.450 ... INK route=embedded ... at=3500ms ... ink=000000/000000/000000 alpha=255 ... pos=1347 playing=true loops=1
```

and a 14-shot screencap series over one whole texture run read `000000`
in the box, `FF00FF` outside it, 14 times out of 14 while the player
looped 8 times. The emulator's own renderer says why:

```
W HWUI    : Unknown dataspace 0
I Gralloc4: mapper 4.x is not supported
D EGL_emulation: app_time_stats: avg=889.18ms min=15.29ms max=28751.97ms count=33
```

33 app frames in 19 seconds — this app draws about 1.7 times a second
under `-gpu swiftshader_indirect`, against a clip decoding at 30. An
`invalidate()` on the TextureView and the decor plus a Choreographer frame
and 64ms of slack before the copy (`--es nudge 1`) moved one run to 3 of 7
and left the next at 0 of 7, so a redraw nudge is not the fix.

**By the end of the session the emulator was not presenting the clip on
ANY route:** a screencap series on the SurfaceView run at 01:56 read
`box=000000 outside=FF00FF` six times out of six, on the route that had
composited `3D4A5F` seven minutes earlier, with the player looping and
`mWakefulness=Awake`. So the instability is the emulator's video
presentation as a whole, not the texture route alone and not PixelCopy.

## Decoder notes

- **H.264 decoded, every time.** `c2.goldfish.h264.decoder` (the
  emulator's own software AVC decoder, `libcodec2_goldfish_avcdec.so`),
  init 38–107ms. The VP9 twin was needed only for the record: it decoded
  too, `c2.goldfish.vp9.decoder`, init 21–37ms.
- **No decoder death over loops.** Every one of the 27 dumped runs played
  the 2s clip to `loops=8` in 16s (`REPEAT_MODE_ALL`, ~9 plays) with
  **zero `PLAYERERROR` lines**. The androidx/media#2461 shape — the
  emulator's HEVC decoder dying after a few loops — has no H.264 or VP9
  analogue here.
- One benign complaint each run:
  `Codec2Client: setOutputSurface -- failed to set consumer usage (6/BAD_INDEX)`,
  followed by `Surface configure completed`.

## Launch to first decoded frame

`Player.Listener.onRenderedFirstFrame` measured from `onCreate`:
**247–450ms**, median ≈ 285ms, over 27 runs; the outlier 450ms was the
first run after an install. `am start -W` on a COLD start of that same
fresh install: `TotalTime: 541`, with the first frame at 332ms after
`onCreate` inside it. So **launch to first decoded frame is roughly half a
second on this emulator**, decoder init included.

## What this means for docs/video-editor-plan.md §3

§3's construction rule survives and gets sharper: the Android video must
be a `SurfaceTexture`-backed external texture composited by Compose,
because kaya's `PixelCopy.request(activity.window, …)` reads a
SurfaceView-hosted player as a fully transparent hole (alpha 0, 159 of 159
samples) while it reads the composited texture as the clip's own bytes
(`2D3B50` against a host decode of `2C3B4F`, inside the ±1 ink tolerance)
whenever a frame is up — so the §1.0d disagreement resolves against the
"PixelCopy can read a SurfaceView" reading, which was about the SurfaceView
overload and not kaya's. But §3's promise of "ONE flat-colour ink read per
lane" cannot be cashed on the emulator pool as it stands: the texture
presented a frame in 5 of 318 samples, the same pool later stopped
presenting the clip on every route, and the cause is the guest's software
renderer (`HWUI: Unknown dataspace 0`, 1.7 app frames a second under
`-gpu swiftshader_indirect`) rather than anything kaya could fix in the
read — so the Android video leg should assert geometry, state and timing,
and hold the pixel assertion open behind a second probe on a host-GPU
emulator (`-gpu host`) or a physical device before it is promised.

## Cleanup, proven

- `adb -s emulator-5560 uninstall dev.kaya.videoprobe` → `Success`, and
  `pm list packages | grep -i videoprobe` → nothing. Logcat cleared.
- **The pool is as it was found**: five instances still up
  (`emulator-5554/5556/5558/5560/5562`), none erased, recreated, rebooted
  or `emu kill`ed; only `emulator-5560` was ever addressed.
- **No JVM left behind.** Every gradle invocation was `gradle --no-daemon`
  with `kotlin.compiler.execution.strategy=in-process` in the probe's own
  `gradle.properties`, so neither a build daemon nor a Kotlin compile
  daemon survives a build. After the run, the only Gradle daemon on the
  machine is pid 39239 — recorded in `baseline-java.txt` *before* this
  probe ran its first gradle command, and its elapsed time has grown by
  exactly the length of this session, so it is not one of mine.
- **Disk**: `tools/android/videoprobe/app/build (gone)` reached 72 MB; it and
  `build/`, `.gradle/` and `.kotlin/` are deleted.
  `du -sh tools/android/videoprobe` → **44K**, being the 3 gradle files,
  the manifest, `ProbeActivity.kt` and the two clips (2852 + 2018 bytes).
  `tools/android/pickerprobe` (16M, pre-existing) untouched.
- **Tree**: the only change is the untracked `tools/android/videoprobe/`.
  `tools/check-python.py`, `tools/check-doc-refs.py` and
  `tools/check-assets.py` all green afterwards.

## Files

- Probe app: `/Users/akhilindurti/Projects/kaya/tools/android/videoprobe`
- Raw logcat dumps, 27 runs: `logcat-h264-*.txt`, `logcat-vp9-*.txt`,
  the full unfiltered buffer of one texture run
  `logcat-full-embedded.txt`, and the first run's lines
  `logcat-h264-embedded-run1-transcript.txt`.
- Device composites: `screencap-embedded.png`, `screencap2-embedded.png`,
  `screencap-surfaceview.png`, `screencap2-surfaceview.png`.
