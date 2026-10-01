# Thumbnail and waveform extraction: the research pass (2026-10-01)

Status: COMPLETE 2026-10-01; awaits the maintainer's ruling. The question for the
maintainer's ruling (docs/media-plan.md §8 ruling 4, "research first";
docs/video-editor-plan.md §5): how does a kaya app get (a) still frames from
a video at given times, for a filmstrip, and (b) audio peaks, for a
waveform, on all five platforms? Through each platform's own APIs behind
one kaya call, through FFmpeg, or not through kaya at all?

The earlier passes this builds on, not repeated here:
docs/probes/video-playback-2026-09-02-editor.md §B6-§B8 (the API catalogue
per platform, the audiowaveform `.dat` peaks shape, "offline at import, drawn
with the canvas"), docs/probes/video-playback-2026-09-02-android-gtk.md §A5
(media3's `FrameExtractor`), and docs/probes/video-playback-2026-09-02-decoders.md
§B6-§B10 (FFmpeg's licence, store rules, size and hardware decode). What this
pass adds is MEASUREMENT on this tree's hosts and lanes, the frame each API
actually returns, and the prior art.

## The test file and how accuracy is read

One file for every platform, generated in the scratchpad with the dev
shell's FFmpeg 9.0 (deleted afterwards): 10 minutes, 1920x1080 at 30 fps,
H.264 High (x264 `veryfast`, 5 Mb/s, `-g 250`, three B-frames, scene-cut
keyframes left on, so the GOP is irregular and up to 250 frames: 129
keyframes in 18,000 frames), testsrc2 with temporal noise so every frame
costs a real decode, and AAC stereo 48 kHz, a 440 Hz tone whose amplitude
swings over 10 s. 384 MB.

THE FRAME INDEX IS PAINTED INTO THE PICTURE: the top 120 rows are 16 bars,
white for 1, black for 0, carrying the frame number in binary. Any API's
output, at any scale, is read back by cropping that strip and averaging it to
16 pixels, so "which frame did it return" is measured, never inferred from a
reported timestamp. The requests are 30 times, `t = 10 s + 20 s × i`
(frames 300, 900, …, 17700), none on a keyframe; the previous keyframe is
11 to 236 frames earlier (mean ~140, i.e. ~4.7 s of decode to reach the
exact frame).

"Exact" below means the returned frame index equals the requested one;
"sync" means it equals the keyframe at or before it (or after, where the API
says so).

## macOS and iOS: AVFoundation

**Frames: `AVAssetImageGenerator`.** One generator per asset; `images(for:)`
(macOS 13, iOS 16) returns an `AsyncSequence` of results, one per requested
time, each carrying the image, the requested time and the ACTUAL time
(https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/images(for:)).
`image(at:)` is the single async form; `generateCGImagesAsynchronously(forTimes:)`
the older callback batch, cancelled by `cancelAllCGImageGeneration()`.
`requestedTimeToleranceBefore`/`After` default to `.positiveInfinity`
(https://developer.apple.com/documentation/avfoundation/avassetimagegenerator/requestedtimetolerancebefore);
`maximumSize` scales during generation, `appliesPreferredTrackTransform`
honours a phone's rotation. The output is a `CGImage`, so kaya would copy it
into RGBA8 with one `CGContext` draw.

**Audio: `AVAssetReader` + `AVAssetReaderTrackOutput`** with linear PCM
output settings (float32, interleaved, and a channel count: asking for one
channel makes the reader downmix, measured below at +3 dB, the equal-power
sum of two identical channels, so a peaks reader that wants the file's
true level asks for the native count and folds itself).

Measured on this Mac (M5 Pro, macOS 26.6), a 70-line probe compiled with
`kaya_swiftc -O`, each mode a fresh process, 30 thumbnails at
`maximumSize` 320x180 (results are 320x180):

| mode | wall | first image | peak RSS | frames returned |
|---|---|---|---|---|
| `images(for:)`, default tolerance | 0.24 s | 0.09 s | 24 MB | NEAREST keyframe, either side: 12 before, 18 after; 0 exact |
| `images(for:)`, tolerance after `.zero`, before infinite | 0.24 s | 0.09 s | 24 MB | 30 of 30 the keyframe BEFORE |
| `images(for:)`, both tolerances `.zero` | 1.97 s | 0.09 s | 34 MB | 30 of 30 exact |
| `image(at:)` × 30 in sequence, `.zero` | 2.23 s | 0.09 s | 33 MB | 30 of 30 exact |
| PCM read of the whole 10 min, min/max per 480 samples | 0.36 s | | 44 MB | 60,000 pairs, 28.8 M samples |

So the default is not "the frame before": it is the nearest sync sample,
and 18 of 30 came from AFTER the requested time (the worst 4.1 s either
side). An app
that labels a thumbnail with the requested time is showing a different
moment; the `actualTime` each result carries is the honest label. Exact
frames cost about 65 ms each on this file (hardware decode of up to 236
frames per request) and the batch overlaps work slightly better than a
sequential loop. Cancellation: cancelling the Swift `Task` iterating
`images(for:)` stopped delivery at once (15 of 30 delivered after 1 s, the
consumer returned in under 1 ms); the documented API for the callback form
is `cancelAllCGImageGeneration()`.

iOS has the same API and semantics (same availability, iOS 16 for the
async forms); its speed was not measured on a device here, and the
simulator decodes through the host, so a simulator number would not stand
for a phone. Codec coverage is AVPlayer's (§7a): no VP9, no WebM, AV1 only
where the chip decodes it. An `AVAssetImageGenerator` on a file AVPlayer
refuses fails the same way: on a VP9 WebM, `image(at:)` threw -11828 "This
media format is not supported." (measured), the same sentence and code the
player's `unsupported_container` maps from.

## Linux: GStreamer

There is no one-call API; the recipe is the GStreamer manual's snapshot
example, a pipeline ending in `appsink`, a seek, and `pull-preroll`
(https://gstreamer.freedesktop.org/documentation/application-development/advanced/pipeline-manipulation.html).
The seek flags are the accuracy knob: `KEY_UNIT | SNAP_BEFORE` lands on the
keyframe before (`SNAP_NEAREST`/`SNAP_AFTER` the others), `ACCURATE` decodes
forward to the exact frame
(https://gstreamer.freedesktop.org/documentation/gstreamer/gstsegment.html#GstSeekFlags).
`videoconvertscale` with an RGBA caps filter delivers raw RGBA at the
thumbnail size. GTK's `GtkMediaFile` is a player and offers no
frame-at-time read, so a GTK backend would build the pipeline either way.
Peaks are a second pipeline: demux, decode, `audioconvert` to F32 and an
`appsink` pulled with `sync=false`.

Measured in the linux lane image (`kaya-linux`, GStreamer 1.26.2, arm64 in
Docker's VM on this Mac, 18 CPUs, software decode only: no VA-API there),
one python3-gi process per mode, pipeline
`filesrc ! decodebin3 ! videoconvertscale ! video/x-raw,format=RGBA,width=320,height=180 ! appsink`:

| mode | wall | first image | peak RSS | frames returned |
|---|---|---|---|---|
| seek `FLUSH\|KEY_UNIT\|SNAP_BEFORE` + `pull-preroll` × 30 | 0.77 s | 0.09 s | 218 MB | 30 of 30 the keyframe BEFORE |
| seek `FLUSH\|ACCURATE` + `pull-preroll` × 30 | 2.33 s | 0.10 s | 237 MB | 30 of 30 exact |
| PCM: `qtdemux ! decodebin3 ! audioconvert ! fakesink`, decode only | 0.33 s | | 74 MB | |
| PCM + min/max per 480 samples in Python | 0.98 s | | 218 MB | 60,000 pairs |

Three findings worth keeping:

- THE DECODER UNDER GSTREAMER HERE IS FFMPEG. The image's H.264 and AAC
  decoders at primary rank are `avdec_h264` and `avdec_aac` (rank 256) from
  gst-libav, which wraps the distribution's libavcodec; `openh264dec` (64)
  and `faad` (128) are the fallbacks. So "the platform's own API" on Linux
  already means FFmpeg's decoders, dynamically linked from the distro, which
  is the LGPL's easy case and not kaya's to ship. A distro without
  gst-libav decodes H.264 through Cisco's openh264 (Fedora's route) or not
  at all (§7a's `-libav`/`-bad` column).
- A WHOLE-FILE `decodebin3` DECODES EVERY STREAM. The first peaks pipeline
  (`filesrc ! decodebin3`, audio pad linked) took 7.7 s instead of 0.33 s,
  because decodebin3 selected and decoded the video too. A peaks reader
  must select the audio stream before the decoder (`qtdemux` pad, or
  decodebin3's stream selection), or it pays a full video decode for a
  waveform.
- THE BUFFER PTS IS NOT THE PICTURE'S TIME. The MP4 carries an edit list
  (B-frames give a two-frame composition offset); qtdemux applies it through
  the segment, so `buffer.pts` reads two frames late (frame 300 arrived with
  PTS 10.067 s) while the seek itself is correct. The actual time must be
  computed through the sample's segment (`segment.to_stream_time`), the
  GStreamer twin of Apple's `actualTime`.

Codec coverage is the installed plugin set, §7a's Linux column: with
`-libav` or `-bad` it covers the whole suite; without a decoder for the
video, the frame pipeline fails to preroll (measured with both H.264
decoders ranked out through `GST_PLUGIN_FEATURE_RANK`: the PAUSED state
change failed), a loud failure where playbin plays the audio silently.

## Android: MediaMetadataRetriever, media3, MediaCodec

**Frames.** Three routes, all built in or in media3 (the earlier pass's §A5
has the catalogue):

1. `MediaMetadataRetriever.getScaledFrameAtTime(timeUs, option, w, h)`
   (API 27) with `OPTION_PREVIOUS_SYNC`, `OPTION_NEXT_SYNC`,
   `OPTION_CLOSEST_SYNC` or `OPTION_CLOSEST`
   (https://developer.android.com/reference/android/media/MediaMetadataRetriever).
   Synchronous and blocking; no cancellation; the decode runs in the media
   server process, not the app's, so the app's own heap stays flat.
2. media3's `FrameExtractor` (`media3-inspector-frame`, 1.10; the old
   `transformer.ExperimentalFrameExtractor` is removed): `getFrame(positionMs)`
   returns `ListenableFuture<Frame>` (a `Bitmap` and its presentation
   time), "must be accessed from a single application thread"
   (https://developer.android.com/media/media3/inspector/extract-frames).
   A future can be cancelled; the builder takes seek parameters and effects.
   It drives MediaCodec from the app, the same decoders media3's player
   uses. Not measured here: it needs an app module with the
   dependency, and its decoders are the ones measured below.
3. `MediaExtractor` + `MediaCodec` to an `ImageReader`, full control and the
   most code.

**Audio.** `MediaExtractor` + `MediaCodec` in decoder mode, 16-bit PCM out;
the only built-in route (no reader class like Apple's).

Measured on one warm pool emulator (API 35, emulator-5560, arm64 under
Hypervisor.framework), a dex run with `app_process` from `/data/local/tmp`,
deleted afterwards (listing before and after identical but for the
directory's mtime):

| mode | wall | first image | frames returned |
|---|---|---|---|
| `getScaledFrameAtTime(…, OPTION_PREVIOUS_SYNC, 320, 180)` × 30 | 1.37 s | 0.12 s | 30 of 30 the keyframe before |
| same, `OPTION_CLOSEST_SYNC` | 1.35 s | 0.07 s | nearest keyframe: 12 before, 18 after |
| same, `OPTION_CLOSEST` | 11.30 s | 0.18 s | 30 of 30 exact |
| `MediaExtractor` + `MediaCodec` (`c2.android.aac.decoder`), whole 10 min to PCM | 17.2-19.1 s | | 60,000 min/max pairs; the per-sample loop adds nothing measurable |

Findings:

- EVERY `getScaledFrameAtTime` CALL CREATES A NEW DECODER: logcat shows
  `Created component [c2.android.avc.decoder]` 90 times for the 90 calls.
  On the emulator that is the software decoder (`c2.android.avc`); a phone
  would use its hardware one, whose creation is not free either. The
  retriever is a one-frame tool; a filmstrip of hundreds would pay that per
  frame, and media3's `FrameExtractor` (one decoder kept across calls) is
  the route built for a timeline.
- THE PATH AND FD FORMS OF `setDataSource` NEED A CONTEXT ON API 35: both
  reached `FileUtils.convertToModernFd`, which asks a `Context` for the
  media provider (NullPointerException without one). An app always has one,
  so this only shaped the probe, which used a `MediaDataSource`.
- AAC DECODE THROUGH MEDIACODEC IS SLOW HERE: 17-19 s for 10 minutes,
  about 32x real time, against 0.31-0.36 s on the Mac and in the Linux
  image. That is ~0.65 ms per 1024-sample AAC frame, which reads as the
  per-buffer cost of the codec2 round trip (feeding inputs eagerly changed
  nothing), on an emulator; a phone was not measured. A waveform for a long
  file on Android is a progress bar, not an instant.

Codec coverage is the device's decoders (§7a's Android column: the whole
suite on the API 35 pool through media3). `FrameExtractor` takes a
`MediaItem` and so reads what media3's player reads; the retriever goes
through the platform's own extractors, whose container list was not
compared here.

## Windows: Windows.Media.Editing and Media Foundation

**Frames.** Two routes, both in the OS:

1. `MediaComposition.GetThumbnailAsync(time, w, h, VideoFramePrecision)` and
   `GetThumbnailsAsync(times, w, h, precision)`, over a composition holding
   one `MediaClip.CreateFromFileAsync(StorageFile)`; precision is
   `NearestFrame` or `NearestKeyFrame`; each result is an `ImageStream`, a
   JPEG (measured: `image/jpeg`)
   (https://learn.microsoft.com/en-us/uwp/api/windows.media.editing.mediacomposition.getthumbnailsasync).
   Cancellation is the WinRT `IAsyncOperation.Cancel()`. The earlier pass
   recorded an open report that the batch form returns the first thumbnail
   for every time (https://github.com/microsoft/WindowsAppSDK/issues/5049,
   Windows 11 23H2, unpackaged); it did NOT reproduce here (30 distinct,
   correct frames).
2. `IMFSourceReader` (`MFCreateSourceReaderFromURL`, `SetCurrentPosition`,
   `ReadSample`), with `MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING` for RGB32
   out (https://learn.microsoft.com/en-us/windows/win32/medfound/source-reader).
   `SetCurrentPosition` lands on the keyframe before; an exact frame means
   reading forward until the timestamp reaches the target.

**Audio.** The same `IMFSourceReader` on the audio stream with
`MFAudioFormat_Float` out.

Measured on the lane's Windows VM (Windows 11 26100, arm64, 6 vCPUs, no GPU
decode), a 200-line Rust probe on the `windows` 0.62 crate (the crate the
WinUI backend uses), cross-built with `cargo xwin`, run UNPACKAGED in the
interactive session through a `schtasks /it` task, never over ssh. The task
and its directory were removed afterwards; `dir C:\` and the task names
are identical before and after (only Windows' own next-run times moved).

| mode | wall | first image | peak working set | frames returned |
|---|---|---|---|---|
| `GetThumbnailsAsync`, `NearestKeyFrame`, 320x180 | 1.96 s | 1.96 s (one batch) | 166 MB | 30 of 30 the keyframe before |
| `GetThumbnailsAsync`, `NearestFrame` | 12.40 s | 12.40 s | 166 MB | 30 of 30 TWO FRAMES EARLY |
| `GetThumbnailAsync` × 30, `NearestKeyFrame` | 3.10 s | 0.20 s | 157 MB | 30 of 30 the keyframe before |
| `GetThumbnailAsync` × 30, `NearestFrame` | 13.31 s | 0.30 s | 166 MB | 30 of 30 two frames early |
| `IMFSourceReader`, seek + first sample, RGB32 | 1.81 s | 0.16 s | 149 MB | 30 of 30 the keyframe before |
| `IMFSourceReader`, read forward to the target | 38.71 s | 0.56 s | 152 MB | 30 of 30 two frames early |
| `IMFSourceReader` audio, float PCM, whole 10 min | 4.55 s | | 29 MB | 60,002 pairs (28,801,024 samples) |

Findings:

- BOTH ROUTES WORK UNPACKAGED, in the interactive session, from a plain
  Rust exe with no package identity. The session-0 question (§7a's
  `DXGI_ERROR_NOT_CURRENTLY_AVAILABLE`) was not tested, by the rule.
- MEDIA FOUNDATION IGNORES THE MP4 EDIT LIST. The file's `elst` says media
  starts at 1024 (two frames of video, 1024 samples of audio, the encoder
  delay and the AAC priming). Every "exact" Windows frame is the picture
  two frames BEFORE the one asked for, on both APIs, and the audio decode
  returns 1,024 more samples than the file's duration. Apple, Android and
  GStreamer all return the right picture. A filmstrip does not care about
  66 ms; an editor that cuts on a frame does, and so would a test reading
  frame numbers. Whether kaya's WinUI player position carries the same
  offset was not measured here.
- THE EXACT SOURCE-READER LOOP IS SLOW BECAUSE OF HOW IT WAS ASKED, not the
  decoder: with RGB32 output, every one of the 4,338 frames decoded on the
  way was colour-converted by the video processor. A real implementation
  reads NV12 and converts the one frame it keeps; `MediaComposition`'s
  12.4 s is the better reading of what Windows costs here.
- The keyframe modes are in the same range as the other platforms (2-3 s
  on a 6-vCPU VM without GPU decode).

Codec coverage is Media Foundation's (§7a): in-box H.264, AAC, MP3, FLAC,
the WebM container and Opus; HEVC, VP9 and AV1 need the Store extensions,
and both routes read what MF reads (not measured file by file here).

## FFmpeg

**What it does well.** One API (`libavformat` + `libavcodec`, seek with
`av_seek_frame(…, AVSEEK_FLAG_BACKWARD)` then decode to the target), one
behaviour, every codec in the build on every platform including VP9/WebM on
Apple and HEVC on Windows without the Store, frame-exact, and it honours the
edit list (measured below). It is what Qt, Shotcut, Kdenlive and Olive use.

Measured on this Mac with the dev shell's FFmpeg 9.0 CLI, one process per
thumbnail (so each figure includes 30 process starts):

| mode | wall | frames returned |
|---|---|---|
| `ffmpeg -ss T -i … -frames:v 1 -vf scale=320:180`, software | 3.65 s | 30 of 30 exact |
| same with `-hwaccel videotoolbox` | 13.89 s | 30 of 30 exact |
| whole-file audio to f32 PCM | 0.31 s | 28,800,000 samples (priming trimmed) |

The hardware row is FFmpeg's own warning made concrete: "most acceleration
methods are intended for playback and will not be faster than software
decoding on modern CPUs" (https://ffmpeg.org/ffmpeg.html); a per-request
VideoToolbox session costs more than the decode it saves. AVFoundation's
exact batch (1.97 s) beat FFmpeg software (3.65 s, less the process starts)
on the same machine by keeping one hardware session for the batch.

**What it costs kaya** (docs/probes/video-playback-2026-09-02-decoders.md
§B6-§B10 has the citations):

- LICENCE. LGPL 2.1 only without `--enable-gpl` (no x264/x265, no GPL
  filters) and without `--enable-nonfree`; dynamic linking is the easy road
  (§6b), static linking obliges shipping the app's object files for
  relinking (§6a). On iOS there are no user-replaceable shared libraries, so
  §6b is unavailable and §6a is honoured in letter at best; VLC is on the App
  Store because VideoLAN owns VLC, not because the LGPL solved anything.
  Android's signed APK is the milder form of the same hole.
- PATENTS. FFmpeg's own legal page declines to answer; H.264, HEVC and AAC
  decoders are patent-encumbered and the platform decoders carry the
  platform vendor's licence while a shipped FFmpeg carries none. Firefox
  dlopens the system FFmpeg on Linux for exactly this reason.
- SIZE. A full build's `libavcodec` alone is 14-17 MB installed (Debian);
  a decode-only H.264/HEVC/AAC build is roughly 2-4 MB per architecture,
  multiplied by every architecture a platform ships (Android's four ABIs,
  iOS device and simulator, macOS universal).
- A SECOND CODEC TABLE. kaya's player plays what the platform plays (§7a);
  an FFmpeg extractor would read files the player refuses (VP9 on Apple) and
  refuse nothing the player plays, so a filmstrip could show a video that
  will not play. The capability query (`can_play`) would no longer answer
  "can I get a thumbnail".
- On Linux the "platform" route already is FFmpeg (gst-libav), via the
  distribution, at no cost to kaya.

## Prior art: how other toolkits answer the same question

| toolkit | frames | waveform | shape |
|---|---|---|---|
| Expo (`expo-video`) | `player.generateThumbnailsAsync(times, {maxWidth, maxHeight})` ON THE PLAYER, Android `MediaMetadataRetriever` per time in parallel coroutines, iOS `AVAssetImageGenerator`; returns `VideoThumbnail` objects (`width`, `height`, `requestedTime`, `actualTime`) that are references to native images usable as an `Image` source, never files; the separate `expo-video-thumbnails` (files in the cache) is deprecated for it (https://docs.expo.dev/versions/latest/sdk/video/, source: packages/expo-video/android/…/VideoModule.kt and ios/VideoModule.swift) | none | platform APIs behind one call |
| Flutter `video_thumbnail` | Android `MediaMetadataRetriever` `OPTION_CLOSEST`, iOS `AVAssetImageGenerator` with tolerance before zero; JPEG/PNG/WebP bytes or a file (https://pub.dev/packages/video_thumbnail, last release 16 months ago) | | platform APIs, mobile only |
| Flutter `just_waveform` | | Android `MediaExtractor` + `MediaCodec`, Apple `ExtAudioFile`; writes a min/max file in the audiowaveform shape (https://github.com/ryanheise/just_waveform) | platform APIs; no Windows or Linux |
| React Native | `react-native-create-thumbnail`: Android `MediaMetadataRetriever` `OPTION_CLOSEST_SYNC`, iOS `AVAssetImageGenerator`, a file (https://github.com/souvik-ghosh/react-native-create-thumbnail); Expo's above | not surveyed | platform APIs |
| .NET MAUI Community Toolkit | `MediaElement` has no frame or waveform API (https://learn.microsoft.com/en-us/dotnet/api/communitytoolkit.maui.views.mediaelement) | none | left to the app |
| Qt 6 | no thumbnail API; an app plays into a `QVideoSink` and grabs frames; Qt Multimedia's default backend on Windows, macOS, Android and Linux is FFmpeg since 6.5, shipped as FFmpeg 7.1 (https://doc.qt.io/qt-6/qtmultimedia-index.html) | `QAudioDecoder` (decode to PCM; the app reduces) | FFmpeg under the toolkit's own API |
| the web / Electron | `<video>` seek + `drawImage` to a canvas, or WebCodecs; Mediabunny's `CanvasSink.canvasesAtTimestamps(times)` decodes each packet at most once for sorted times and yields canvases with their actual timestamps (https://mediabunny.dev/guide/media-sinks); Electron apps that need more ship FFmpeg binaries (`ffmpeg-static`, https://github.com/eugeneware/ffmpeg-static) | `decodeAudioData`, or precomputed peaks (peaks.js, wavesurfer.js) | browser decoders, else FFmpeg |
| Kdenlive, Shotcut | MLT's avformat producer (FFmpeg) | "audio thumbnails", cached per project | FFmpeg, GPL apps |
| Olive | FFmpeg | FFmpeg | FFmpeg |
| Pitivi | GES/GStreamer previewers | GStreamer | GStreamer |

The pattern: toolkits that ship a PLAYER built on platform players (Expo,
the Flutter and RN plugin families) extract through the same platform
frameworks and put the call next to the player; toolkits built on FFmpeg
(Qt 6, the editors) extract through FFmpeg because it is already there.
Nobody that plays through platform players adds FFmpeg just for thumbnails.
Waveforms are almost always left to a separate package that decodes to PCM
and reduces to min/max, and the result is the audiowaveform shape.

## The measurements side by side

The same file and the same 30 requests everywhere; 320x180 output; "early"
means the picture two frames before the one asked for (the edit-list
finding). Hosts differ (an M5 Pro, its Docker VM, an emulator on it, and a
6-vCPU arm64 Windows VM without GPU decode), so compare shapes, not
platforms.

| platform, API | 30 at a keyframe | 30 exact | which keyframe | exact correct? | 10 min of AAC to PCM |
|---|---|---|---|---|---|
| macOS, `AVAssetImageGenerator` batch | 0.24 s | 1.97 s | nearest by default; before with tolerance-after zero | yes | 0.36 s (`AVAssetReader`) |
| Linux image, GStreamer appsink | 0.77 s | 2.33 s | before (`SNAP_BEFORE`) | yes | 0.33 s (audio stream only; 7.7 s if decodebin3 also decodes the video) |
| Android emulator, `getScaledFrameAtTime` | 1.35-1.37 s | 11.30 s | before, or nearest | yes | 17-19 s (`MediaCodec`) |
| Windows VM, `MediaComposition` batch | 1.96 s | 12.40 s | before | NO, two frames early | |
| Windows VM, `IMFSourceReader` | 1.81 s | 38.71 s (RGB32 every frame; see above) | before | NO, two frames early | 4.55 s |
| macOS, FFmpeg 9.0 CLI, software, one process per frame | | 3.65 s | | yes | 0.31 s |

Every platform API can do the job at filmstrip scale: a keyframe filmstrip
of 30 is one to two seconds or less everywhere, exact frames a few seconds
on the desktops and about ten on the emulator and the VM. The one
correctness defect is Windows' edit list; the one performance hole is
Android's AAC decode for long waveforms.

## RECOMMENDATION

The question has three answers, and the measurements decide between them.

**Option A: one kaya call over each platform's own frameworks**
(RECOMMENDED). AVFoundation on macOS and iOS, media3's `FrameExtractor` and
`MediaCodec` on Android, a GStreamer pipeline on Linux, Media Foundation on
Windows. For: every platform has the API and it is fast enough (above); the
extractor reads exactly what kaya's player plays, so `can_play` stays the
one codec question and a thumbnail never shows a video that will not play;
hardware decoding where the platform has it; no licence, patent or size
cost; and it is the shape the closest prior art chose (Expo puts it on its
player, the Flutter and React Native plugins use the same calls). Against:
five backend arms to write and keep uniform, and two platform defects kaya
must absorb (Windows' ignored edit list; Android's slow AAC decode), which
is exactly the kind of difference kaya exists to hide.

**Option B: FFmpeg inside kaya.** One implementation, frame-exact, every
codec, correct on Windows. Against: the LGPL's relinking clause on iOS and
Android, no patent cover where the platform decoders have it, 2-4 MB per
architecture (14-17 MB for a full build), a second codec table that
disagrees with the player's, and hardware decode that is slower than
software for this job unless kaya keeps sessions alive. Nobody that plays
through the platform's player adds FFmpeg for thumbnails; Qt and the
editors use it because they already decode with it.

**Option C: leave it to the app** (docs/video-editor-plan.md §5 as
written). Costs kaya nothing; but a kaya app is written in one of nine
languages and the five frameworks are reachable from none of them without
writing a native plugin per platform, which is the work kaya is for. A Rust
editor could link FFmpeg itself (Option B moved into the app, with the
licence then the app's).

### The shape, if A is ruled

A SEPARATE READER OBJECT, not a method on the player. The editor reads
dozens of files at import without playing any, and a player holds a
decoder and a surface (Android's `resources` reason, §7b, is what too many
players earn). Expo's player method fits an app showing one video; a
reader object fits both, and a player can offer a convenience that opens
one on its own source later.

- `reader = media_reader(source)` — a path, an asset, or an http(s) URL as
  the player takes (§3). Opening it fails with the player's closed reason
  vocabulary (`unsupported_codec`, `unsupported_container`, `not_found`,
  `network`, `decode_error`, `timeout`), so an app reads one failure table
  for both.
- `reader.frames(times, max_width, max_height, accuracy)` — one async
  request for many times (every platform does a batch better than a loop:
  one decoder session on Apple; Mediabunny decodes each packet at most once
  for sorted times). `accuracy` is `keyframe` or `exact`, and
  `keyframe` means THE KEYFRAME AT OR BEFORE the time on every platform:
  that is the default on Android (`OPTION_PREVIOUS_SYNC`), GStreamer
  (`SNAP_BEFORE`) and Windows, and Apple's with tolerance-after zero
  (measured above), so the one semantics costs nothing anywhere. Results
  arrive one per time as they finish, each carrying the requested time, the
  ACTUAL time of the picture (every platform reports it; GStreamer's must
  go through the segment, Windows' must be corrected for the edit list) and
  an image.
- The image is a KAYA-HELD RASTER: premultiplied RGBA8, the layout the
  canvas already rasterizes in (canvas.rs, the canvas record's `pixels`),
  with a handle the app passes to the canvas's `draw_image` op (§8 ruling 3)
  and to an `image` widget, and a `pixels()` read for an app that caches
  its filmstrip to disk. The pixels never cross into the guest unless
  asked: a filmstrip of 300 frames at 160x90 is 17 MB that has no reason to
  travel through nine bindings and back. YES, IT RIDES THE CANVAS
  `draw_image` op, which is why the op should take a kaya image handle
  rather than encoded bytes.
- `reader.peaks(samples_per_pair)` — one async request, PCM decoded by the
  platform and REDUCED IN THE CORE, so the downmix and the bucket rule are
  one Rust function rather than five: min and max per bucket, per channel,
  as 16-bit values, the audiowaveform `.dat` fields (`sample_rate`,
  `samples_per_pair`, `channels`, `length`, data), with progress events,
  because ten minutes is 17-19 s on the Android emulator. Coarser zoom
  levels are a reduction of the result and need no API.
- Cancellation: closing the reader, or the binding's own cancellation of
  the request (a dropped future, a cancelled Task, a cancelled
  CompletableFuture), maps to `Task.cancel` / `cancelAllCGImageGeneration`,
  the pipeline to NULL, the `ListenableFuture`'s cancel, and
  `IAsyncOperation.Cancel` or a stop flag in the source-reader loop. One
  request in flight per reader; a new `frames` on a reader whose last
  request is still running cancels nothing implicitly (the app asks).
- Delivery uses the async machinery the dialogs already have
  (docs/async-dialogs-plan.md): the request is made in a transaction, the
  results arrive as occurrences, and each binding spells it as its own
  async idiom.

Per backend: Apple `AVAssetImageGenerator.images(for:)` and
`AVAssetReader`; Android `FrameExtractor` (built for a timeline, and an
object that lives across requests; the retriever creates a decoder per
frame, measured) and `MediaExtractor` +
`MediaCodec`; GTK a `decodebin3` + `appsink` pipeline with the audio and
video streams selected separately; WinUI `IMFSourceReader` with NV12 out,
converting only the frames kept, which also gives the audio and avoids
`MediaComposition`'s JPEG round trip (to be measured against
`MediaComposition`'s 12.4 s before it is chosen).

The guard that comes with it: a shared scene over a short clip carrying
this probe's frame-number bars (tools/gen-media.py would paint them: a
16x2 `geq` overlaid on the clip), asking
for exact frames and reading the numbers back out of the returned pixels
on every lane, plus a keyframe request asserting the actual time is a
keyframe at or before the request. It is the test that found the Windows
edit-list defect here, and it would fail on Windows today.

### Unsettled

- WINDOWS' EDIT LIST: kaya would have to read the MP4 `elst` itself (Media
  Foundation exposes no attribute for it that this pass found) and shift
  times by it, or document the two-frame error. Whether the WinUI player's
  reported position carries the same offset is unmeasured and worth one
  check, since the player's position is a shared-scene observable.
- Android's waveform speed on a real phone, and whether a parallel or
  async-mode `MediaCodec` helps; only the emulator was measured.
- `FrameExtractor` itself was not measured (it needs an app module);
  whether it keeps one decoder across `getFrame` calls, unlike the
  retriever, is the first thing its depth slice measures.
- iOS was not measured on a device; the API is macOS's.
- Whether `media_reader` should also take a source the player cannot play
  (it should not, by Option A's own argument).
