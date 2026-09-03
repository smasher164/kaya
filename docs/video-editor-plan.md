# The video editor — the forcing app for drag and drop, sliders and video (design pass, 2026-09-03)

The maintainer's ask (2026-09-02): "an app that tests drag and drop,
sliders. a video editor maybe?", then "we should also treat video playback
(and owning the rendering) as requirements for this milestone", where
owning the rendering means docs/canvas-plan.md ruling 16 — the IMAGE
widget's high-rate update path for pixels kaya did not draw, the canvas
plan's one deferred arm. Sliders: "whatever we don't already have". JS:
out of this app and off the phones by ruling (docs/js-plan.md §5); the
app is written in a language that runs natively on all five lanes.

The research behind every claim here: docs/probes/video-playback-2026-09-02.md
(with five companions), docs/probes/dnd-2026-09-02-*.md, and the
drag-and-drop design in docs/dnd-plan.md. Numbers below are theirs.

## §1 What the app is, and what it forces

A TIMELINE EDITOR: a media bin of imported clips, a timeline with tracks,
a clip monitor, a program monitor that cuts between clips at the playhead,
trim handles, a playhead, zoom and volume. Export is out of scope (an
export is a media-engine job, §8).

What each part of it forces out of kaya:

| part of the app | kaya surface it forces |
|---|---|
| dragging a clip along a track, between tracks, from the bin, from Finder/Files | docs/dnd-plan.md's arms on five backends, with drop position, auto-scroll during a drag, and touch on the phones |
| trim handles, playhead, zoom, volume | the slider contract that does not exist yet (§4) |
| the clip monitor and the program monitor | the `video` kind (§2) over the image widget's high-rate path (§3) |
| the filmstrip and waveform under each clip | offline extraction at import, drawn with the canvas (§5) |
| importing a clip | the file dialogs and picked-file reads that exist |
| the bin and the track list | collections, records and tables that exist |

The app's language: one that runs on all five lanes today — Rust, Go or
Python (the portfolio is Python; kaya's text editor is Go). RULING 1 in §7.

## §2 The `video` kind: the platform decodes, kaya presents

RULED SHAPE (from the maintainer's "owning the rendering" clarification):
kaya does NOT host a platform player VIEW, and kaya does NOT decode video
in the core. Each platform's player runs HEADLESS — it owns decode, audio,
the clock and A/V sync — and hands its frames to kaya as a platform
surface, which kaya presents through the image widget's high-rate path.
Video is then an ordinary kaya widget: it clips, scrolls, rounds, and can
be drawn over, and every observable kaya has about a widget's geometry
holds for it.

Why not the other two routes the research priced:

- A hosted player VIEW (MAUI's MediaElement shape) is a hole in kaya's
  surface on Android and a rectangle kaya may not draw on anywhere; the
  research's D8 called it a carve-out from "kaya rasterizes, backends
  blit". The maintainer did not mean it.
- kaya decoding in the core (four platform decoders behind a trait, or
  FFmpeg) drags in the audio milestone through the A/V clock, has a real
  licensing problem for FFmpeg on iOS, and is the design Qt built over four
  native backends and retreated from. It is not this milestone.

The headless player per backend, and the surface it hands over:

| backend | headless player | frames arrive as |
|---|---|---|
| macOS, iOS (SwiftUI) | `AVPlayer` + `AVPlayerItemVideoOutput` (additive: the player keeps its clock while frames are pulled) | `CVPixelBuffer` / `IOSurface` |
| Android (Compose) | media3 `ExoPlayer` rendering to a `Surface` kaya owns (`SurfaceTexture` / `AHardwareBuffer`) | the external texture |
| Linux (GTK4) | `gstreamer-rs` driving `playbin3` (rate, accurate seek, EOS/error on the bus; a rate-2.0 FLUSH\|ACCURATE seek measured accepted) | `gtk4paintablesink`'s `gdk::Paintable` (Debian trixie packages it as `gstreamer1.0-gtk4`; its rank is none, so `video-sink` is set explicitly) |
| Windows (WinUI 3) | `MediaPlayer` in frame-server mode (`IsVideoFrameServerEnabled`: exclusive by design — the player renders nothing itself, which is what we want) | `IDirect3DSurface` |

The wire contract (one semantics, four spellings; RULING 2 fixes it):

- props: `source` (an asset name or a picked-file handle — a PATH, never
  a stream: AVFoundation has no in-memory or descriptor initializer),
  `autoplay`, `loop`, `muted`, `volume` (0..1), `speed`, `fit`
  (`contain`|`cover`|`fill`, the image widget's own vocabulary).
- commands: `play`, `pause`, `seek(ms)`, `stop`.
- mirrors (signals the app reads): `position` (ms), `duration` (ms),
  `state` (`idle`|`loading`|`playing`|`paused`|`ended`|`failed`),
  `media_width`, `media_height`.
- occurrences: `ended`, `failed(reason)`, `seek_completed`, and
  `position` ticking at a rate the platform chooses (the app's playhead
  slider is bound to it; §4).
- NO platform transport chrome, ever: the editor draws its own scrubber.
- NO "give me the frame playing now" call in v1: Apple's output is
  additive and Windows' frame server is exclusive, so the uniform answer is
  offline extraction against a FILE (§5).
- Chrome ownership drags system integration with it: keep-awake during
  playback and Now Playing metadata become explicit props or are silently
  lost (the research's D2). RULING 3.

The codec floor: the intersection of what every target decodes with no
extra install is H.264 in MP4 with AAC. Apple plays no VP9 or WebM;
Windows lacks HEVC (what an iPhone records by default) without a paid
Store extension kaya cannot buy for the user; Android and GStreamer differ
again. The kind states the floor AND ships a capability query, the way
`aux_windows` does. RULING 4.

## §3 The image widget's high-rate path (canvas ruling 16, built)

docs/canvas-plan.md §16: "the zero-copy arm was never a second canvas. It
is the IMAGE widget learning a high-rate update path for content KAYA DID
NOT DRAW … platform surface handles — IOSurface, DXGI shared handles,
dmabuf — is the zero-copy arm and is still deferred." This milestone
builds it, with video as its first producer and a camera as the obvious
second.

The mechanism, in plain words: today an image widget's pixels arrive on
the wire as bytes (the blob channel) and the backend uploads them. On the
high-rate path the pixels never cross the wire at all: a producer on the
platform (the headless player) writes frames into a surface the platform
compositor can present directly, and the image widget is told "present
this surface" once; every later frame is the producer's business, on the
producer's clock, with no kaya code running per frame. That is Flutter's
`Texture` widget, named by the ruling as the precedent.

What it needs per backend: a way to hand an image widget a surface
handle instead of bytes, and the widget's own layout, clipping and hit
testing unchanged around it. What it gives up, stated once: kaya cannot
read those pixels back the way it reads the canvas (`expect_ink` samples
a raster kaya produced), so a video scene asserts geometry, state and
timing, plus ONE flat-colour ink read per lane against a synthetic clip
to prove frames reached the screen — and on Android that read is the
probe in §6 before it is a promise. RULING 5.

The harness rule this keeps: the image widget's high-rate path is a
producer-owned surface INSIDE kaya's layout, not a hole beside it, so no
backend may take the video out of kaya's clip. On Android that means a
`SurfaceTexture`-backed external texture (composited by Compose), NOT a
`SurfaceView` (a hole punched by SurfaceFlinger); the research's §1.0d
disagreement about reading a SurfaceView's pixels becomes moot by
construction. The probe in §6 confirmed both halves on 2026-09-03: the
window `PixelCopy` reads the clip's own bytes off a Compose-composited
external texture (2D3B50 against a host decode of 2C3B4F, inside the ink
tolerance) and reads a transparent hole (000000, alpha 0, 159 of 159
samples) off a SurfaceView while a SurfaceFlinger screencap shows the clip
— but under the emulator pool's software GPU a frame was actually up in 5
of 318 samples (~1.7 presented frames per second, `HWUI: Unknown
dataspace 0`), so a per-run ink assertion on that lane would be a flake by
construction. RULING 5 is amended accordingly.

## §4 Sliders: the contract that does not exist yet

Today: `slider` carries `value` (F64), `min`, `max`, and one change
occurrence carrying the new value (crates/kaya/src/spec.rs). The editor
needs, and the milestone builds:

- `step`: snap increments, and the keyboard/accessibility increment; a
  frame-stepped playhead is a step of one frame's duration.
- a two-thumb RANGE slider (`low`/`high`) for trim in and out — a new
  kind or a mode of the slider; RULING 6 (a separate `range` kind keeps
  the slider's one-value occurrence intact and is the uniform spelling
  across the four backends, whose native range controls differ most).
- drag-versus-release semantics: a live value while dragging and a
  committed value on release, as two occurrences (`change` live,
  `commit` on release), so a playhead scrubs live and a trim commits once.
- `vertical` orientation (a volume fader).
- touch fidelity on the phones: the thumb's hit slop, the driver's swipe
  verbs already exist for the assertion.

Each of these is a wire change through the spec, all nine bindings'
sugar (check-sugar-surface's census grows the rows), four backends and
the three harness interpreters, on the milestone's usual fan-out.

## §5 Thumbnails and waveforms: offline at import, drawn with the canvas

At import the app extracts a filmstrip (one still per N seconds:
`AVAssetImageGenerator`, media3's `FrameExtractor`, a GStreamer `appsink`
seek + `pull-preroll`, `MediaComposition.GetThumbnailsAsync`) and a peaks
file for the waveform (decode once, min and max per bucket, the
`audiowaveform` .dat shape), and caches both in the app's own directory.
The timeline then draws entirely with existing canvas ops over cached
data — nothing decodes while the user drags.

The one gap on kaya's side: the canvas has no image op, so a filmstrip is
either a row of `image` widgets (works today) or a new `draw_image` op
(a spec change through eight bindings and three interpreter copies).
RULING 7.

Extraction itself is per-platform code in the APP's language, not in
kaya's core — it is an editor feature, not a GUI feature — unless the
maintainer wants `kaya.thumbnail(path, at_ms)` on the asset floor.
RULING 8.

## §6 Sequencing: the probes, then depth, then breadth

Two ten-minute probes before any arm is written (the research's D9,
amended for the §3 shape):

1. Android — RUN 2026-09-03 (docs/probes/video-probe-android-2026-09-03.md;
   the probe app is tools/android/videoprobe). An `ExoPlayer` rendering
   a flat-colour clip into a Compose-composited external texture, read
   back through kaya's own window `PixelCopy`: the clip's bytes when a
   frame is up; the SurfaceView control reads the punched hole every
   time. H.264 decoded on every run (`c2.goldfish.h264.decoder`; the VP9
   twin too; no analogue of the HEVC decoder's death), launch to first
   decoded frame 247–450 ms. What the emulator cannot do is PRESENT: under
   `-gpu swiftshader_indirect` about 1.7 frames a second reached the
   window, and by the session's end the pool presented the clip on no
   route at all. So the Android lane asserts geometry, state and timing;
   the flat-colour ink read is a `-gpu host` or physical-device measurement
   before it is a promise (docs/traps.md, "A SurfaceView video reads as a
   transparent hole").
2. Linux — RUN 2026-09-03 (docs/probes/video-probe-linux-2026-09-03.md).
   The lane's container (tools/linux/Dockerfile) installs `libgtk-4-dev`
   and `ffmpeg` and no GStreamer. The set that plays both an H.264/MP4
   and a VP9/WebM clip to EOS under the lane's own Xvfb, through
   `playbin3` -> `gtk4paintablesink` and through `GtkMediaFile`, is
   `gstreamer1.0-plugins-base`, `-good`, `gstreamer1.0-libav`,
   `gstreamer1.0-gtk4` and the two `-dev` packages: 60.3 MB on the 1.9 GB
   image; `-bad`, `-gl` and `-x` are unnecessary and cost 149 MB more.
   The missing-module sentence is "GTK could not find a media module.
   Check your installation." (g-io-error-quark 15), set AT CONSTRUCTION
   before `play()` and byte-identical for no packages and for
   `GTK_MEDIA=none`, so it is a watched branch. Three traps the arm must
   hold (docs/traps.md, "A GStreamer pipeline missing its codec reaches EOS
   with status 0"): a missing CODEC is a bus warning plus a missing-plugin
   message and then a clean EOS; `is_prepared()` is TRUE while the
   missing-module error is set; `GTK_MEDIA=bogus` warns and silently
   plays. And the frame-arrival observable that needs no pixel read: the
   sink's paintable goes 0x0 -> 320x240 on the first frame.

Then the ladder this tree always walks: the image widget's high-rate
path and the `video` kind on macOS (SwiftUI) with the Rust binding and
one scene, green on the mac lane; then the sliders' contract the same
way; then the fan-out to the four other backends and eight other
bindings; then drag and drop on the timeline (docs/dnd-plan.md's own
sequence); then the app itself, one screen at a time, with its scene
scripts shared verbatim. The matrix before anything is called landed.

## §7 Rulings for the maintainer

1. The app's language: Rust, Go or Python. (Python keeps the portfolio's
   shape; Go keeps the editor's; Rust is the depth binding.)
2. The `video` kind's surface as §2 spells it — props, commands,
   mirrors, occurrences — or changes to it.
3. Keep-awake and Now Playing metadata: explicit props (`keep_awake`,
   `title`/`artist`) in v1, or dropped from v1 and recorded as a gap.
4. The codec floor: state H.264/MP4/AAC as the floor AND ship a
   capability query, or the floor alone.
5. What a video scene may assert: geometry, state and timing on every
   lane, plus one flat-colour ink read on the lanes whose host presents
   frames reliably (mac, iOS, linux, windows) and a frame-arrival
   observable instead on Android (recommended, after probe 1), or
   geometry and state only everywhere.
6. The range slider: a separate `range` kind (recommended) or a mode of
   `slider`.
7. Filmstrips: a row of `image` widgets (works today) or a new canvas
   `draw_image` op.
8. Thumbnail and waveform extraction: in the app's language per
   platform (recommended for this milestone), or a `kaya.thumbnail` on
   the asset floor.
9. The test asset: one H.264/MP4 clip shared by all five lanes (the
   floor) — requires verifying the Android emulator's H.264 path first —
   or two assets with each lane picking.

## §8 What this milestone does not promise, on the record

- A COMPOSED preview beyond cuts: transitions, overlays, an audio mix.
  Every shipped editor takes these from a media engine that is not its UI
  toolkit (Shotcut and Kdenlive from MLT, Pitivi from GES, Olive from
  FFmpeg, Descript and Clipchamp from their own WebCodecs compositors), and
  the four platform composition APIs disagree on frame exactness and seek
  behaviour too much to hide behind one semantics. The program monitor
  cuts between two headless players at the playhead; that is the editor's
  honest v1.
- Export. A media-engine job, and the same non-promise.
- kaya decoding video, or FFmpeg in the core. Recorded as declined with
  the research's reasons, not deferred.
- JavaScript anywhere in this app, or on the phones (docs/js-plan.md §5).
- A `SurfaceView` on Android, or any route that takes the video out of
  kaya's clip.
