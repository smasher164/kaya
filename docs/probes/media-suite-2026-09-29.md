# The media test suite's support probe (2026-09-29)

Measured for docs/media-plan.md §7a ("The media test suite"). Every run
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

## Follow-up, 2026-09-30

Asked by the maintainer after the first pass. A C# console probe on the
VM (.NET 10, the Windows SDK projection) that catches `MediaFailed` with
its HRESULT, which Windows PowerShell 5.1 could not; the same binary run
over ssh and through a `schtasks /it` task, the lanes' route.

### Windows: why an ssh session cannot play H.264 at 90 rows or any HEVC

In plain words: an ssh login on Windows runs in SESSION 0, the services
session. Its window station (`Service-0x0-…$`) has no display at all:
`EnumDisplayDevices` returns nothing and every DXGI adapter reports zero
outputs. The logged-in desktop is session 1 (`WinSta0`), with the Basic
Display Driver and the VirtIO GPU as its two displays. Decoding is the same
software decoding in both sessions; what fails in session 0 is the
player's own picture presentation, for the frames that need cropping.

Measured, the same in both sessions unless said:

- The VM's only Direct3D adapter is the Microsoft Basic Render Driver
  (1414:008C, software). `D3D11CreateDevice` with video support succeeds at
  feature level 11_0, but the device has no `ID3D11VideoDevice`, so there
  is no DXVA hardware decoding in either session. `MFTEnumEx` lists no
  hardware decoder for H.264, HEVC, VP9 or AV1.
- One decoder per codec, and the DLLs the process loads name it: H.264 is
  the in-box "Microsoft H264 Video Decoder MFT" (`msmpeg2vdec.dll`, CLSID
  62ce7e72-4c71-4d20-b15d-452831a87d9d); HEVC is the Store extension's
  `HEVCDECODER_STORE.dll`, VP9 `msvp9dec_store.dll`, AV1
  `av1decodermft_store.dll`.
- The decoders work in session 0. An `IMFSourceReader` decoding to NV12
  delivers all 50 frames of every clip in both sessions, with software
  decoding forced (`MF_SOURCE_READER_DISABLE_DXVA`) and with a D3D11 device
  manager. H.264 comes out in whole 16-row macroblocks with a display
  aperture: 160x90 decodes to 160x96 with a 160x90 aperture, 640x360 to
  640x368. The HEVC extension sets an aperture on every frame (160x96 even
  for the 96-row clip). VP9 and AV1 frames come out at their own size.
- `MediaPlayer` in its default mode, session 0: the clip opens
  (`MediaOpened`), then within 20 ms `MediaFailed` with
  `Error=DecodingError`, `ExtendedErrorCode` 0x887A0022
  (`DXGI_ERROR_NOT_CURRENTLY_AVAILABLE`) and an empty message; the state
  returns to `None` and the session's properties then throw 0xC00D3E85
  (`MF_E_SHUTDOWN`). The track's `SupportInfo.DecoderStatus` still reads
  `FullySupported`. It fails for every H.264 clip whose height is not a
  multiple of 16 (160x90 High and Baseline, 640x360) and both HEVC clips
  (90 and 96 rows); 160x96 and 640x368 H.264, VP9 and AV1 play. The failing
  runs load the video processor (`msvproc.dll`) and `dcomp.dll`. Which call
  inside the Media Engine returns the DXGI error was not measured.
- The same player in FRAME-SERVER mode (`IsVideoFrameServerEnabled`, where
  the player presents nothing and raises `VideoFrameAvailable` for the app)
  plays all ten clips in session 0, 36 to 50 frames each.
- In session 1 (`schtasks /it`) the default mode plays all ten.

Does it touch kaya's lanes: no. Every windows leg already runs in session 1
through `schtasks /it`, kaya's video view draws through
`MediaPlayerElement` in the app's window there, and frames mode is the
frame-server mode that works even in session 0. One exposure: deploy-win's
guest unit-test phase runs `kaya-unittests.exe` over ssh, in session 0, so
a unit test that plays video through the player's own presentation would
fail there; such a test uses frame-server mode or runs through
`schtasks /it`. Media measurements on the VM are taken in session 1.

### Windows: the Store extensions, and playing without them

Installed and provisioned, for the one user: VP9VideoExtensions 1.2.20,
HEVCVideoExtension 2.5.33, AV1VideoExtension 2.0.35, WebMediaExtensions
2.1.51, MPEG2VideoExtension 1.2.32, AVCEncoderVideoExtension 1.1.47,
RawImageExtension 2.5.35, HEIFImageExtension 1.2.48, WebpImageExtension
1.2.31. Their manifests say what each adds to Media Foundation:
VP9 a VP9 decoder (and an encoder), HEVC a decoder and encoders, AV1 a
decoder, and Web Media Extensions an FFmpeg media source for `.ogg`,
`.ogv`, `.oga`, `.ogx`, `.ogm`, `.opus` and `audio/ogg`, `video/ogg`,
`application/ogg`, a Vorbis decoder and a Theora decoder. In-box: the
WebM/Matroska source (`mfmkvsrcsnk.dll`, registered for `.webm`, `.mkv`),
the Opus decoder (`MSOpusDecoder.dll`), FLAC (`MSFlacDecoder.dll`), MP3,
AAC and H.264.

Measured WITHOUT them: VP9, HEVC, AV1 and Web Media Extensions removed for
the user (`Remove-AppxPackage`; the payload stays staged because the
packages are provisioned), the set played in session 1, then all four
re-registered (`Add-AppxPackage -Register`, which is refused over ssh with
0x80070005 and works in session 1) and the package list and manifests
compared equal to the listing taken before, and the set played again.

| item | without the four |
|---|---|
| H.264 + AAC, MP4 | plays |
| HEVC MP4 and MOV, VP9 WebM (both), AV1 MP4 and WebM | QUIET: `Playing`, the clock advancing on the audio, size 0x0, no `MediaFailed`; only the video track's `SupportInfo.DecoderStatus` = `UnsupportedSubtype` says so |
| Opus in WebM | plays (in-box container and decoder) |
| Opus in Ogg | fails: `MediaFailed` `SourceNotSupported`, 0xC00D36C4 (`MF_E_UNSUPPORTED_BYTESTREAM_TYPE`); the Ogg container is Web Media Extensions' |
| MP3, AAC (M4A), FLAC, WAV | play |

So on a Windows without the packages the dangerous shape is the quiet
one, the iOS simulator's AV1 case again, and kaya's `unsupported_codec`
rule reading `SupportInfo.DecoderStatus` is what catches it.

### Windows: why the MP4 tx3g caption track is not listed

Media Foundation's MP4 source does not expose the text track at all. A
source reader over `h264_tx3g.mp4` finds two streams, AAC audio and H.264
video, and the file's third track (handler `sbtl`, sample entry `tx3g`,
language `eng`) is not among them; `MediaPlaybackItem.TimedMetadataTracks`
stays empty through open and play. The same holds for the track as `tx3g`
in a `.3gp` and as a QuickTime `text` track in a `.mov`. What does reach
`TimedMetadataTracks`, with `CueEntered` delivering "first cue" at 0 ms and
"second cue" at about 1020 ms:

- a sidecar WebVTT through `TimedTextSource.CreateFromStream` added to
  `MediaSource.ExternalTimedTextSources` (`Resolved` with no error, one
  `Subtitle` track);
- a sidecar SRT the same way;
- SRT in-band in Matroska (`S_TEXT/UTF8`, language `en`).

WebVTT in-band in Matroska is not listed. HLS WebVTT is listed (first
pass). So on Windows the tx3g item is `unsupported`-shaped for captions
only (the video plays), and kaya either draws those cues itself from its
own read of the track or the Windows lane table names the item as
captionless.

### The local server from every lane

The first pass's Range server (python, `ThreadingHTTPServer`), started twice
on the mac, bound to 127.0.0.1 and to the UTM bridge address 192.168.64.1
(`bridge100`), port 8765, serving `h264_aac.mp4` (20,496 bytes, sha256
1711cdb3c000f6c5…). The macOS application firewall is off on this host
(`socketfilterfw --getglobalstate`: disabled), so no prompt could appear;
with it on, a listener on a non-loopback address is what would raise one.

| lane | address | result |
|---|---|---|
| mac | 127.0.0.1 | 200, 20,496 bytes, hash equal; `Range: bytes=0-1` 206, 2 bytes. `en0`'s address refused (nothing bound there) |
| iOS simulator (kaya-sim-0) | 127.0.0.1 and `localhost` | AVPlayer (the first pass's probe via `simctl spawn`) ready, 160x90, 15 frames, C93C1E; the log shows its `bytes=0-1` probe then `bytes=0-20495` |
| Android (emulator-5554, API 35) | 10.0.2.2 | `nc` from `adb shell`: 206 for the Range request, the full body with headers for the plain one |
| Windows VM | 192.168.64.1 | `Invoke-WebRequest` 200, 20,496 bytes, hash equal; `curl.exe -r 0-1` 206, 2 bytes. The VM's own 127.0.0.1 is not the host ("Unable to connect") |
| linux lane image, a throwaway container | `host.docker.internal` (192.168.65.254) and 192.168.64.1 | both 200 with the hash equal, Range 206: Docker Desktop's host route reaches a server bound to the host's loopback alone |

So one server on the host serves all five lanes from two bindings,
loopback and the bridge, and neither is reachable from the LAN. The linux
lane may equally run it inside the container (the plan's choice); both
work. Both servers stopped, `lsof` shows no listener on 8765.

### Public test streams (extra evidence, not for the record)

Nine public streams, each through each platform's own player the way the
first pass ran the local set: the mac and the iOS simulator (kaya-sim-0)
through the AVPlayer probe with no window, Android (emulator-5562) through
the media3 1.10.1 probe APK, Windows through the C# probe in session 1, the
lane image through `playbin3` into counting fakesinks with `-bad`, `-libav`
and `-base-apps` installed in a throwaway container. Bitmovin's public demo
manifests answered 403 to a plain request (both the old akamaihd host and
cdn.bitmovin.com) and were left out.

| stream | what is in it | macOS / iOS sim | Windows | Linux | Android |
|---|---|---|---|---|---|
| Apple bipbop advanced, fMP4 HLS | 24 H.264 renditions to 1080p, AAC/AC-3/E-AC-3, WebVTT + CEA-608 | plays, 960x540 then 1920x1080; legible `en` sbtl and clcp | plays, but `MediaOpened` only at 12.0 s (two runs); `en` Subtitle listed | plays, 960x540 and 1920x1080, 24 text buffers | plays 768x432, first frame 1.8 s, CEA-608 cues |
| Apple bipbop advanced HEVC, fMP4 HLS | HEVC and H.264 renditions | plays 1920x1080 | plays after 12.7 s, 416x234 | plays | plays; media3 picked an H.264 rendition |
| Apple bipbop 16x9, TS HLS | 5 H.264 renditions, 2 audio, subtitles in en, fr, es, ja | plays; 8 legible options | HANGS: `Opening` at 90 s, no error, though `AdaptiveMediaSource` is created in 0.33 s with 6 bitrates | plays, 416x234 then 1920x1080 | plays, all subtitle languages listed |
| Mux x36xhzz, HLS | Big Buck Bunny, 5 renditions, AAC and HE-AAC | plays | plays from 320x184 | plays | plays |
| Shaka angel-one, HLS | 7 audio languages, 4 WebVTT subtitle languages | plays; `fr` selected and taken | plays; 6 audio and 4 text tracks listed | plays, 11 cue buffers; discoverer reads `en de it fr es en` | plays; switched to `fr` |
| Akamai bbb_30fps, DASH | H.264 to 2160p, HE-AAC | FAILS -11850 (below) | plays from 320x180 | plays, 320x180 to 3840x2160 | plays (3840x2160 chosen) |
| DASH-IF IOP 3.3 adaptation set switching 5 | H.264 and HEVC (`hev1`) video sets | FAILS -11850 | plays, 2 video tracks | plays | plays |
| DASH-IF livesim2 testpic_2s | LIVE (`type="dynamic"`) | FAILS -11850 | FAILS: `SourceNotSupported`, 0xC00D6591; `AdaptiveMediaSource` says `UnsupportedManifestProfile` | plays | plays |
| Shaka angel-one, DASH | VP9 and H.264, AAC and Opus, 7 languages, WebVTT in MP4 (`wvtt`) | FAILS -11828 "This media format is not supported." | plays; 10 audio, 4 text tracks | plays, VP9 | plays VP9 on `c2.goldfish.vp9`; switched to `fr` |

What the real streams add over the generated ones:

- AVFoundation's DASH failure is not always -11828. The Akamai and
  livesim servers answer AVPlayer's opening `Range: bytes=0-1` with 200 and
  the whole body (measured with curl), and AVPlayer then reports -11850
  "The server is not correctly configured." (underlying -12939) before it
  reads the format; Google's storage honours `Range` (206) and gets the true
  -11828. So on Apple the SAME unsupported container surfaces as a server
  error from a server that ignores `Range`.
- Windows opens Apple's fMP4 HLS about 12 s after the adaptive source is
  created, where the other players need 0.2 to 2.5 s, and never starts the
  TS one. Neither shows in the local HLS trees, which Windows plays at
  once. It does not play a live DASH manifest.
- ABR works everywhere it plays: GStreamer and AVPlayer switch renditions
  within the first seconds; media3 and Windows start low or high by their
  own estimate.
- Multiple audio languages and WebVTT subtitle renditions are listed on
  every platform that plays the stream, and switching audio to `fr` took
  on AVPlayer and media3.

### How long a failed stream takes to fail

Each player given one URL, the time from load to the failure it reports.
The scene's refused port is the first column.

| | refused port | unresolvable host (`.invalid`) | HTTP 404 (a public server) | unroutable address (10.255.255.1) |
|---|---|---|---|---|
| macOS | 0.1 s, NSURLErrorDomain -1004 | 0.1 s, -1003 | 1.5 s, -1100 | 75 s, -1001 timed out |
| iOS simulator | 0.1 s, -1004 | 0.1 s, -1003 | 1.2 s, -1100 | 75 s, -1001 |
| Windows | 16.3 to 16.6 s, `MediaFailed` `SourceNotSupported`, 0xC00D0035 `NS_E_SERVER_NOT_FOUND` | 0.03 s, the same | 1.3 s, `SourceNotSupported`, 0xC00D001A `NS_E_FILE_NOT_FOUND` | still `Opening` at 90 s, no error |
| Linux (GStreamer) | 0.01 to 0.14 s | 0.03 s | 1.3 s, `RESOURCE_ERROR` "Not Found" | 15 s |
| Android (media3) | 4.7 s, 2001 `ERROR_CODE_IO_NETWORK_CONNECTION_FAILED` | 3.3 s, 2001 | 6.2 s, 2004 | 35 s, 2002 `ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT` |

The names of 0xC00D0035 and 0xC00D001A are from the Windows SDK's
`nserror.h` on the VM (certutil names neither). Windows' own TCP stack
refuses the same port in 2.0 s (`curl.exe`, `TcpClient`: it retries the
SYN twice), so Media Foundation's 16 s is its HTTP source retrying. Two
mapping facts: WinUI reports every network failure, refused, unresolvable
and 404 alike, as `MediaPlayerError.SourceNotSupported`, never
`NetworkError`, so the reason is read from `ExtendedErrorCode`; and
GStreamer reports a refused, unresolvable or unroutable connection as a
STREAM error from `souphttpsrc` ("Internal data stream error", flow -5),
with only the 404 a resource error.

The harness's expect window is 15 s (`POLL_DEADLINE`,
crates/kaya/src/harness.rs), and Windows fails the refused port at about
16.5 s, so an expect of `failed(network)` after a refused port cannot pass
on Windows as scenes are written today, while every other platform is
inside 5 s. The unresolvable host is inside 3.3 s everywhere but needs a
resolver that answers for `.invalid`.
