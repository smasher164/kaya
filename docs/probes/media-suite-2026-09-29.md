# The media test suite's support probe (2026-09-29)

Measured for docs/media-plan.md §8a ("The media test suite"). Every run
played a set of generated test files through each platform's own player,
with no kaya code, on this tree's hosts and lanes. Everything started was
stopped and shown gone (servers by `ps`, containers by `docker ps -a`, the
probe APK by `pm list packages`, the Windows task by `schtasks /query`,
the Windows copy of the files by `if exist`).

## The files

FFmpeg 9.0 from the dev shell. Video 160x90 at 25 fps, one flat colour
C83C1E; audio a 440 Hz sine at 48 kHz (a second track, 660 Hz, tagged
`fra`, the first `eng`); 2 s each. 59 files, 828 KB, of which the WAV is
192 KB. Byte-identical across two runs only with `-fflags +bitexact -flags
+bitexact` given as OUTPUT options (before `-i` they bind to the input and
every Ogg and WebM file differed run to run) and `-serial_offset 1` on the
Ogg muxer.

- `h264_aac.mp4`, `hevc_aac.mp4`, `hevc_aac.mov` (tag `hvc1`),
  `vp9_opus.webm`, `av1_aac.mp4`, `av1_opus.webm` (libaom);
- `tone.mp3`, `tone.m4a`, `tone.ogg` (Opus), `tone_opus.webm`,
  `tone.flac`, `tone.wav`;
- `captions.vtt` (two cues, "first cue" 0-1 s, "second cue" 1-2 s),
  `h264_tx3g.mp4` (those cues as a `mov_text` track, `eng`),
  `h264_2audio.mp4` and `vp9_2audio.webm` (two audio tracks);
- `hls_fmp4/` and `hls_mpegts/`: one video playlist, two audio renditions
  (en, fr) and a WebVTT subtitle rendition, 1 s segments, the master
  playlist written by hand; `dash/manifest.mpd` with the same three
  streams.

FFmpeg has no CEA-608 encoder, so no 608 file was made.

## The server

A 50-line python server honouring `Range`, bound to the one address each
lane needs. Reached as 127.0.0.1 from the mac and from the iOS simulator
(which shares the host's network), as 10.0.2.2 from the Android emulator
(the emulator's alias for the host loopback,
https://developer.android.com/studio/run/emulator-networking), as
192.168.64.1 (the host's bridge address) from the Windows VM, and as
127.0.0.1 inside the linux container, with the server started in it.
AVPlayer asks for `bytes=0-1` first. Served WITHOUT range support, as
python's stock `http.server` does, AVPlayer refuses a progressive MP4:
AVFoundationErrorDomain -11850 "The server is not correctly configured.",
underlying -12939.

## macOS 26.6.2, M5 Pro: AVPlayer, muted, `AVPlayerItemVideoOutput`, no window

Plays, frames arriving, centre pixel exactly C83C1E: H.264, HEVC (MP4 and
MOV), AV1 in MP4; audio MP3, AAC, Ogg Opus, FLAC, WAV; progressive HTTP;
HLS fMP4 and TS with both audio renditions (switching to `fr` took) and
the subtitle rendition listed. Two legible options for the tx3g file;
`[en, fr]` for the two-track MP4, switching took.

Fails, `AVFoundationErrorDomain -11828` "Cannot Open", "This media format
is not supported.", underlying -12847: every WebM (VP9, AV1, Opus) and the
DASH manifest. A sidecar `.vtt` opened as an asset is `isPlayable` false.
HTTP 404: NSURLErrorDomain -1100. Connection refused: NSURLErrorDomain
-1004. A missing LOCAL file: AVFoundationErrorDomain -11800 "An unknown
error occurred (-17913)", which names nothing.

## iOS simulator 26.5 (kaya-sim-0, the same probe through `simctl spawn`)

As macOS, pixel C93C1E, with one difference: `av1_aac.mp4` reaches
`readyToPlay` with the asset's `isPlayable` false, presentation size 0x0,
no frame ever, the clock advancing on the audio, and NO error. HEVC plays
on this Apple-silicon simulator. The probe was a bare binary, so App
Transport Security did not apply; an app bundle needs
`NSAllowsLocalNetworking` for plain http to a local server.

## Linux lane image (kaya-linux:latest, throwaway containers)

GStreamer 1.26.2. The image already carries `gstreamer1.0-plugins-base`
and `-good` (pulled in by xdg-desktop-portal) and nothing else of
GStreamer: no tools, no `-bad`, `-libav`, `-ugly`, `gstreamer1.0-gtk4` or
`libgtk-4-media-gstreamer`. `playbin3` into three fakesinks, counting the
buffers each received:

| installed | plays | fails |
|---|---|---|
| base + good (as shipped) | VP9/Opus WebM, MP3 (mpg123 is in good), Ogg Opus, Opus WebM, FLAC, WAV | H.264, HEVC, AV1 in MP4, AAC: "Missing element: … decoder", exit 1 |
| + libav | adds H.264, HEVC, AAC, progressive HTTP, HLS fMP4, DASH | AV1; HLS TS |
| + bad (without libav) | everything: openh264dec, libde265dec (with a warning, "Unsupported extra data version"), faad, av1dec (libaom), tsdemux | nothing |

Three silent shapes, all with base + good or base + good + libav:
`av1_opus.webm` exits 0 with 101 audio buffers, 0 video buffers and only a
missing-element message; `hls_fmp4` missing H.264 and `hls_mpegts` missing
`tsdemux` hang until the 20 s timeout with no error. `-ugly` changed
nothing. `dav1ddec` and `webvttdec` are absent from all of it. A sidecar
WebVTT through `playbin3`'s `suburi` delivered both cues (subparse, in
base). `gst-discoverer-1.0` (in `gstreamer1.0-plugins-base-apps`) lists
missing plugins with their installer detail, `decoder-video/x-h264,
level=(string)1.1, profile=(string)high`, and reads the WebM tracks'
languages as `en` and `fr`. HTTP 404: souphttpsrc "Not Found"; a missing
file: filesrc "Resource not found.".

## Android (emulator-5562, API 35 arm64): media3 1.10.1 with -hls and -dash

Decoders on the pool (`dumpsys media.player`): `c2.goldfish.{h264,vp8,vp9}`
(host offload) and `c2.android.{avc,hevc,vp8,vp9,av1,av1-dav1d,aac,mp3,
opus,flac,vorbis}` (software). There is no `c2.goldfish.hevc.decoder` on
this image, so the looping bug of androidx/media#2461 is not reachable.

A standalone probe APK (the 2026-09-29 video probe's build, plus
`media3-exoplayer-hls` and `-dash` at 1.10.1, `usesCleartextTraffic`),
files in its APK assets as `asset:///` URIs: EVERY item plays to the end.
HEVC decodes on `c2.android.hevc.decoder`, AV1 on
`c2.android.av1-dav1d.decoder`, VP9 on `c2.goldfish.vp9.decoder`; WAV needs
no decoder. tx3g and the sidecar VTT (`SubtitleConfiguration`,
`text/vtt`) each delivered 2 cues; HLS fMP4 delivered 2 and TS 1 in the
window read. `setPreferredAudioLanguage("fr")` switched the two-track MP4,
WebM, HLS and DASH. HLS and DASH were still buffering 3.5 s after
`prepare` on the first run and played to the end within 20 s on the
second. Errors: missing asset `ERROR_CODE_IO_FILE_NOT_FOUND` (2005); 404
`ERROR_CODE_IO_BAD_HTTP_STATUS` (2004), "Response code: 404", after
retries (not yet raised at 3.5 s); refused `ERROR_CODE_IO_NETWORK_CONNECTION_FAILED`
(2001).

## Windows 11 Pro 25H2 (26200), ARM64 VM: `Windows.Media.Playback.MediaPlayer`

Installed Store packages: HEVCVideoExtension 2.5.33, AV1VideoExtension
2.0.35, VP9VideoExtensions 1.2.20, WebMediaExtensions 2.1.51,
MPEG2VideoExtension. Run from Windows PowerShell 5.1, which cannot
subscribe to WinRT events, so `MediaFailed`'s reason was not read; the
probe polled `PlaybackSession`, `MediaSource.State` and each track's
`SupportInfo`.

In the interactive session (a `schtasks /it` task, the lanes' route),
EVERY item plays: H.264, HEVC (MP4, MOV), VP9 and AV1 WebM, AV1 MP4, every
audio file, progressive HTTP, HLS fMP4 and TS (audio `en, fr`, text `en`
Subtitle), DASH (audio `eng, fra`). The tx3g track was NOT listed among
`TimedMetadataTracks`. Missing file and 404: `MediaSource.State` Failed.
Refused connection: still `Opening` after 8 s.

Over ssh (a non-interactive session) the same player on the same VM left
H.264 whose height is not a multiple of 16 (160x90, 640x360) and every
HEVC file at PlaybackState None, never advancing, while 160x96 and 640x368
H.264, VP9, AV1 and all audio played. Media playback measurements on the
Windows VM are taken in the interactive session.

Without the extensions was not measured (it means uninstalling Store
packages). Microsoft's table
(https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/supported-codecs,
2026-05-12): "H.265 and AV1 are available with the install of the
corresponding optional codec pack"; VP9 is listed in fMP4, MP4 and MKV;
WebM is a Matroska profile and MKV is listed in-box; there is no Ogg
column and no Opus or Vorbis row. The Web Media Extensions package's Store
description names the Ogg container and the Vorbis and Theora codecs;
whether Opus is in-box or the extension's is not settled here. WebVTT is a
supported timed text format.
