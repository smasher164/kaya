# What a video editor actually needs; thumbnails and waveforms

Research slice for kaya's "forcing app" question: how much of the video stack must the
library own if the demo app is a video editor with playback?

Status: IN PROGRESS (appended as findings land).

## A1. Media bin preview vs composed timeline preview

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

### MLT (the engine behind Shotcut and Kdenlive)

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

## A2. Can the PLATFORM play a composed timeline? (the crux)

Short answer: **all four platforms now ship a composition-playing API, but they are not equal.
Apple's is mature and general; Windows' is a frozen WinRT API that still works; Android's landed
as experimental in December 2025; Linux/GTK has GES, which is a real engine but is a separate
library, not "the platform".**

### Apple (macOS + iOS) — YES, mature, and this is the strong case

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

### Android — YES as of Media3 1.9.0 (Dec 2025), but EXPERIMENTAL

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

### Windows — YES, `Windows.Media.Editing.MediaComposition`, WinRT, works from WinUI 3

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

### Linux / GTK — GES (GStreamer Editing Services), a real engine but a separate library

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

### Verdict for kaya

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
## A3. What the cross-platform frameworks actually do today

### Flutter — no composed preview. Player + rendered proxies + ffmpeg export.

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

### React Native — same shape, one level lower

`react-native-video` is a wrapper: ExoPlayer on Android, AVPlayer on iOS/tvOS/visionOS.
https://docs.thewidlarzgroup.com/react-native-video/docs/v6/intro/
It plays sources. Multiple simultaneous players are possible but the ExoPlayer issue tracker is
full of the reasons not to lean on it for a timeline: creating player instances is expensive, and
"each device has limited media codecs responsible for video decoding" — you run out of hardware
decoders. https://github.com/google/ExoPlayer/issues/273 ·
https://github.com/google/ExoPlayer/issues/11265
Nothing in the RN ecosystem composes a timeline; RN editor apps call out to native modules or
ffmpeg.

### Electron / Tauri (the web route) — and this is where the interesting precedent is

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

### Qt — the closest analogue to what kaya would be building, and its trajectory is the warning

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
## A4. The minimal "render the timeline at its playhead" pipeline

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

### Where the difficulty actually is

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

## A5. The cheaper design: player-per-clip, composition only at export

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
# B. Thumbnails and waveforms

## B6. Frame extraction for the filmstrip

Every platform ships a "give me a still at time T" API. None of them requires the app to own a
decoder, and all of them are one call.

### Apple — `AVAssetImageGenerator`

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

### Android — three tiers

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

### Linux / GStreamer

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

### Windows — two routes

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

### Cost summary

| Platform | Filmstrip API | Tolerance knob | Notes |
| --- | --- | --- | --- |
| Apple | AVAssetImageGenerator.images(for:) | requestedTimeTolerance{Before,After} | set maximumSize; appliesPreferredTrackTransform |
| Android | media3 FrameExtractor (or getScaledFrameAtTime) | OPTION_PREVIOUS_SYNC vs CLOSEST | single-thread affinity; scale during extraction |
| Linux | appsink + seek + pull-preroll | seek flags (KEY_UNIT vs ACCURATE) | you assemble the pipeline |
| Windows | MediaComposition.GetThumbnailsAsync, or IMFSourceReader | VideoFramePrecision | batch call has an open correctness bug |

## B7. Audio waveform extraction

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

## B8. Is an offline extraction step at import enough for the TIMELINE?

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
# C. What real cross-platform editors are actually built with

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

### The pattern in that table

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

# Synthesis: the four routes, priced

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

# Addenda / verified quotes

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
