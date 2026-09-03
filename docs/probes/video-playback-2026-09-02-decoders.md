# kaya video: THE DECODER ROUTES — research notes

Research date: 2026-09-02. Every claim carries a URL. Primary sources preferred.
Status: IN PROGRESS (appended as learned).

## Crate maintenance snapshot (observed 2026-09-02, crates.io JSON API)

| crate | latest | last release | downloads | repo |
|---|---|---|---|---|
| `ffmpeg-next` | **9.0.0** | **2026-08-05** | 6,766,861 | https://github.com/zmwangx/rust-ffmpeg |
| `rsmpeg` | **0.18.0+ffmpeg.8.0** | **2025-08-24** | 168,571 | https://github.com/larksuite/rsmpeg |
| `gstreamer` (gstreamer-rs) | **0.25.3** | **2026-06-29** | 10,029,512 | https://gitlab.freedesktop.org/gstreamer/gstreamer-rs |
| `windows` (windows-rs) | **0.62.2** | **2025-10-06** | 312,237,949 | https://github.com/microsoft/windows-rs |
| `objc2-video-toolbox` | **0.3.2** | **2025-10-04** | 49,981 | https://github.com/madsmtm/objc2 |
| `ndk` (rust-mobile) | **0.9.0** | **2024-04-26** | 50,881,460 | https://github.com/rust-mobile/ndk |
| `cros-codecs` | **0.0.6** | **2025-06-18** | 1,992,353 | https://github.com/chromeos/cros-codecs |
| `rav1d` | **1.1.0** | **2025-05-07** | 32,940 | https://github.com/memorysafety/rav1d |
| `dav1d` (dav1d-rs) | **0.11.1** | **2025-11-25** | 1,238,301 | https://github.com/rust-av/dav1d-rs |

Sources: https://crates.io/api/v1/crates/ffmpeg-next , /rsmpeg , /gstreamer , /windows , /objc2-video-toolbox , /ndk , /cros-codecs , /rav1d , /dav1d

## A1. Apple — VideoToolbox vs AVAssetReader

**Apple's own framing.** The VideoToolbox landing page abstract is "Work directly with hardware-accelerated video
encoding and decoding capabilities", and the overview reads:

> "VideoToolbox is a low-level framework that provides direct access to hardware encoders and decoders. It
> provides services for video compression and decompression, and for conversion between raster image formats
> stored in CoreVideo pixel buffers. These services are provided in the form of session objects (compression,
> decompression, and pixel transfer), which are vended as Core Foundation (CF) types. **Apps that don't need
> direct access to hardware encoders and decoders shouldn't need to use VideoToolbox directly.**"

Platform floors listed there: iOS/iPadOS 6.0, macOS 10.8, tvOS 10.2, Mac Catalyst 13.0, visionOS 1.0.
Source: https://developer.apple.com/documentation/videotoolbox (JSON: https://developer.apple.com/tutorials/data/documentation/videotoolbox.json)

**It is a C API, not Objective-C.** The types are Core Foundation types (`VTDecompressionSessionRef`,
`CMSampleBufferRef`, `CVImageBufferRef`) and the entry points are plain C functions with a C function-pointer
output callback — `VTDecompressionSessionCreate(allocator:formatDescription:decoderSpecification:imageBufferAttributes:outputCallback:decompressionSessionOut:)`
and `VTDecompressionSessionDecodeFrame(_:sampleBuffer:flags:frameRefcon:infoFlagsOut:)`.
Sources: https://developer.apple.com/documentation/videotoolbox/1536134-vtdecompressionsessioncreate ,
https://developer.apple.com/documentation/videotoolbox/1536071-vtdecompressionsessiondecodefram
The decompression output callback hands back a **`CVImageBufferRef`** (a `CVPixelBuffer`), and by asking for
`kCVPixelBufferIOSurfacePropertiesKey` in `imageBufferAttributes` you get IOSurface-backed buffers that can be
handed to Metal/CoreImage with no copy.

**The two levels, and which is right for kaya.**
- `AVAssetReader` + `AVAssetReaderTrackOutput` is the *file* level: it demuxes, feeds the decoder, and vends
  decoded `CVPixelBuffer`s in the pixel format you asked for in the output settings. Apple's own description:
  "If you want only to read media data from one or more tracks and potentially convert that data to a different
  format, use the AVAssetReaderTrackOutput class."
  https://developer.apple.com/documentation/avfoundation/avassetreadertrackoutput
- `VTDecompressionSession` is the *sample* level: you already have a `CMSampleBuffer` (you demuxed it yourself,
  or it came off a network socket) and you want it decoded.

For "give me decoded frames of a file as fast as possible" the right level is **AVAssetReader**: it is the
supported route, it handles the demux, and (WWDC20 session 10090, "Decode ProRes with AVFoundation and
VideoToolbox") it "reads samples from the source file, optimizing them for the RPC that will happen in the
Video Toolbox, and it decodes the video data in the sandbox process, providing the decoded CVPixelBuffers in
the requested output format." https://developer.apple.com/videos/play/wwdc2020/10090/
VTDecompressionSession is the right level only when kaya wants to own the container parsing (which it would
have to if it wants ONE demuxer across five platforms).

**Rust crates (objc2 family, madsmtm).** All observed 2026-09-02 on crates.io:
- `objc2-video-toolbox` 0.3.2, released **2025-10-04**, 49,981 downloads. https://crates.io/crates/objc2-video-toolbox
- `objc2-core-video` (CVPixelBuffer/CVImageBuffer) and `objc2-core-media` (CMSampleBuffer) are siblings in the
  same generated family; `objc2-av-foundation` covers AVAssetReader. Repo: https://github.com/madsmtm/objc2
The whole family is auto-generated from Apple's own headers/metadata and released in lockstep, so maintenance
state is "actively generated" rather than "hand-maintained per framework" — but note the version numbers are
0.3.x, i.e. pre-1.0 and API-unstable.
The older hand-written `core-video-sys` / `core-foundation-sys` route still exists but the objc2 family has
displaced it for new work.

## A2. Android — AMediaCodec / AMediaExtractor

**API floor.** The NDK media APIs (`AMediaCodec`, `AMediaExtractor`, `AMediaFormat`) were introduced in
**API 21 (Android 5.0 Lollipop)**; the headers carry `__INTRODUCED_IN(21)` on the core entry points.
`AImageReader` (`media/NdkImage.h`, `media/NdkImageReader.h`) is **API 24**, and `AHardwareBuffer` is **API 26**.
Sources: https://developer.android.com/ndk/reference/group/media ,
https://android.googlesource.com/platform/frameworks/av/+/master/media/ndk/include/media/NdkMediaCodec.h
kaya's Android floor is already well above 21, so the NDK route is available unconditionally.

**Both output routes exist.**
- **To a CPU buffer:** configure with a NULL surface, then `AMediaCodec_dequeueOutputBuffer` +
  `AMediaCodec_getOutputBuffer` gives you a `uint8_t*` of the decoded frame in whatever colour format the codec
  negotiated (typically some NV12/YUV420 flavour, and the exact one is *device-dependent* — this is the classic
  MediaCodec portability tax; see Big Flake's long-standing notes, https://www.bigflake.com/mediacodec/).
- **To a Surface:** configure with an `ANativeWindow`. For an app that wants the pixels back rather than
  composited, the zero-copy route is `AImageReader_newWithUsage()` → `AImageReader_getWindow()` → hand that
  `ANativeWindow` to `AMediaCodec_configure`, then `AImageReader_acquireNextImage` and
  `AImage_getHardwareBuffer()` for an `AHardwareBuffer` you can import into GL/Vulkan without a CPU copy.
  Both Chromium and Firefox took exactly this route:
  https://bugzilla.mozilla.org/show_bug.cgi?id=1649110 (Firefox "Add AImageReader with MediaCodec support on Android"),
  https://groups.google.com/a/chromium.org/g/feature-media-reviews/c/vuadhaZcLo0 (Chromium "Implement Video decode path using AImageReader").

**The cost difference.** Surface/AImageReader output keeps the frame in GPU-resident memory; the ByteBuffer route
forces the decoder to write to (and often *convert into*) system memory. Firefox's own bug notes that with
AHardwareBuffer "there's no need for additional GL texture images and memory usage could be reduced", whereas
the shared-memory path needs an extra GL texture upload per frame. The counterweight Chromium recorded is that
cross-process IPC between AImageReader and MediaCodec can *slow* decode; in-process it is fine.
**For kaya this matters a lot**: kaya rasterizes on the CPU with tiny-skia and the backends blit. A CPU-side
frame is what kaya's architecture actually wants — which means Android's *cheap* path (Surface) is the one kaya
would have to undo, and the ByteBuffer path is the one whose device-dependent colour formats kaya would have to
normalise itself.

**Rust access.** The `ndk` crate (rust-mobile) has a `media` module ("Bindings for the NDK media classes"),
a `media_error` module, and `hardware_buffer` (API 26) / `hardware_buffer_format` modules.
https://docs.rs/ndk/latest/ndk/ — but note the crate's last release is **0.9.0, 2024-04-26**
(https://crates.io/api/v1/crates/ndk), i.e. no release in over two years as of 2026-09; `ndk-sys` carries the raw
bindgen output regardless. So the raw FFI is there; the safe wrapper is stale and kaya would likely drive
`ndk-sys` directly.

## A3. Linux — GStreamer, VA-API, and the honest answer

**GStreamer + `appsink` is the pull-decoded-frames route.** `decodebin` (or `uridecodebin`) → `appsink`, and the
app calls `pull_sample()` / `try_pull_sample()`; the docs note appsink internally queues buffers from the
streaming thread and will grow memory if the app does not pull fast enough, and that `emit-signals=true` gives
a callback shape instead. https://gstreamer.pages.freedesktop.org/gstreamer-rs/git/docs/gstreamer_app/struct.AppSink.html
Rust example (upstream): https://github.com/sdroege/gstreamer-rs/blob/main/examples/src/bin/decodebin.rs
`gstreamer-rs` is the healthiest binding in this whole survey: **0.25.3 released 2026-06-29**, 10.0M downloads,
maintained by Sebastian Dröge at https://gitlab.freedesktop.org/gstreamer/gstreamer-rs

**What must be installed.** The bindings need GStreamer ≥ 1.14 and gst-plugins-base ≥ 1.14 to *build*; to
actually decode anything you need plugins from base/good/bad/ugly and/or **gst-libav**. On Debian/Ubuntu the
usual set is `libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-plugins-{base,good,bad,ugly}
gstreamer1.0-libav`. (gstreamer-rs README, https://gitlab.freedesktop.org/gstreamer/gstreamer-rs)

**THE CATCH, and it is the important finding for this slice:** GStreamer's software H.264 decoder *is FFmpeg*.
`avdec_h264` is described by GStreamer's own documentation as the "libav h264 decoder", shipped in the
**"GStreamer FFMPEG Plug-ins"** package (gst-libav).
https://gstreamer.freedesktop.org/documentation/libav/avdec_h264.html
So "use GStreamer on Linux instead of FFmpeg" does not avoid FFmpeg — it moves the FFmpeg dependency into the
distro's package set, where the *distro* has already made the LGPL/GPL/patent decision on the user's behalf.
That is a real advantage (kaya distributes no codec) and a real fragility (a machine without gst-libav or a
hardware decoder plugin simply cannot open an H.264 file, and kaya's error message is "no decoder").

**VA-API directly (`libva`, or `cros-codecs`).** Realistic only as an *accelerator*, not as the route:
- It is decode/encode *acceleration*, not a demuxer; you still need to parse the container and the bitstream
  headers yourself, which is why `cros-codecs` ships H.264/H.265/VP8/VP9/AV1 *stream parsers* alongside its
  VAAPI backend. https://github.com/chromeos/cros-codecs
- Driver coverage is uneven. Arch's wiki: Intel works via intel-media-driver from Broadwell on; AMD works with
  the free drivers; **NVIDIA proprietary needs the third-party `nvidia-vaapi-driver`, which is "intended mostly
  for web browser support and may not correctly work in other apps", decode only.**
  https://wiki.archlinux.org/title/Hardware_video_acceleration , https://wiki.debian.org/HardwareVideoAcceleration
- `cros-codecs` maintenance: **0.0.6, last released 2025-06-18** (https://crates.io/api/v1/crates/cros-codecs).
  Still 0.0.x after three years; it is Google/ChromeOS-internal-first ("developed for use in ChromeOS,
  particularly crosvm"). Usable as a reference for bitstream parsing; not a product dependency.

**"Is there a Linux route with NO system GStreamer?"** Practically: **FFmpeg (vendored/statically built) is the
only self-contained one**, unless kaya writes its own demuxer + bitstream parsers and drives libva/V4L2 itself
(the cros-codecs shape) — which is the largest engineering item in this whole document and still leaves the
NVIDIA-proprietary hole above. The pure-Rust alternatives (rav1d for AV1, dav1d-rs, openh264-rs) are
self-contained but do not cover the codecs the user's footage is in (see §C).

## A4. Windows — Media Foundation IMFSourceReader

Microsoft's own description of the Source Reader is exactly the level kaya needs:

> "The Source Reader is an alternative to using the Media Session and the Microsoft Media Foundation pipeline to
> process media data. … **If the media source delivers compressed data, you can use the source reader to decode
> the data.** In that case, the source reader will load the correct decoder and manage the data flow between the
> media source and the decoder. The source reader can also perform some limited video processing: color
> conversion from YUV to RGB-32, and software deinterlacing, although these operations are not recommended for
> real-time video rendering. … The source reader does not send the data to a destination; it is up to the
> application to consume the data."

https://learn.microsoft.com/en-us/windows/win32/medfound/source-reader
The doc's own "consider using the source reader when: you want to get data from a media file without worrying
about the underlying file structure … you already have a media pipeline that is not based on Media Foundation
and you want to incorporate the Media Foundation media sources into your own pipeline" is a description of kaya.

**`MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING`** — "Enables advanced video processing by the Source
Reader, including color space conversion, deinterlacing, video resizing, and frame-rate conversion." It inserts
a video processor MFT so `SetCurrentMediaType` can request e.g. RGB32 at a given size; the doc says over the
plain `..._ENABLE_VIDEO_PROCESSING` attribute it supports a greater range of conversions and "some conversions
can be performed in hardware using the GPU." Minimum client **Windows 8**.
https://learn.microsoft.com/en-us/windows/win32/medfound/mf-source-reader-enable-advanced-video-processing
This is the attribute that gets kaya a CPU-friendly RGB32 frame without writing a YUV converter.

**Hardware decode** — set `MF_SOURCE_READER_D3D_MANAGER` to an `IMFDXGIDeviceManager` (or the legacy
`IDirect3DDeviceManager9`): "Use this attribute to provide a Direct3D device for any video decoders loaded by
the source reader. If you set this attribute and the decoder supports Microsoft DirectX Video Acceleration
(DXVA), the source reader uses the Direct3D device to allocate video buffers."  Minimum client Windows 7.
https://learn.microsoft.com/en-us/windows/win32/medfound/mf-source-reader-d3d-manager
Note the doc explicitly says not to set it if you only want compressed video out — and, importantly, that the
buffers you get are then DXVA/D3D surfaces, so the CPU read-back is on you.

**Codec availability is NOT unconditional on Windows.** Windows ships an H.264 decoder, but **HEVC/H.265 is not
in the box** — it requires a Microsoft Store extension: the paid "HEVC Video Extensions" (~$0.99) or the free
"HEVC Video Extensions from Device Manufacturer" (OEM-provisioned, not freely installable by everyone). AV1
likewise needs the "AV1 Video Extension". See Microsoft's Store listing and the community write-up:
https://apps.microsoft.com/detail/9nmzlz57r3t7 (HEVC Video Extensions),
https://windowsforum.com/threads/hevc-h-265-support-in-windows-11-how-to-get-free-or-paid-codec-support.373773/
**This is a real argument for owning decode**: on Windows, the platform route cannot open an iPhone's default
recording (HEVC) on a machine that lacks the extension, and kaya cannot make the user buy a Store package.

**Rust access.** `windows` crate 0.62.2 (2025-10-06, 312M downloads, https://crates.io/api/v1/crates/windows)
generates the whole Win32 metadata surface, and Media Foundation is fully covered:
`windows::Win32::Media::MediaFoundation::IMFSourceReader` and every sibling interface exist in the generated
bindings — https://microsoft.github.io/windows-docs-rs/doc/windows/Win32/Media/MediaFoundation/struct.IMFSourceReader.html
The one rough edge on record is implementing MF *callback* interfaces from Rust (async `IMFAsyncCallback`):
https://github.com/microsoft/windows-rs/issues/1378 — avoidable if kaya uses the Source Reader synchronously,
which is the natural shape for "decode this file as fast as possible".

## A5. Engineering size of "four decoder backends behind one trait"

The honest way to size this is to measure a project that has already done exactly it. **Firefox's
PlatformDecoderModule is the closest analogue**: one `PlatformDecoderModule` interface, a `PDMFactory` that
picks among per-platform implementations. Byte counts read from the GitHub mirror on 2026-09-02
(https://api.github.com/repos/mozilla-firefox/firefox/contents/dom/media/platforms):

| directory | files | bytes |
|---|---|---|
| `dom/media/platforms/` (the trait, factory, allocation policy, codec-support table) | 20 | ~194 KB |
| `dom/media/platforms/apple/` (AppleVTDecoder, AppleATDecoder, AppleVTEncoder) | 12 | **153,729** |
| `dom/media/platforms/wmf/` (DXVA2Manager, WMFVideoMFTManager, MFMediaEngine…) | 52 | **560,871** |
| `dom/media/platforms/android/` (AndroidDecoderModule, RemoteDataDecoder) | 9 | **92,759** |
| `dom/media/platforms/ffmpeg/` (top level only; plus 11 per-version subdirs) | 36 | **461,690** |

Take the decode-only slice and drop the encoder files, and the *per-backend* cost still lands around
**60–250 KB of C++ each, i.e. roughly 2k–8k lines per platform**, with a shared trait + factory layer of
another ~5k lines. Note two things this table shows plainly:
1. **Windows is the expensive one** (560 KB) — DXVA2 device management alone is 54 KB, and Media Foundation's
   surface is large enough that Mozilla eventually added a *second* Windows backend (MFMediaEngine) beside the
   first.
2. **The single-library backend is not cheap either** — Firefox's FFmpeg PDM is 461 KB and carries *eleven*
   per-libavcodec-version shims (ffmpeg57 … ffmpeg63, ffvpx, libav53-55) because it dlopen's whatever the
   distro has. A *vendored, version-pinned* FFmpeg avoids exactly that tax.

Chromium's split is the same shape one size up: `media/filters` holds "software decoding implementations …
backed by FFmpeg and libvpx" and `media/gpu` holds "the platform hardware encoder and decoder implementations"
for "android, chromeos, mac, and windows, as well as v4l2 and vaapi".
https://chromium.googlesource.com/chromium/src/+/HEAD/media/README.md ,
https://chromium.googlesource.com/chromium/src/+/HEAD/media/gpu/README.md

**The counter-example worth weighing:** *Servo* — a from-scratch Rust browser engine with the same
five-platform ambition kaya has — did **not** build four backends. servo-media defines a `Backend` trait and
"currently, the only functional backend is GStreamer", on every platform.
https://github.com/servo/media , https://servo.org/blog/2019/07/09/media-update-h1-2019/
A project of Servo's size, with Igalia's multimedia team on it, chose one cross-platform media library over
four native ones. That is the single most relevant precedent for kaya.

**Estimate for kaya.** Four decoder backends behind one trait, decode-only, no encode, no DRM, no seeking
subtleties beyond keyframe seek: **on the order of 8k–15k lines of Rust + unsafe FFI**, spread over four
platform-specific unsafe surfaces that kaya's existing five-lane matrix would have to grow legs for. And the
long tail is not the happy path — it is per-device MediaCodec colour formats, Windows machines with no HEVC
extension, VideoToolbox format-description construction from a raw stream, and every combination of
"which of the four is red today". Compare: the whole of kaya's current backend layer is four *UI* backends;
this adds a fifth axis of platform divergence to a project whose core discipline is uniform semantics.

---

# B. FFMPEG LINKED INTO THE CORE

## B6. Licensing, precisely

**FFmpeg's own legal page** (https://www.ffmpeg.org/legal.html) states it plainly:

> "FFmpeg is licensed under the GNU Lesser General Public License (LGPL) version 2.1 or later. However, FFmpeg
> incorporates several optional parts and optimizations that are covered by the GNU General Public License (GPL)
> version 2 or later. **If those parts get used the GPL applies to all of FFmpeg.**"

Its compliance checklist begins with "compile FFmpeg without `--enable-gpl` and without `--enable-nonfree`",
then: distribute FFmpeg's source with your binaries, **use dynamic linking**, credit FFmpeg on download pages
and in the about box, state LGPL 2.1 in the EULA, and state that you do not own FFmpeg's code.
`--enable-nonfree` produces a build that is **not redistributable at all** (it lets GPL-incompatible non-free
code, e.g. the Fraunhofer FDK AAC, be linked in).

On patents the same page is deliberately unhelpful, and this is worth quoting to Akhil verbatim because it is
FFmpeg's *own* position: "We do not know, we are not lawyers so we are not qualified to answer this", followed
by a warning that standards like H.264 and MPEG-4 carry patent notices and that commercial users should expect
"the owners of the patents will come after their licensing fees."

**What a STATIC link into a proprietary app requires — LGPL 2.1 §6, verbatim**
(https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt):

> "As an exception to the Sections above, you may also combine or link a 'work that uses the Library' with the
> Library to produce a work containing portions of the Library, and distribute that work under terms of your
> choice, **provided that the terms permit modification of the work for the customer's own use and reverse
> engineering for debugging such modifications.**"

and then you must do one of:

> **a)** "Accompany the work with the complete corresponding machine-readable source code for the Library
> including whatever changes were used in the work …; and, if the work is an executable linked with the Library,
> **with the complete machine-readable 'work that uses the Library', as object code and/or source code, so that
> the user can modify the Library and then relink to produce a modified executable containing the modified
> Library.**"
>
> **b)** "Use a suitable shared library mechanism for linking with the Library. A suitable mechanism is one that
> (1) uses at run time a copy of the library already present on the user's computer system, rather than copying
> library functions into the executable, and (2) will operate properly with a modified version of the library,
> if the user installs one …"

So: **dynamic link (6b) is the easy road; static link (6a) obliges you to ship your own application's object
files** (or source) plus a way to relink. That is a real, if unglamorous, deliverable — a tarball of `.o` files
and a link script — and it is what "provide object files" means in practice.

**What real apps do.** Overwhelmingly (b): ship `libavcodec.so`/`.dll`/`.dylib` beside the app and dlopen or
link dynamically. Firefox goes further and **dlopen's the system FFmpeg at runtime** rather than shipping one —
`FFmpegRuntimeLinker.cpp` plus eleven per-version shims
(https://api.github.com/repos/mozilla-firefox/firefox/contents/dom/media/platforms/ffmpeg) — which sidesteps
both the LGPL obligation and the patent exposure by never distributing a codec at all. The static-link +
object-files route (6a) is documented as legally workable but is described in practitioner discussions as
"highly impractical" on locked-down platforms; see the two camps ("provide object files" vs "provide source")
laid out at https://roadfiresoftware.com/2013/08/the-problem-with-using-lgpl-v2-1-code-in-an-ios-app/ and the
LWN thread https://lwn.net/Articles/526355/ (2012-11-22).

## B7. The app-store question

**iOS / Apple.** This is where the LGPL story gets bad, and the reason is structural, not FFmpeg-specific.
- **iOS has no user-installable shared libraries**, so LGPL §6(b) is unavailable and you are forced onto §6(a):
  ship object files so the user can relink. But an App Store binary is code-signed and DRM'd; a user cannot
  install the relinked result on their own device without a developer account. The practitioner consensus is
  that you must offer the relinkable object files **outside** the App Store, and that even then the "operate
  properly with a modified version" spirit is not honoured.
  https://roadfiresoftware.com/2013/08/the-problem-with-using-lgpl-v2-1-code-in-an-ios-app/
- The LWN discussion reaches the sharper conclusion, quoting Bradley Kuhn after studying app-store terms:
  the stores' terms "neither permit LGPL-covered applications any more easily than GPL-covered ones", i.e.
  **LGPL buys you less on iOS than people assume.** https://lwn.net/Articles/526355/
- **The VLC history.** VLC for iOS was pulled from the App Store in January 2011 after developer Rémi
  Denis-Courmont filed a GPL infringement notice: the App Store's DRM and usage rules conflict with the GPL's
  requirement that recipients may freely copy and redistribute.
  https://www.fsf.org/blogs/licensing/vlc-enforcement
  VideoLAN then **relicensed the VLC *engine* (libVLC and libVLCcore) from GPLv2 to LGPLv2.1-or-later**,
  announced 2011-12-21 — "to match the evolution of the video industry and to spread the VLC engine as a
  multi-platform open-source multimedia engine and library." Note the press release's own FAQ was *not*
  confident this fixed the store problem: "Will this license change allow VLC to be available on the Apple
  stores? So far, we don't know if this will change anything."
  https://www.videolan.org/press/lgpl-libvlc.html
  VLC for iOS is on the App Store today — but as **GPLv2+/MPLv2 software published by VideoLAN itself**
  (https://apps.apple.com/us/app/vlc-media-player/id650377962 ,
  https://github.com/videolan/vlc-ios), i.e. the copyright holder distributing its own code. That is a
  permission *kaya does not have* for FFmpeg. The lesson to draw is the opposite of the popular one: VLC is on
  the store because VideoLAN owns VLC, not because LGPL solved anything.
- **Practical reading for kaya:** statically linking LGPL FFmpeg into an iOS app and shipping it through the
  App Store is what a large number of apps actually do, and it is *not* clean under §6(a) unless kaya also
  publishes relinkable object files. Dynamic linking on iOS is possible now (embedded `.framework` /
  `.xcframework` inside the app bundle) but does not satisfy 6(b)(1)'s "a copy of the library already present on
  the user's computer system"; it does arguably satisfy the *relink* spirit better than a static archive.

**Google Play.** Play's Developer Program Policy does not ban GPL/LGPL, and GPL apps are published there
routinely. The practical hole is the same as iOS's: an APK is signed, so a user cannot drop in a modified
`.so` and have the app run, which defeats §6(b)(2). See the write-up at https://xebia.com/blog/the-lgpl-on-android/
Shipping FFmpeg as a `.so` inside the APK is the normal industry practice (this is exactly what
ffmpeg-kit/mobile-ffmpeg do, and they are published on Maven Central under LGPL v3 / GPL v3 variants:
https://github.com/tanersener/mobile-ffmpeg/wiki/License-LGPL-v3.0).

**Microsoft Store.** The historical restriction people remember is the 2011 *Windows Phone* Marketplace
agreement banning GPLv3/AGPLv3/LGPLv3 (https://www.theregister.com/2011/02/17/microsoft_bans_opensource_windows_phone/).
The modern Microsoft Store's live controversy was different — a June 2022 policy (10.8.7) that would have
banned *selling* open-source software, which Microsoft reversed on 2022-07-19 after backlash:
https://www.theregister.com/2022/07/19/microsoft_store_policy/ ,
https://techcrunch.com/2022/07/19/microsoft-u-turns-on-policy-that-wouldve-banned-commercial-open-source-apps/
Windows is also the platform where LGPL §6(b) is genuinely easy: ship `avcodec-*.dll` next to the exe. Windows
is not the app-store problem; **iOS is, and Android is a milder version of it.**

## B8. Binary size

I could not find a *published, measured* size table for "FFmpeg built with only H.264+AAC decode" per platform —
the ffmpeg-kit wiki page that people cite for this teaches the technique (`--disable-everything` then
`--enable-decoder=…`) but publishes **no numbers at all**
(https://github.com/arthenica/ffmpeg-kit/wiki/How-to-Decrease-Binary-Size). Rather than repeat a folk figure,
here are the real measurements I could anchor:

**Full build, shared libraries, Debian trixie** (https://packages.debian.org/trixie/libavcodec61 ,
/libavformat61 , /libavutil59) — this is the *upper* bound, a distro build with everything on:

| package | amd64 download / installed | arm64 download / installed |
|---|---|---|
| libavcodec61 | 5,684.8 kB / **16,613 kB** | 5,268.5 kB / **14,200 kB** |
| libavformat61 | 1,175.1 kB / 3,047 kB | 1,113.6 kB / 3,120 kB |
| libavutil59 | 415.0 kB / 1,252 kB | 382.8 kB / 1,091 kB |
| **core three, installed** | **~20.9 MB** | **~18.4 MB** |

**Prebuilt iOS xcframeworks** (kewlbear/FFmpeg-iOS release assets, measured from the GitHub API on 2026-09-02,
https://api.github.com/repos/kewlbear/FFmpeg-iOS/releases): `avcodec.zip` **22,066,489 bytes**,
`avformat.zip` 4,860,891, `avutil.zip` 1,551,814, `swscale.zip` 957,946, `swresample.zip` 197,441 — i.e. a
compressed multi-slice avcodec alone is ~22 MB. Again, everything-on.

**Minimal build, lower bound.** The best measured minimal figure I found is a whole *`ffmpeg` executable*
"less than 2.5 MB" from a `--disable-everything`-style build with `--enable-small`, RTMP/H.264 scope, at
https://gist.github.com/gyk/49dc80c58691a21a1c5f5e16926beaa6 — that includes the CLI tool, so the libraries are
smaller still. **A reasonable planning number for H.264+AAC decode only, per architecture, is 2–4 MB**, against
~15–20 MB for a full build, and this must be multiplied by architecture on every platform that ships fat
binaries (iOS device+simulator, Android's four ABIs, macOS universal).

For kaya's likely scope (H.264 + HEVC decode, MP4/MOV demux, AAC decode, no encoders, no filters, no protocols
beyond `file`), expect the low end of that band — but note that **HEVC's decoder is itself large**, and that
enabling the assembly optimisations (which you must, for a video editor) is where most of the bytes are.

## B9. Hardware decode through FFmpeg — and the catch

FFmpeg's `-hwaccel` list, per the manual (https://ffmpeg.org/ffmpeg.html): `none`, `auto`, `vdpau`, `dxva2`,
`d3d11va`, `vaapi`, `qsv`, `videotoolbox`; `mediacodec`, `vulkan`, `d3d12va`, `cuda`/`nvdec` and `amf` appear
in the fuller manual (https://ffmpeg.org/ffmpeg-all.html) and in `libavutil/hwcontext.c`
(https://github.com/FFmpeg/FFmpeg/blob/master/libavutil/hwcontext.c). Mapped to kaya's five lanes:
macOS/iOS → `videotoolbox`, Android → `mediacodec`, Linux → `vaapi` (or `vdpau`, or `vulkan`),
Windows → `d3d11va`/`dxva2` (`d3d12va` on newer).

**The catch, in FFmpeg's own words:**

> "Note that most acceleration methods are intended for playback and **will not be faster than software decoding
> on modern CPUs**. Additionally, ffmpeg will usually need to **copy the decoded frames from the GPU memory into
> the system memory, resulting in further performance loss.**"
> — https://ffmpeg.org/ffmpeg.html, `-hwaccel` documentation

The mechanism behind that sentence is `AVHWFramesContext`: a hwaccel decoder hands you an `AVFrame` whose
`data[]` are opaque platform handles (a `CVPixelBuffer`, an `AHardwareBuffer`/`ANativeWindow` slot, a
`VASurfaceID`, an `ID3D11Texture2D`), living in a GPU frame pool. To get pixels you call
`av_hwframe_transfer_data()`, which is a device→host copy; `-hwaccel_output_format` lets you *keep* the frame on
the device instead, but only helps if the next stage can consume a device surface.
https://ffmpeg.org/doxygen/trunk/hwcontext_8c.html , https://www.ffmpeg.org/doxygen/3.4/hwcontext_8h.html

**Why this bites kaya specifically.** kaya's whole architecture is "kaya rasterizes, backends blit" — the core
owns CPU pixels and hands bytes down. A hardware-decoded frame is exactly the thing that architecture cannot
consume without a readback, and a readback per frame at 4K is the cost hardware decode was supposed to save.
So kaya gets one of two shapes, and should pick deliberately:
- **CPU frames everywhere** (software decode, or hwaccel + `av_hwframe_transfer_data`): fits kaya's canvas
  model exactly, costs CPU, and is honest about it.
- **Device surfaces handed to each backend**: fast, but reintroduces per-backend divergence *in the pixel
  path*, which is the one place kaya has so far kept uniform (check-canvas-blit's whole point).

## B10. Rust bindings in 2026

**`ffmpeg-next`** (zmwangx/rust-ffmpeg) — **9.0.0, released 2026-08-05**, 6,766,861 downloads. Latest commits
2026-08-05 / 2026-07-21. Its README says the crate "is currently in maintenance mode, and aims to be compatible
with all of FFmpeg's versions from 3.4 (currently from 3.4 til 8.0)". Licensed **WTFPL**.
https://github.com/zmwangx/rust-ffmpeg , https://crates.io/api/v1/crates/ffmpeg-next ,
https://api.github.com/repos/zmwangx/rust-ffmpeg/commits
Its sys crate **`ffmpeg-sys-next` 9.0.0 (2026-08-05)**, 7,087,355 downloads,
https://github.com/zmwangx/rust-ffmpeg-sys — 74 cargo features. The build story is in those features:
- default: link against a **system** FFmpeg found by pkg-config (avcodec/avdevice/avfilter/avformat/swresample/
  swscale on by default);
- `static` — link statically;
- `build` — **vendored: download and compile FFmpeg from source** as part of the cargo build (requires `static`),
  with `build-pic`, `build-portable`, and per-library switches `build-lib-x264`, `build-lib-x265`,
  `build-lib-dav1d`, `build-lib-vpx`, `build-lib-opus`, …;
- **licence switches are explicit cargo features**: `build-license-gpl`, `build-license-nonfree`,
  `build-license-version3` — i.e. the LGPL/GPL/nonfree decision is a line in `Cargo.toml`, which is a *good*
  property for a project that has to keep it LGPL;
- hardware: `build-videotoolbox`, `build-mediacodec`, `build-vaapi`, `build-nvenc`, `build-nvidia`, `build-amf`,
  `build-drm`, `build-vulkan`.
  Feature list: https://docs.rs/crate/ffmpeg-sys-next/latest/features
For reference, current FFmpeg upstream is **9.0.1 "Lei" (2026-08-12)**, with 8.1.2, 8.0.3, 7.1.5 also
maintained — https://ffmpeg.org/download.html

**`rsmpeg`** (larksuite) — **0.18.0+ffmpeg.8.0, released 2025-08-24**, 168,571 downloads, MIT.
https://github.com/larksuite/rsmpeg , https://crates.io/api/v1/crates/rsmpeg
Links via `rusty_ffmpeg`, with `link_system_ffmpeg` / `link_vcpkg_ffmpeg` features and environment variables
(`FFMPEG_PKG_CONFIG_PATH`, `FFMPEG_LIBS_DIR`, `FFMPEG_INCLUDE_DIR`) for a hand-built FFmpeg — which is the
shape you want for cross-compiling, because you build FFmpeg for the target yourself and point the crate at it.
The version suffix in the crate version (`+ffmpeg.8.0`) is the whole maintenance story: **rsmpeg pins a
specific FFmpeg major**, where ffmpeg-next does compile-time version detection across a range. rsmpeg is a year
behind ffmpeg-next as of 2026-09 (no FFmpeg 9 release).

**Cross-compilation reality for iOS/Android.** Neither crate does it for you. The practical route both use is:
build FFmpeg for the target with an NDK/Xcode toolchain (or take a prebuilt), then point the sys crate at the
headers and libs. Prebuilt sets exist — https://github.com/kewlbear/FFmpeg-iOS (Swift package of xcframeworks),
https://github.com/arthenica/ffmpeg-kit (Android AAR + iOS xcframework; **note: ffmpeg-kit was retired by its
author in 2025 and its binaries pulled from the CDNs**), and Qt documents its own from-source recipe for both:
https://doc.qt.io/qt-6/qtmultimedia-building-ffmpeg-android-windows.html ,
https://doc.qt.io/qt-6/qtmultimedia-building-ffmpeg-ios.html
Expect this to be a real build-system project inside kaya's flake, not a cargo feature flip.

**`ffmpeg-sidecar`** (spawn the `ffmpeg` binary and parse its output) — **2.5.2, released 2026-05-30**,
1,747,381 downloads, https://github.com/nathanbabcock/ffmpeg-sidecar , https://crates.io/api/v1/crates/ffmpeg-sidecar
The crate wraps a standalone FFmpeg binary "in an intuitive Iterator interface" and can auto-download a build.
The tradeoff is different in kind, and mostly favourable on licensing: **an unmodified FFmpeg executable invoked
as a separate process is not linking**, so LGPL §6 does not attach to kaya at all — you are a user of a program,
not a distributor of a library, *provided you do not ship the binary*. Ship it and you are distributing FFmpeg
again (still LGPL-clean if unmodified and source-offered, but now inside your app bundle, which reopens the iOS
question). The engineering cost is: process-per-decode, pixel data over a pipe, no seek without re-spawn, and
**it is a non-starter on iOS and Android**, which do not let an app fork-exec an arbitrary binary. Real GUI apps
do ship FFmpeg as a subprocess on desktop — that is the classic Handbrake/Shotcut/Kdenlive-adjacent pattern and
what ffmpeg-sidecar's 1.7M downloads represent — but no five-platform GUI toolkit can rely on it.

**One more current-state fact for B10:** the standard prebuilt-FFmpeg-for-mobile project, **`ffmpeg-kit`, was
retired on 2026-07-02** ("Development of FFmpegKit continues with FFmpegKitNext, maintained by its original
author"); historical releases remain in the repo and community forks are on Maven Central / pub.dev / npm.
https://github.com/arthenica/ffmpeg-kit
If kaya depends on prebuilt mobile FFmpeg, this is the supply chain it depends on — one maintainer, retired
once already.

---

# C. PURE-RUST / PATENT-FREE DECODERS

## C11. rav1d (and dav1d-rs)

**rav1d** — the Rust port of dav1d, by ISRG's Prossimo. https://github.com/memorysafety/rav1d
- crates.io: **1.1.0, released 2025-05-07**, only 32,940 downloads, BSD-2-Clause.
  https://crates.io/api/v1/crates/rav1d — 1.1.0 "synchronizes rav1d code with the latest version of dav1d,
  v1.5.1" (https://www.memorysafety.org/initiative/av1/).
- Repository is alive but slow: 641 stars, most recent commits **2026-08-14** ("Harden apt setup",
  "obu: construct optional refidx with bool::then_some"). https://api.github.com/repos/memorysafety/rav1d/commits
- **Functional completeness is real.** Prossimo, 2025-05-14: "By September of 2024 rav1d was basically
  complete", it "passes all the same tests as the dav1d decoder it is based on", and "it's possible to build and
  run Chromium with it." https://www.memorysafety.org/blog/rav1d-perf-bounty/
- **Performance is the open item and has not closed.** The same post: rav1d is "currently about 5% slower than
  the C-based dav1d decoder (the exact amount differs a bit depending on the benchmark, input, and platform)",
  down from ~11% overhead earlier (https://www.memorysafety.org/blog/rav1d-performance-optimization/, 2024-09-10).
  A **$20,000 bounty** for parity was posted 2025-05-14 and **concluded on 2025-12-31**
  (https://www.memorysafety.org/rav1d-bounty-official-rules/) with no parity announcement on the initiative page.
- **Shape:** "librav1d is designed to be a drop-in replacement for libdav1d, so it primarily exposes a **C API**
  with the same usage as libdav1d's. A Rust API is mentioned as planned but not yet implemented." So even the
  pure-Rust AV1 decoder is consumed through a C ABI today.
- **Verdict:** production-*capable* for AV1 (Chromium builds and runs with it), ~5% slower than the C reference,
  pre-1.x cadence on crates.io. Fine as a component; not a reason to build a decode stack around it.

**dav1d-rs** (`dav1d` crate) — bindings to the C libdav1d. **0.11.1, released 2025-11-25**, 1,238,301 downloads,
https://github.com/rust-av/dav1d-rs , https://crates.io/api/v1/crates/dav1d
Uses `system-deps` to find a **system** libdav1d (overridable via `PKG_CONFIG_PATH` /
`SYSTEM_DEPS_DAV1D_*`), no vendoring; README says "The bindings require dav1d>=1.3.0 (Might not work for
>1.5.0)" — a narrow version window, i.e. it does not insulate you from the C library's release cadence.

## C12. What a patent-free-only path leaves out

**H.264 (AVC).** Licensed through **Via LA** (the merged MPEG LA / Via Licensing pool).
https://www.via-la.com/licensing-programs/avc-h-264/ — an "AVC Product" explicitly includes "media player and
other personal computer software" and "mobile devices". The PC-software rate card:
- units 1–100,000 per year: **$0.00** (available to one legal entity in an affiliated group)
- units 100,001–5,000,000: **$0.20/unit**
- units 5,000,001+: **$0.10/unit**
- annual enterprise cap: **$9.75M** from 2017 onward.
So a small app is *below the threshold* and a large one is not. The threshold is a real answer for a project at
kaya's stage and a real liability at scale. Note also the 2025 reporting that Via LA has been raising AVC
streaming-side fees sharply (https://www.tomshardware.com/service-providers/streaming/h264-streaming-license-fees-jump-from-100000-to-4-5-million).

**HEVC (H.265).** Worse: **three** pools plus unpooled holders. Access Advance's HEVC Advance pool covers
"over 27,000 patents"; Via LA runs a separate HEVC program (https://www.via-la.com/licensing-programs/hevc-vvc/);
Access Advance announced on **2025-07-21** that from **2026-01-01** HEVC rates realign to the VVC rate structure
with an approved **25% rate increase for new licensees**, current rates lockable through 2030 only if you signed
by 2025-12-31. https://accessadvance.com/2025/07/21/access-advance-announces-hevc-advance-and-vvc-advance-pricing-through-2030/
There is no equivalent to Via LA's free-first-100k tier stated publicly for a software decoder.

**FFmpeg's own position**, again, because it is the most honest sentence anyone writes on this: "We do not know,
we are not lawyers so we are not qualified to answer this" — and the warning that patent holders "will come
after their licensing fees." https://www.ffmpeg.org/legal.html

**The OpenH264 (Cisco) loophole — how it actually works, and why it does not help kaya.**
Cisco's binary licence text (https://www.openh264.org/BINARY_LICENSE.txt) grants Cisco's own AVC/H.264 Patent
Portfolio Licence from MPEG LA at no cost to you **only if**:
1. "the Cisco-provided binary is **separately downloaded to an end user's device, and not integrated into or
   combined with third party software prior to being downloaded** to the end user's device"; and
2. "the end user must have the ability to control (e.g., to enable, disable, or re-enable) the use of the
   Cisco-provided binary"; plus attribution ("OpenH264 Video Codec provided by Cisco Systems, Inc.") reproduced
   in the EULA.
Cisco's FAQ (https://www.openh264.org/faq.html) confirms the split: **"Cisco is only covering the licensing fees
for its own binary module"** — build from source and "you must pay all applicable license fees" yourself. The
FAQ also notes the mechanism works on Linux/Windows/macOS/Android but **not iOS**, because Apple's distribution
rules do not permit downloading an executable module at install time.

Consequences for kaya:
- The **`openh264` Rust crate's default `source` feature compiles Cisco's C from source via `cc`** — which is
  precisely the case Cisco does *not* cover. Its `libloading` feature is the one that matches the loophole
  (load Cisco's own prebuilt at runtime), and it requires you to fetch that binary at run time.
  https://github.com/ralfbiedert/openh264-rs (crate: 0.9.8, released **2026-08-08**, 890,766 downloads,
  https://crates.io/api/v1/crates/openh264)
- Even done correctly, the loophole is a **runtime download of a separate module the user can disable** — a
  shape a GUI toolkit cannot impose on its embedders, and one that is unavailable on iOS entirely.
- **The crate's own README is worth quoting to Akhil**: "Below a thin Rust layer we rely on a *very complex* C
  library … this project will give you *no* additional safety guarantees as far as video handling is concerned."

## C13. Pure-Rust decoders that actually exist (honest maturity)

| codec | crate | state (observed 2026-09-02) |
|---|---|---|
| **AV1** | `rav1d` | **The only credible one.** Complete, passes dav1d's test suite, runs in Chromium, ~5% slower. crates.io 1.1.0 (2025-05-07); commits to 2026-08-14. https://crates.io/api/v1/crates/rav1d |
| **AV1 (C)** | `dav1d` bindings | Mature C library, thin Rust bindings, 0.11.1 (2025-11-25). Not pure Rust. |
| **VP8/VP9** | — | **Nothing credible.** The only Rust route is FFI to libvpx: `vpx-sys` 0.1.1, **last released 2021-03-01**, 4,768 lifetime downloads. https://crates.io/api/v1/crates/vpx-sys — effectively abandoned. |
| **H.264** | `openh264` | FFI to Cisco's C. 0.9.8 (2026-08-08), 890k downloads. Mature *as a binding*; patent-encumbered as above. |
| **H.264 (pure Rust)** | `rusty_h264` | **New and unproven.** First published **2026-06-27**, at 0.14.0 by **2026-09-03** — fifteen releases in ten weeks. 16,915 downloads, **6 GitHub stars, 1 fork.** README claims "35 of openh264's conformance streams decode byte-for-byte identical", `#![forbid(unsafe_code)]` in the core, and decode throughput of **150 Mpx/s baseline / 107 Mpx/s CABAC vs ffmpeg's 314 / 289** — i.e. by its own numbers **roughly 2–3× slower than FFmpeg**. https://github.com/remade-with-rust/rusty_h264 , https://crates.io/api/v1/crates/rusty_h264 |
| **H.264 (pure Rust)** | `rust_h264` | Also new: 0.1.0 on **2026-04-05**, 0.4.0 on **2026-04-20**, then nothing. 25,052 downloads. https://crates.io/api/v1/crates/rust_h264 |
| **H.264 (pure Rust)** | `oxideav-h264` | Currently an **empty crate** under "spec-driven rewrite". https://github.com/OxideAV/oxideav-h264 |
| **HEVC (pure Rust)** | — | Nothing. |

**Honest read:** the pure-Rust story is *AV1 only*. The two 2026 pure-Rust H.264 decoders are months old, single-
digit-star, single-maintainer projects with rapid pre-1.0 churn; one publishes benchmarks showing itself 2–3×
slower than FFmpeg, and neither has a track record on malformed input — which for a decoder is the entire risk
surface. **And writing a pure-Rust decoder does not touch the patent question at all**: patents cover the
algorithm, not the implementation language. A clean-room Rust H.264 decoder has exactly the same Via LA exposure
as FFmpeg's, minus FFmpeg's twenty years of fuzzing.

## C14. What the user's own footage actually is

This is the decisive constraint for a video editor and it argues against every patent-free-only path.

**iPhone.** Since iOS 11 the default capture format is **HEVC** (the Camera → Formats → "High Efficiency"
setting); "Most Compatible" switches to H.264/JPEG. Apple: HEIF/HEVC capture "is recommended"; the Most
Compatible option exists to "use JPEG or H.264 format" for "more broadly compatible" output. HEVC capture is
supported on iPhone 7 and later, iPad (6th gen) and later, and Apple Vision Pro; on macOS Tahoe 26+, **screen
recordings in HDR are captured as HEVC** too. https://support.apple.com/en-us/116944
Higher tiers add **ProRes** (iPhone 13 Pro and later), which is another decoder entirely:
https://support.apple.com/en-us/109041

**Android.** Android *requires* device support for decoding **H.264 AVC Baseline (Android 3.0+), HEVC
(Android 5.0+), VP8, VP9 (4.4+)**, and **AV1 decode+encode became mandatory in Android 14**.
https://developer.android.com/guide/topics/media/media-formats
Capture default is OEM-dependent: HEVC became the default on many OEMs from Android 12
(https://www.xda-developers.com/oems-change-default-video-capture-format-android-12-hevc/), and Samsung,
Pixel and OnePlus all expose an HEVC/H.264 toggle in the camera. Samsung's Galaxy S26 Ultra adds a *third*
format, **APV**, published as **RFC 9924** in February 2026 — a new professional capture codec kaya would not
decode at all. https://smartphones.gadgethacks.com/news/samsung-galaxy-s26-ultra-apv-video-codec-explained-for-editors/

**Conclusion:** the practical floor for a video editor is **H.264 and HEVC in MP4/MOV**, and both are
patent-encumbered. An AV1-only, patent-free-only path **cannot open the user's own camera roll** — not on
iPhone (HEVC by default), not on a modern Android flagship (HEVC by default), not a QuickTime screen recording.
AV1 is what the *web* delivers, not what the *camera* writes.

---

# SYNTHESIS FOR THE RULING

## The three routes, side by side

| | four platform decoders behind one trait | FFmpeg linked into the core | pure-Rust / patent-free only |
|---|---|---|---|
| **codec coverage** | whatever the OS has. H.264 everywhere; HEVC everywhere **except Windows without the Store extension**; AV1 mandatory on Android 14+, needs an extension on Windows, fine on Apple hardware | everything, decided at configure time | **AV1 only.** Cannot open an iPhone or a modern Android camera roll |
| **engineering** | ~8k–15k lines of unsafe FFI across 4 platform surfaces; Firefox's analogue is 150 KB (Apple) / 561 KB (Windows) / 93 KB (Android) of C++ | one dependency + a real cross-compile build project for iOS/Android | one crate, ~5% slower than dav1d |
| **licensing** | **clean.** No codec distributed; the OS's licence covers it | LGPL 2.1: dynamic link is easy on Windows/Linux/macOS; **static link on iOS obliges §6(a) object files** | BSD-2 clean, patents untouched |
| **patents** | **the OS holder pays.** This is the single biggest argument for this route | kaya distributes an H.264/HEVC decoder → Via LA / Access Advance exposure (free below 100k units/yr for AVC PC software) | AV1 is royalty-free by design |
| **binary size** | ~0 | ~2–4 MB minimal, ~15–20 MB full, **per architecture** | ~1–2 MB for rav1d |
| **uniformity (kaya's core invariant)** | four divergent surfaces, four divergent failure modes, four sets of lane legs | **one behaviour on five platforms** | one behaviour, one codec |
| **precedent** | Chromium, Firefox — both browser-scale projects with media teams | most desktop editors; Firefox *also* has an FFmpeg PDM and dlopen's the system one | nobody ships a patent-free-only editor |

## The finding I would put in front of Akhil first

**Servo — a from-scratch Rust engine with the same five-platform ambition — did not build four decoder backends.**
servo-media defines a `Backend` trait and, with Igalia's multimedia team on the project,
"currently, the only functional backend is GStreamer" on every platform
(https://github.com/servo/media , https://servo.org/blog/2019/07/09/media-update-h1-2019/). Meanwhile Firefox,
which *did* build four, needed 561 KB of C++ for the Windows one alone and still added a second Windows backend
beside the first.

**The second finding:** "use GStreamer on Linux instead of FFmpeg" does not escape FFmpeg. GStreamer's software
H.264 decoder `avdec_h264` is documented by GStreamer as "libav h264 decoder", shipped in the "GStreamer FFMPEG
Plug-ins" package. https://gstreamer.freedesktop.org/documentation/libav/avdec_h264.html

**The third finding, which cuts the other way and is the strongest argument for owning decode:** on Windows the
platform route **cannot open an iPhone's default recording**. Windows ships no HEVC decoder; it needs a Microsoft
Store extension the user must obtain, and kaya cannot make them. Combine that with Apple's HEVC-by-default
capture (https://support.apple.com/en-us/116944) and the platform-decoder route has a hole exactly where a video
editor's most common input lands.

**The fourth finding:** kaya's canvas architecture ("kaya rasterizes, backends blit") wants **CPU frames**, and
every hardware decode route on every platform wants to give you a **GPU surface**. FFmpeg says so itself:
"ffmpeg will usually need to copy the decoded frames from the GPU memory into the system memory, resulting in
further performance loss." (https://ffmpeg.org/ffmpeg.html) So kaya pays a readback whichever route it takes —
unless it breaks its own blit uniformity to hand device surfaces to four backends, which is the thing
`tools/check-canvas-blit.py` exists to prevent.

## What I could NOT confirm (stated rather than guessed)

1. **No published, measured size table** for a minimal `--disable-everything --enable-decoder=h264 …` FFmpeg
   build per platform. The ffmpeg-kit wiki page everyone cites has no numbers. My 2–4 MB band is bracketed by a
   measured "<2.5 MB whole ffmpeg executable" minimal build (https://gist.github.com/gyk/49dc80c58691a21a1c5f5e16926beaa6)
   and Debian's everything-on libavcodec61 at 16.6 MB installed. **This is worth measuring in kaya's own flake
   rather than inheriting from this document.**
2. **The current Microsoft Store policy text on GPLv3/LGPLv3.** The commonly cited ban is from the 2011
   *Windows Phone* Marketplace agreement; the 2022 controversy was about *selling* open source (policy 10.8.7)
   and Microsoft reversed it on 2022-07-19. I did not find a live clause in today's Store Policies naming
   LGPLv3. FFmpeg is LGPL **2.1**, so this is probably moot either way.
3. **Whether `ffmpeg-next` 9.0.0 formally supports FFmpeg 9.** Its README still says "from 3.4 til 8.0" while
   the crate version and its sys crate both jumped to 9.0.0 on 2026-08-05, the week before FFmpeg 9.0.1 shipped.
   The README is stale; verify against the wiki/build before relying on a range.
4. **Whether the rav1d $20,000 parity bounty was claimed.** The contest "concluded on December 31, 2025"
   (https://www.memorysafety.org/rav1d-bounty-official-rules/) and the initiative page carries no outcome; the
   last performance figure on the record is still ~5% slower than dav1d.
5. **Per-frame readback costs** — I found the mechanism (`av_hwframe_transfer_data`, AImageReader vs ByteBuffer)
   documented everywhere and a *number* nowhere. Also worth measuring rather than citing.

## Rust crate maintenance, one line each (all observed 2026-09-02)

- `ffmpeg-next` **9.0.0 / 2026-08-05**, 6.77M downloads, WTFPL, README says "maintenance mode" — healthy but not ambitious. https://crates.io/api/v1/crates/ffmpeg-next
- `ffmpeg-sys-next` **9.0.0 / 2026-08-05**, 7.09M downloads, 74 features incl. vendored `build` and explicit `build-license-gpl`/`-nonfree`. https://crates.io/api/v1/crates/ffmpeg-sys-next
- `rsmpeg` **0.18.0+ffmpeg.8.0 / 2025-08-24**, 169k downloads, MIT, pinned to one FFmpeg major, a year behind. https://crates.io/api/v1/crates/rsmpeg
- `ffmpeg-sidecar` **2.5.2 / 2026-05-30**, 1.75M downloads — subprocess, desktop only. https://crates.io/api/v1/crates/ffmpeg-sidecar
- `gstreamer` **0.25.3 / 2026-06-29**, 10.0M downloads — the healthiest binding here. https://crates.io/api/v1/crates/gstreamer
- `windows` **0.62.2 / 2025-10-06**, 312M downloads — Media Foundation fully covered. https://crates.io/api/v1/crates/windows
- `objc2-video-toolbox` **0.3.2 / 2025-10-04** (50k), `objc2-core-video` **0.3.2** (8.3M), `objc2-av-foundation` **0.3.2** (1.3M) — one generated family, one maintainer (madsmtm), all pre-1.0. https://github.com/madsmtm/objc2
- `ndk` **0.9.0 / 2024-04-26**, 50.9M downloads — has `media` and `hardware_buffer` modules but **no release in over two years**; expect to drive `ndk-sys`. https://crates.io/api/v1/crates/ndk
- `cros-codecs` **0.0.6 / 2025-06-18**, 2.0M downloads — Linux/VAAPI + bitstream parsers, still 0.0.x after 3 years. https://crates.io/api/v1/crates/cros-codecs
- `rav1d` **1.1.0 / 2025-05-07** (commits to 2026-08-14), 33k downloads — AV1 only, ~5% slower than dav1d, exposes a **C** API. https://crates.io/api/v1/crates/rav1d
- `dav1d` **0.11.1 / 2025-11-25**, 1.24M downloads — needs a system libdav1d in a narrow version window. https://crates.io/api/v1/crates/dav1d
- `openh264` **0.9.8 / 2026-08-08**, 891k downloads — default feature compiles Cisco's C **from source**, which is the case Cisco's royalty coverage explicitly excludes. https://crates.io/api/v1/crates/openh264
- `rusty_h264` **0.14.0 / 2026-09-03**, first published 2026-06-27, 6 stars — too new to bet on. https://crates.io/api/v1/crates/rusty_h264
- `vpx-sys` **0.1.1 / 2021-03-01**, 4,768 downloads — abandoned; there is no VP8/VP9 Rust story. https://crates.io/api/v1/crates/vpx-sys

END OF NOTES.
