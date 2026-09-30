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
| the clip monitor and the program monitor | a media player shown by a video view (docs/media-plan.md) |
| the filmstrip and waveform under each clip | offline extraction at import, drawn with the canvas (§5) |
| importing a clip | the file dialogs and picked-file reads that exist |
| the bin and the track list | collections, records and tables that exist |

The app's language: Rust (RULING 1 in §7, RULED 2026-09-29).

## §2 and §3 Video: replaced by docs/media-plan.md (2026-09-29)

These two sections designed the `video` kind as a headless platform
player handing its frames to the image widget's high-rate path, on the
belief that a native player view is a hole kaya cannot draw on. The
research of 2026-09-29 (docs/probes/video-native-2026-09-29/) measured
otherwise: the platform's own view composites with kaya's widgets on
four of five platforms (a bare `AVPlayerLayer` on Apple, a `GtkPicture`
on GTK, `MediaPlayerElement` on WinUI with stated limits; only Android's
SurfaceView is a hole), and it brings captions in the user's style, DRM,
Picture in Picture and HDR for free, all of which the frames route would
have lost. Flutter added an `AVPlayerLayer` platform view to its texture
player in 2025 for the same reasons. The maintainer ruled the new shape
the same day: a media player object, the platform's video view as the
default, a surface widget for composited frames, and a media session.
docs/media-plan.md is the design; the Android and Linux probes of §6
remain its evidence.

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
RULED 2026-09-29 as the `draw_image` op, docs/media-plan.md §8 ruling 3.

Extraction itself is per-platform code in the APP's language, not in
kaya's core — it is an editor feature, not a GUI feature — unless the
maintainer wants `kaya.thumbnail(path, at_ms)` on the asset floor.
Now docs/media-plan.md §8 ruling 4, ruled 2026-09-29 as research first.

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

Then the ladder this tree always walks: docs/media-plan.md §7's order for
the player, the video view and the session; then the sliders' contract the same
way; then the fan-out to the four other backends and eight other
bindings; then drag and drop on the timeline (docs/dnd-plan.md's own
sequence); then the app itself, one screen at a time, with its scene
scripts shared verbatim. The matrix before anything is called landed.

## §7 Rulings for the maintainer

1. The app's language: Rust, Go or Python. RULED 2026-09-29 (the
   maintainer): Rust.
2. The `video` kind's surface. RESOLVED 2026-09-29 by docs/media-plan.md
   §0 rulings 2 and 3: a media player object shown by a video view,
   replacing the headless kind.
3. Keep-awake and Now Playing metadata. RESOLVED 2026-09-29 by
   docs/media-plan.md: keep-awake belongs to the player (§2 rule 5), Now
   Playing to the media session (§5).
4. The codec floor. MOVED to docs/media-plan.md §8 ruling 1, RULED
   2026-09-29.
5. What a video scene may assert. MOVED to docs/media-plan.md §8 ruling
   2, RULED 2026-09-29.
6. The range slider: a separate `range` kind (recommended) or a mode of
   `slider`. RULED 2026-09-28 (the maintainer): a separate `range` kind,
   horizontal, two thumbs for trim in and out. The vertical fader is a
   different need, spelled as the `axis` a row, column and scroll take,
   now legal on a slider (recommended, no ruling asked).
7. Filmstrips. MOVED to docs/media-plan.md §8 ruling 3, RULED 2026-09-29.
8. Thumbnail and waveform extraction. MOVED to docs/media-plan.md §8
   ruling 4, ruled 2026-09-29 as research first.
9. The test asset. MOVED to docs/media-plan.md §8 ruling 5, RULED
   2026-09-29.

## §8 What this milestone does not promise, on the record

- A COMPOSED preview beyond cuts: transitions, overlays, an audio mix.
  Every shipped editor takes these from a media engine that is not its UI
  toolkit (Shotcut and Kdenlive from MLT, Pitivi from GES, Olive from
  FFmpeg, Descript and Clipchamp from their own WebCodecs compositors), and
  the four platform composition APIs disagree on frame exactness and seek
  behaviour too much to hide behind one semantics. The program monitor
  cuts between two players at the playhead; that is the editor's
  honest v1.
- Export. A media-engine job, and the same non-promise.
- kaya decoding video, or FFmpeg in the core. Recorded as declined with
  the research's reasons, not deferred.
- JavaScript anywhere in this app, or on the phones (docs/js-plan.md §5).
- (Withdrawn 2026-09-29: the Android video view is a `SurfaceView`,
  with its limits stated in docs/media-plan.md §3; an app that needs the
  video inside kaya's composition uses the surface.)
