# THE FRAME PATH — research notes

Research slice: the cost of CPU frame delivery, and the texture-registry pattern
frameworks use instead. Every claim carries a URL.

Status: IN PROGRESS (appended as learned).

---

## A1. The arithmetic (computed here, not cited — plain multiplication)

One 1920x1080 frame:

| format | bytes/pixel | bytes/frame | MiB/frame |
|---|---|---|---|
| RGBA8888 / BGRA8888 | 4 | 8,294,400 | 7.91 |
| NV12 / YUV420 (8-bit, 4:2:0) | 1.5 | 3,110,400 | 2.97 |

YUV 4:2:0 is 1.5 B/px because chroma is subsampled 2x2: one Y byte per pixel plus
one U and one V byte per 2x2 block = 1 + 0.5 = 1.5. So **converting to RGBA is a
2.67x data expansion before any copy happens at all.**

ONE full-frame touch (read OR write, not both) at 1080p:

| fps | RGBA one copy | NV12 one copy |
|---|---|---|
| 24 | 199 MB/s | 75 MB/s |
| 30 | 249 MB/s | 93 MB/s |
| 60 | 498 MB/s | 187 MB/s |

4K (3840x2160) RGBA is 33.2 MB/frame -> 995 MB/s at 30fps, 1.99 GB/s at 60fps for
ONE copy.

### Counting the copies a naive owned-rendering path actually makes

A "kaya rasterizes, backends blit" video path at 1080p60. Each numbered step is a
full-frame *read plus* a full-frame *write* through memory — memory-bandwidth
traffic is the sum of both sides:

| # | step | reads | writes | traffic @60fps |
|---|---|---|---|---|
| 1 | decoder writes NV12 output | — | 3.11 MB | 187 MB/s |
| 2 | YUV->RGBA color convert | 3.11 MB (NV12) | 8.29 MB (RGBA) | 685 MB/s |
| 3 | composite/blit RGBA frame into the canvas raster (tiny-skia `draw_pixmap`/`draw_image`) | 8.29 MB | 8.29 MB | 995 MB/s |
| 4 | hand the canvas pixmap to the backend (a `Vec<u8>` -> platform bitmap copy, unless the backend can borrow) | 8.29 MB | 8.29 MB | 995 MB/s |
| 5 | upload the bitmap to a GPU texture (CPU read + PCIe/UMA write) | 8.29 MB | 8.29 MB | 995 MB/s |
| 6 | GPU compositor samples the texture and writes the framebuffer | 8.29 MB | 8.29 MB | 995 MB/s |

Sum of steps 1-6 at 1080p60: **~4.85 GB/s of memory traffic** for a single video
rectangle, before the UI around it is drawn even once. (Steps 3 and 4 collapse into
one if the backend can blit straight out of kaya's pixmap with no staging copy;
step 2 disappears entirely if the frame is delivered as a GPU texture and converted
in a shader.) The same accounting at 1080p30 is ~2.4 GB/s; at 4K60 it is ~19 GB/s,
which is more than the entire bandwidth of most phone SoCs (see A2).

The minimum a texture path spends, by contrast, is steps 1 and 6 only — the decoder
writes NV12 into a buffer the GPU can sample directly, and the compositor reads it
(with the YUV->RGB conversion folded into the sampler, which is free — it is fixed
function on every modern GPU's sampler or a handful of ALU ops):
**~370 MB/s at 1080p60, a 13x reduction.**

---
## A2. How much of the machine's bandwidth is that? (published figures)

**Phone SoC — Snapdragon 8 Elite Gen 5.** Qualcomm's own product brief states the
memory spec as: "Support for LP-DDR5x memory, up to 5300MHz / Memory Density: Up to
24GB" — https://www.qualcomm.com/content/dam/qcomm-martech/dm-assets/documents/Snapdragon-8-Elite-Gen-5-product-brief.pdf
(extracted from the PDF's Memory section). Qualcomm does not print a GB/s figure;
the arithmetic from the spec is 5300 MHz DDR = 10,600 MT/s across a 64-bit bus
(4 x 16-bit channels) = **84.8 GB/s**, which is the figure third parties quote:
https://www.notebookcheck.net/Qualcomm-Snapdragon-8-Elite-Gen-5-for-Galaxy-Processor-Benchmarks-and-Specs.1271123.0.html

**Laptop — Apple silicon (Apple's own newsroom, exact sentences).**
- "M4 supports up to 32GB of unified memory and has higher memory bandwidth of 120GB/s."
- "M4 Pro supports up to 64GB of fast unified memory and 273GB/s of memory bandwidth..."
- "M4 Max supports up to 128GB of fast unified memory and up to 546GB/s of memory bandwidth..."
https://www.apple.com/newsroom/2024/10/apple-introduces-m4-pro-and-m4-max/

### The honest ratio

| machine | peak BW | naive CPU path @1080p60 (4.85 GB/s) | texture path (0.37 GB/s) |
|---|---|---|---|
| Snapdragon 8 Elite Gen 5 phone | ~84.8 GB/s | **5.7%** | 0.4% |
| MacBook Air / base M4 | 120 GB/s | **4.0%** | 0.3% |
| M4 Max | 546 GB/s | 0.9% | 0.07% |

Two caveats that make the percentage understate the problem:

1. **Peak is not achievable.** Real STREAM-style efficiency on LPDDR is well under
   100% of peak, and on a phone the GPU, the display controller, the ISP and the
   modem are all contending for the same LPDDR. A 6% peak-bandwidth figure is a
   larger fraction of *available* bandwidth.
2. **Bandwidth is power.** On a phone, DRAM traffic is one of the larger energy
   line items; a video path that moves 13x more bytes than it needs to shows up as
   battery and as thermal throttling long before it shows up as dropped frames.
3. **4K is where it stops being arguable.** The same naive path at 4K60 is
   ~19.4 GB/s — 23% of a flagship phone's entire theoretical memory bandwidth, for
   one video rectangle. At that point the CPU path is not a tradeoff, it is a wall.

---

## A3. YUV->RGB on the CPU: measured cost, and why frameworks use a shader

**libyuv** is Chromium's SIMD YUV library: "libyuv is an open source project that
includes YUV scaling and conversion functionality", optimized for "SSSE3 and AVX2"
on x86/x64 and "Neon, SVE2, and SME" on Arm (also MSA on MIPS, RVV on RISC-V) —
https://chromium.googlesource.com/libyuv/libyuv/+/HEAD/README.md

**Measured conversion cost (Mozilla bug 1256475, "Use libyuv for non scaling YUV
color conversion", on an Intel Core i7-6700K at 4GHz):**
https://bugzilla.mozilla.org/show_bug.cgi?id=1256475

4K frame, I420 -> ARGB:
| implementation | time per frame |
|---|---|
| libyuv `I420ToARGB` AVX2 | **8 ms** |
| libyuv `I420ToARGB` SSSE3 | 9 ms |
| libyuv `I420ToARGB` **C fallback** | **54 ms** |
| Gecko's old `ConvertYCbCrToRGB32` MMX/SSE | 12 ms |
| Gecko's old `ConvertYCbCrToRGB32` C fallback | 120 ms |

1080p frame in the same bug: ~8 ms before the patch, ~5 ms after (path
`I422ToARGBRow_AVX2`).

What those numbers mean for kaya:

- **SIMD is not optional, it is the whole thing.** The C fallback is **6.75x** slower
  than AVX2 at 4K (54ms vs 8ms). 54ms/frame is 3 frames' worth of budget at 60fps
  for the *color conversion alone*. The bug itself records the regression risk in
  the other direction: "if chip does not support ssse3, libyuv::I420ToARGB()
  fallback to c and it degrade performance compared to ConvertYCbCrToRGB32 mmx/sse."
- Even the *good* number is expensive. 8 ms of a 4 GHz desktop core to convert one
  4K frame; a 1080p frame is ~1/4 the pixels so ~2 ms of a fast desktop core per
  frame, i.e. **~12% of one core at 60fps just to change the pixel format**, before
  compositing. On a phone's little core that multiplies.
- On the GPU the same conversion is *free*: it is either fixed-function in the
  sampler (external OES textures on Android, `CVMetalTextureCache` planar textures
  on Apple) or three multiply-adds in a fragment shader executed as part of a
  sample the compositor was going to do anyway. That is the reason every framework
  in section B pushes it there.

---

## A4. What tiny-skia is, and is not

From the README — https://github.com/linebender/tiny-skia/blob/main/README.md :

- "tiny-skia is a tiny [Skia](https://skia.org/) subset ported to Rust"; the goal is
  "an absolute minimal, **CPU only**, 2D rendering library."
- Supported: "filling and stroking a shape with a solid color, gradient or pattern;
  stroke dashing; clipping; images blending; PNG load/save." Main missing feature is
  text rendering.
- **Explicitly NOT supported: GPU rendering, PDF generation, and non-RGBA8888 images.**
  That last one is decisive here: tiny-skia has no notion of a YUV/NV12 surface, no
  planar image type, and no video surface of any kind. Every video frame must be
  converted to RGBA8888 *before* tiny-skia can touch it.
- SIMD: yes. x86 gets "decent performance ... by default"; AVX needs
  `RUSTFLAGS="-Ctarget-cpu=haswell"`; "We support ARM AArch64 NEON as well and there
  is no need to pass any additional flags."
- Speed relative to Skia (README's own claim): "tiny-skia is 20-100% slower than
  Skia on x86-64 and about 100-300% slower on ARM", while being faster than cairo
  and raqote in many cases, and adding ~200 KiB to the binary vs Skia's 3-8 MiB.
  Benchmark harness: https://github.com/linebender/tiny-skia/blob/main/benches/README.md

### What would a per-frame 1080p `draw_pixmap` cost?

**No published benchmark of tiny-skia at 1080p image blit exists that I could find** —
tiny-skia's benches are path/gradient/stroke microbenchmarks, not full-frame image
composition, and nobody has published a video-rate number. So this has to be reasoned
from bandwidth rather than quoted, and it should be stated that way rather than
inventing a figure.

The floor is memory traffic: a `SrcOver` blend of a 1080p RGBA pixmap onto a 1080p
RGBA pixmap reads 8.29 MB of source, reads 8.29 MB of destination and writes 8.29 MB
of destination = ~25 MB of traffic per frame, 1.5 GB/s at 60fps. If the source is
opaque and the blend mode is `Source` (which a video frame is, and which tiny-skia
does have), the read of the destination goes away: ~16.6 MB/frame, ~1 GB/s at 60fps.
Streaming 1 GB/s through a single core is achievable on a desktop and marginal on a
phone's efficiency core, so the *blit itself* is not automatically fatal — **the
problem is that it is one of six such passes**, and the only one of the six a
texture path does not eliminate.

The other structural cost is that tiny-skia has no scaler tuned for this: any
non-1:1 video scaling (which is the normal case — a 1080p frame in a 640pt view)
goes through a general pattern/transform path per frame, and the README's own
"100-300% slower on ARM" than Skia applies to exactly that code.

---
## B5. Flutter's texture registry — the canonical form of the pattern

Flutter is the closest architectural analogue to kaya's "we own the pixels" stance,
and it is exactly where Flutter makes an exception.

**The `Texture` widget** (https://api.flutter.dev/flutter/widgets/Texture-class.html)
— verbatim:

> "Backend textures are images that can be applied (mapped) to an area of the Flutter
> view. They are created, managed, and updated using a platform-specific texture
> registry."

> "A texture widget refers to its backend texture using an integer ID. Texture IDs are
> obtained from the texture registry and are scoped to the Flutter view."

> "**Texture widgets are repainted autonomously as dictated by the backend (e.g. on
> arrival of a video frame). Such repainting generally does not involve executing Dart
> code.**"

That last sentence is the whole design in one line: **the pixels never enter the
framework's language runtime, and a new frame does not go through the framework's
build/layout/paint cycle at all.** Dart declares a rectangle with an integer id; the
engine's Skia/Impeller scene composites the platform texture into that rectangle on
the raster thread. Flutter's per-frame cost for video is the compositor sampling a
texture — the same cost as any other layer.

Related APIs: `TextureLayer` (https://api.flutter.dev/flutter/rendering/TextureLayer-class.html),
`TextureBox` (https://api.flutter.dev/flutter/rendering/TextureBox-class.html). The
widget carries `filterQuality` (default `FilterQuality.low`) and a `freeze` flag —
both are compositor-side sampling knobs, not per-frame CPU work.

**Android: `SurfaceProducer` replaced `SurfaceTextureEntry` (Flutter 3.22 landed,
3.24 stable).** https://docs.flutter.dev/release/breaking-changes/android-surface-plugins

> "For Impeller, use of this API is recommended."

The reason given is exactly the GPU-API one: Android's `HardwareBuffer` (API 29+) is
"backend-agnostic" and coincides with Flutter's move to the Vulkan renderer, whereas
"the old `SurfaceTexture` API relied on OpenGLES and was incompatible with Vulkan."
The plugin's whole job becomes:

```java
TextureRegistry.SurfaceProducer producer = textureRegistry.createSurfaceProducer();
Surface surface = producer.getSurface();   // hand this to MediaCodec / ExoPlayer
```

i.e. **the decoder writes directly into a buffer the compositor can sample. There is
no frame data path through the framework at all.**

**iOS: the `FlutterTexture` protocol returns a `CVPixelBufferRef`.** The engine calls
`copyPixelBuffer` when it wants a frame; the plugin calls `textureFrameAvailable` to
say one exists. Flutter's own tracking issue for redesigning this
(https://github.com/flutter/flutter/issues/159162) documents the pull model and its
races: "There is race between `textureFrameAvailable` and `copyPixelBuffer` in a sense
that call to `textureFrameAvailable` may or may not have any effect depending on
whether engine already cleared that flag or not." Despite the name, `copyPixelBuffer`
returns a *retained reference* to an IOSurface-backed buffer, not a byte copy — the
engine wraps it as a Metal texture (`FlutterDarwinExternalTextureMetal.mm`).

Worth noting for kaya: **even Flutter, which owns a complete GPU scene graph, treats
this as a hard boundary with its own lifecycle problems.** It is not free; it is just
enormously cheaper than moving bytes.

---

## B6. The per-platform primitives, precisely

### APPLE (macOS + iOS)

- **`CVPixelBuffer` backed by `IOSurface`.** Camera and decoder output is IOSurface-backed
  by construction; an IOSurface is a shareable, GPU-addressable buffer.
  Apple's Q&A on creating them: https://developer.apple.com/library/ios/qa/qa1781/_index.html
- **`CVMetalTextureCacheCreateTextureFromImage`** — "Creates a Core Video Metal texture
  buffer from an existing image buffer."
  https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)
  This is the zero-copy step: no pixels move, the Metal texture aliases the IOSurface.
  Apple's own note in the docs: the function "increments the use count of the image
  buffer, but not the IOSurface buffer. The Core Video Metal texture owns this IOSurface
  buffer" — i.e. it is explicitly an aliasing, not a copying, API. (The GLES-era twin is
  `CVOpenGLESTextureCache`.)
- **`AVPlayerItemVideoOutput`** — pulls frames from a running `AVPlayer` as
  CVPixelBuffers; `copyPixelBufferForItemTime:` "is typically called in response to a
  CVDisplayLink callback or CADisplayLink delegate invocation and if
  hasNewPixelBufferForItemTime also returns YES."
  https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput
- **`AVSampleBufferDisplayLayer`** — "An object that displays compressed or uncompressed
  video frames." A `CALayer` subclass; you enqueue `CMSampleBuffer`s through
  `sampleBufferRenderer` (an `AVSampleBufferVideoRenderer` conforming to
  `AVQueuedSampleBufferRendering`). iOS 8+/macOS 10.8+/visionOS 1.0+.
  https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer
  **This is the one that matters for a framework that does NOT own a GPU scene**: it is a
  Core Animation layer, so it composites with the rest of the native view tree for free,
  and it accepts frames you decoded yourself.
- Apple DTS, asked directly whether to use `CAMetalLayer` or `AVSampleBufferDisplayLayer`
  for video (https://developer.apple.com/forums/thread/756206):
  > "AVSampleBufferDisplayLayer will leverage the GPU and like Core Image may optimize
  > behavior dynamically based on the underlying hardware and operating system."
  > "Metal is a low-level framework dedicated to the GPU so you have finer grain control
  > over your rendering pipeline. This comes at the cost of high-level features offered
  > by AVFoundation and WebRTC."
  > "Overall AVSampleBufferDisplayLayer is probably better suited for your needs in this
  > case and is expected to perform well."

### ANDROID

- **`SurfaceTexture`** — captures frames into a `GL_TEXTURE_EXTERNAL_OES` texture.
  https://developer.android.com/reference/android/graphics/SurfaceTexture
- **`AHardwareBuffer`** + `EGL_ANDROID_get_native_client_buffer` — the Vulkan-era
  replacement; a shareable cross-process GPU buffer.
  https://developer.android.com/ndk/reference/group/a-hardware-buffer
- **Compose (1.7+): `AndroidExternalSurface` and `AndroidEmbeddedExternalSurface`.**
  This is the exact case kaya's Compose backend is in, and Google states the cost
  difference explicitly. From the kdoc
  (https://composables.com/foundation/androidexternalsurface):
  > `AndroidExternalSurface` "uses a separate window layer, graphics composition is
  > handled by the system compositor which can bypass the GPU and provide better
  > performance and power usage characteristics."
  Z-order is `Behind` (default), `MediaOverlay`, or `OnTop`; there is an `isSecure` flag
  for DRM. Signature:
  ```kotlin
  @Composable fun AndroidExternalSurface(
      modifier: Modifier = Modifier, isOpaque: Boolean = true,
      surfaceSize: IntSize = IntSize.Zero,
      zOrder: AndroidExternalSurfaceZOrder = AndroidExternalSurfaceZOrder.Behind,
      isSecure: Boolean = false, onInit: AndroidExternalSurfaceScope.() -> Unit)
  ```
  `AndroidEmbeddedExternalSurface` instead "positions its surface as a regular element
  inside the composable hierarchy... graphics composition is handled like any other UI
  widget using the GPU, which can lead to **increased power and memory bandwidth usage**"
  — and is what you use when the video must be "sandwiched between two other widgets, or
  if it must participate in visual effects."
  Google's stated rule: "**It is recommended to use AndroidExternalSurface over
  AndroidEmbeddedExternalSurface whenever possible.**"
  https://composables.com/docs/androidx.compose.foundation/foundation/composables/AndroidEmbeddedExternalSurface
- Android's media docs put the same rule in SurfaceView/TextureView terms
  (https://developer.android.com/media/media3/ui/surface):
  > "SurfaceView has a number of benefits over TextureView for video playback:
  > Significantly lower power consumption on many devices. More accurate frame timing,
  > resulting in smoother video playback. Support for higher quality HDR video output on
  > capable devices. Support for secure output when playing DRM-protected content. The
  > ability to render video content at the full resolution of the display on Android TV
  > devices that upscale the UI layer."
  > "TextureView should be used only if SurfaceView does not meet your needs."
  It also flags that Compose's two wrappers "provide an API surface that limits access of
  the underlying views", recommending `PlayerSurface`/`ContentFrame` from
  `media3-ui-compose` for full lifecycle handling.

---
### GTK4 / Linux

GTK's model is the most kaya-shaped of the four, because GTK is a widget toolkit that
does NOT own a GPU scene the way Flutter does — and it solved this problem anyway.

- **`GdkPaintable`** is the abstraction: "An interface for content that can be painted.
  The content of a `GdkPaintable` can be painted anywhere at any size without requiring
  any sort of layout." When contents change, the paintable calls
  `gdk_paintable_invalidate_contents()`, emitting `invalidate-contents`; static content
  sets `GDK_PAINTABLE_STATIC_CONTENTS`. Implementations include `GdkTexture`,
  `GdkMemoryTexture`, `GdkGLTexture` and `GdkDmabufTexture`.
  https://docs.gtk.org/gdk4/iface.Paintable.html
  `GtkPicture` displays any paintable: https://docs.gtk.org/gtk4/class.Picture.html
- **The CPU option: `GdkMemoryTexture`** — "A `GdkTexture` representing image data in
  memory." https://docs.gtk.org/gdk4/class.MemoryTexture.html — this is the naive path,
  and it is what a "kaya rasterizes, GTK blits" video implementation would use per frame.
- **The zero-copy option (GTK 4.14+): `GdkDmabufTextureBuilder` + `GtkGraphicsOffload`.**
  From GTK's own announcement (https://blog.gtk.org/2023/11/15/introducing-graphics-offload/):
  > "GtkGraphicsOffload widget, whose only job it is to give a hint that GTK should try
  > to offload the content of its child widget by attaching it to a subsurface instead of
  > letting GSK process it"
  The new `GdkDmabufTextureBuilder` wraps dmabufs (kernel buffers identified by file
  descriptors, typically from pipewire, video4linux or gstreamer) as `GdkTexture`s. Two
  configurations: the subsurface **above** the main surface enables direct scanout — a
  zero-copy path from decoder to display — and **below** it when UI must overlay the
  video, in which case the compositor still composes. Conditions: the content must
  already be dmabufs, and effects like corner-rounding defeat it.
  **Platform limit, stated flatly: "Graphics offload will only work with Wayland on
  Linux."** (X11 gets nothing.)
- Centricular's writeup of the GStreamer side
  (https://centricular.com/devlog/2024-04/gtk4-dmabuf-import/): before dmabuf import, the
  GTK4 sink "could only handle RGB system memory (i.e. after downloading from the GPU in
  case of hardware decoders) or GL textures"; dmabuf import "reduces CPU usage and power
  consumption considerably when using a suitable hardware decoder and running GTK on
  Wayland." (No measured numbers are published in that post — the claim is qualitative.)
- **`gtk4paintablesink`** is the ready-made bridge, a GStreamer element written in Rust
  providing "a `gst_video::VideoSink` along with a `gdk::Paintable` that's capable of
  rendering the sink's frames." It accepts system memory (RGBA/BGRA/RGB/BGR), GL textures,
  and "DMABufs on Linux with GTK 4.14+".
  https://gstreamer.freedesktop.org/documentation/gtk4/index.html
  `GtkGLArea` remains the manual-GL escape hatch: https://docs.gtk.org/gtk4/class.GLArea.html

### WINUI 3 / Windows

- **`SwapChainPanel`** — "provides a hosting surface where Microsoft DirectX swap chains
  provide content that can be rendered into a XAML UI"; you get at the underlying
  `IDXGISwapChain1` by QI'ing the panel for `ISwapChainPanelNative`, and can "refresh
  graphics without syncing to the XAML framework refresh timer."
  https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.swapchainpanel
  https://learn.microsoft.com/en-us/windows/uwp/gaming/directx-and-xaml-interop
  **Constraint worth knowing:** in WinUI 3, `SwapChainPanel` does not support transparency
  and cannot be sampled by `CompositionBackdropBrush`/`AcrylicBrush` effects.
- **Visual layer: `CompositionSurfaceBrush` painting a `SpriteVisual`** is the
  lower-level composition route.
  https://learn.microsoft.com/en-us/windows/uwp/composition/composition-brushes
  https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/composition
- **`MediaPlayer` frame server mode** is Microsoft's supported "you own the frames" path
  (https://learn.microsoft.com/en-us/windows/apps/develop/media-playback/play-audio-and-video-with-mediaplayer):
  > "In frame server mode, the **MediaPlayer** does not automatically render frames to an
  > associated **MediaPlayerElement**. Instead, your app copies the current frame from the
  > **MediaPlayer** to an object that implements `IDirect3DSurface`. The primary scenario
  > this feature enables is using pixel shaders to process video frames provided by the
  > **MediaPlayer**. **Your app is responsible for displaying each frame after processing,
  > such as by showing the frame in a XAML Image control.**"
  Enabled with `IsVideoFrameServerEnabled = true`; you handle `VideoFrameAvailable` and
  call `CopyFrameToVideoSurface(IDirect3DSurface)`.
  https://learn.microsoft.com/en-us/uwp/api/windows.media.playback.mediaplayer.copyframetovideosurface
  Note the shape: **the target is a D3D surface, not a byte array.** Microsoft's own
  sample then keeps everything on the GPU (Win2D `CanvasBitmap` -> `GaussianBlurEffect`
  -> `CanvasImageSource`); nothing in the supported path ever reads the pixels into
  CPU memory.

---

## B7. THE HARD PART — what does the pattern cost architecturally?

**The premise to check: does the framework need its own GPU compositor?**

Flutter needs one *because it has one*: `Texture` works by giving the engine's Skia/
Impeller scene a texture to draw. But that is Flutter's implementation of the pattern,
not the pattern itself. **The pattern is "the video lives in a compositable surface the
platform owns, and the framework positions it" — and every one of kaya's four backends
already sits on a platform compositor that can do this.** SwiftUI sits on Core Animation,
Compose sits on SurfaceFlinger/HWC, GTK4 sits on GSK plus (on Wayland) the system
compositor, WinUI sits on Windows.UI.Composition/DWM. kaya does not need to build a GPU
compositor; it needs to be able to say "put a platform-owned surface in this rectangle."

That is the good news. The cost is real but it is a *different* cost from "build a
renderer": it is **a second content model.** kaya's node tree currently has one leaf that
produces pixels (the canvas), and its bytes are kaya's. A video node's bytes would not be
kaya's — they would be a platform handle, per backend, with a per-backend lifecycle, and
kaya's own observables (expect_ink and friends) could not read them the way they read a
canvas raster. That is the architectural price, and it is paid in the harness and the
gates as much as in the backends.

### Per-backend: can this be done inside a native-view UI layer?

**SwiftUI (macOS + iOS) — YES, and the primitive is `AVSampleBufferDisplayLayer`.**
It is a `CALayer` subclass that "displays compressed or uncompressed video frames"
(https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer), so
it composites in the normal Core Animation tree alongside every SwiftUI view — no
GPU scene of kaya's own required. You reach it from SwiftUI through
`NSViewRepresentable`/`UIViewRepresentable`, which is exactly the drop-down mechanism
kaya's SwiftUI backend already uses for gaps. Apple DTS's own recommendation when asked
`CAMetalLayer` vs `AVSampleBufferDisplayLayer` for video:
> "Overall AVSampleBufferDisplayLayer is probably better suited for your needs in this
> case and is expected to perform well." — https://developer.apple.com/forums/thread/756206

Ranking of SwiftUI options, fast to slow:
1. `AVSampleBufferDisplayLayer` (enqueue `CMSampleBuffer`s; layer-composited, GPU) — fast.
2. `CAMetalLayer` / `MTKView` with a `CVMetalTextureCache`-derived texture — fast, more
   control, more code, and it loses AVFoundation features (PiP, etc.).
3. `AVPlayerLayer` / SwiftUI's `VideoPlayer` — fast, but only if AVPlayer owns the media.
4. **`Image(decorative: cgImage, scale:)` recreated per frame — SLOW, and this is the
   trap.** There is no SwiftUI primitive that takes a `CVPixelBuffer`; the only route is
   CVPixelBuffer -> CGImage -> `Image`, which forces a CPU-side pixel path AND drives a
   SwiftUI view-graph invalidation + diff on every frame. This is the "kaya rasterizes,
   SwiftUI blits" shape, and it is the slow one.

**Compose (Android) — YES, and Google has already written the answer down as a
recommendation.** `AndroidExternalSurface` gives a composable a real `Surface` to hand
`MediaCodec`/ExoPlayer, and it "uses a separate window layer, graphics composition is
handled by the system compositor which can bypass the GPU and provide better performance
and power usage characteristics." `AndroidEmbeddedExternalSurface` is the in-tree variant
whose "graphics composition is handled like any other UI widget using the GPU, which can
lead to increased power and memory bandwidth usage." Google's rule: "It is recommended to
use AndroidExternalSurface over AndroidEmbeddedExternalSurface whenever possible."
(https://composables.com/foundation/androidexternalsurface). Note this is *Compose's own
API*, in `androidx.compose.foundation` — no Flutter-style engine required.

**GTK4 — YES: `GtkPicture` + a `GdkPaintable`.** GTK is the existence proof that a plain
widget toolkit can do this: the widget displays a paintable, the paintable signals
`invalidate-contents` per frame, and the paintable's backing can be a `GdkMemoryTexture`
(CPU, slow), a `GdkGLTexture`, or a `GdkDmabufTexture` (zero-copy from a hardware
decoder, GTK 4.14+). Wrapping it in `GtkGraphicsOffload` promotes it to a Wayland
subsurface. `gtk4paintablesink` supplies the whole thing off the shelf. **The caveat is
that the fast path is Wayland-only** — on X11 GTK falls back to texture upload, which is
the CPU path again.

**WinUI 3 — YES, but it is the roughest of the four.** `SwapChainPanel` is a XAML
element hosting a DXGI swap chain, so it composites in the XAML tree; the D3D11 video
processor does YUV->RGB and scaling on the GPU. Frame server mode's `CopyFrameToVideoSurface`
targets an `IDirect3DSurface`, keeping the frame on the GPU. The friction: `SwapChainPanel`
has no transparency and cannot be sampled by backdrop effects in WinUI 3, so it is
genuinely a hole in the XAML tree rather than a normal element — which pushes the same
"UI beside, not on top" constraint that section C describes.

**Summary verdict for B7:** the texture-registry pattern does NOT require kaya to build
Flutter's GPU compositor. All four platforms expose a *platform-composited surface* that a
native-view UI layer can position. What kaya would give up is that video pixels stop being
kaya's pixels — no `expect_ink` over a video frame, no tiny-skia effect applied to it, and
four separate lifecycles to manage.

---
## B8. How expensive is the normal UI path per frame? (what is actually measured)

**The honest headline: almost nobody has published a clean per-frame measurement of
"push a full-frame bitmap through the framework's normal image widget."** What exists is
(a) platform vendors stating the rule qualitatively, sometimes forcefully, and (b) a few
incidental numbers from bug reports. Both are below. Do not let a survey turn the
qualitative statements into invented milliseconds.

### Android — the strongest authoritative statements of the four

From AOSP's graphics architecture docs (https://source.android.com/docs/core/graphics/arch-tv):
> "TextureView has better alpha and rotation handling than SurfaceView, but **SurfaceView
> has performance advantages when compositing UI elements layered over videos.**"
> "When a client renders with TextureView, the UI toolkit composites the TextureView
> object's content into the view hierarchy with the GPU."
> "Updates to the content may cause other view elements to redraw, for example, if the
> other views are positioned on top of TextureView."
> "After view rendering completes, SurfaceFlinger composites the app UI layer and all
> other layers, so that **every visible pixel is composited twice.**"
> "In API 24 and higher, it's recommended to implement SurfaceView instead of TextureView."

And (https://source.android.com/docs/core/graphics/arch-sv-glsv):
> "Rendering with SurfaceView, SurfaceFlinger directly composes buffers to the screen.
> Without a SurfaceView, you need to composite buffers to an offscreen surface, which then
> gets composited to the screen, so rendering with SurfaceView eliminates extra work."

Media3's list of SurfaceView's advantages over TextureView leads with "**Significantly
lower power consumption on many devices**" (https://developer.android.com/media/media3/ui/surface).
Compose's own kdoc says the embedded variant "can lead to **increased power and memory
bandwidth usage**". **Nowhere does Google publish the delta in numbers.**

No published measurement was found for `ImageBitmap`-recreated-per-frame in Compose
specifically. The general Compose performance material is about recomposition counts, not
bitmap upload (https://developer.android.com/develop/ui/compose/performance).

### Windows — one qualitative rule and one incidental number

Microsoft Learn, "Optimize animations, media, and images for WinUI apps"
(https://learn.microsoft.com/en-us/windows/apps/develop/performance/optimize-animations-and-media):
> "**Making per-frame updates, which are effectively dependent animations.** An example of
> this is applying transformations in the handler of the CompositionTarget.Rendering event."
> (listed under things that *disable* the composition-thread optimization and put work on
> the UI thread)
> "The [SoftwareBitmapSource] class **obviates an extra copy that would typically be
> necessary with WriteableBitmap**, and that helps reduce peak memory and source-to-screen
> latency." / "your app should use **SoftwareBitmapSource** when loading uncompressed image
> data instead of using **WriteableBitmap**."
> "The XAML framework can optimize the display of video content when it is the only thing
> being rendered, resulting in an experience that uses less power and yields higher frame
> rates."
> "**Animating a MediaPlayerElement is a similarly bad idea.** Beyond the performance
> detriment, it can cause tearing or other artifacts in the video content being played."

The one hard number found is WPF, not WinUI, and is a regression report rather than a
steady-state measurement — but it is the right order of magnitude to be scared of:
dotnet/wpf#6411 reports `WriteableBitmap` used to display **1920x1080** video frames
"will cost 70-90 ms with .net6", against no such cost on .NET Framework 4.8
(https://github.com/dotnet/wpf/issues/6411). A sibling report, dotnet/wpf#8045, records
`WriteableBitmap.Lock()` taking 100-200 ms at 3352x909 and under a millisecond at
3353x909 — a one-pixel width change (https://github.com/dotnet/wpf/issues/8045). The
lesson is not the specific number; it is that **the per-frame-bitmap path on a XAML stack
has cliffs nobody documents.**

### Apple — no published number at all

Apple publishes no measurement of `Image(decorative:)`-per-frame vs
`AVSampleBufferDisplayLayer`. The strongest available statement is the DTS engineer's
recommendation quoted in B6. This is a genuine gap: **if kaya wants a number here it will
have to measure it, and that measurement would be novel.**

### GTK — no published number

GTK's and Centricular's claims are qualitative ("reduces CPU usage and power consumption
considerably"). No before/after figures are published in either post.

### The one place a real number exists: Chromium

Chromium's VideoNG deep-dive (https://developer.chrome.com/docs/chromium/videong) is the
only source found that publishes overlay-vs-composite power figures:
> "the use of these (also often) opaque buffers ensures that **high bandwidth video data
> never actually leaves the GPU**"
> macOS fullscreen: "**power consumption during fullscreen video playback was halved**"
> "we can use overlays even in non-fullscreen cases, **saving up to 50% nearly everywhere**"
> "the goal of any modern video playback engine with efficiency in mind is to minimize
> bandwidth between the decoder and the final rendering step"

A 50% power reduction from *nothing but changing where the frame is composited* is the
best single datum in this whole document for the "is the CPU path affordable" question.

---

## C. THE HYBRID: video as its own compositor layer

### C9. Is there a middle route?

**Yes, and it is what every platform actually does — including for its own video
players.** The route is: kaya's canvas stays exactly as it is (CPU raster, tiny-skia,
blit), and a `video` node is declared as a *platform-composited surface* placed in the
layout, with kaya's UI drawn **around** it rather than **over** it. The platform's
compositor puts the two together. kaya never sees a video pixel.

This is not a compromise invented for kaya; it is the model with the best name-brand
support of anything in this document:

- **Chromium**: "video is just a fixed-size hole with opacity", where "each video talks
  directly to Viz" through a `SurfaceLayer` — hole-punching, in a browser engine that owns
  a full compositor and *still* prefers to hand the frame to the platform.
  https://developer.chrome.com/docs/chromium/videong
  Design doc: https://www.chromium.org/developers/design-documents/video-playback-and-compositor/
- **Android** is the extreme case, and it is the default: a `SurfaceView`'s surface is
  "the producer side of a BufferQueue, whose consumer is a SurfaceFlinger layer"; "the
  framework places the newly created surface behind the app UI surface" and the view
  leaves a transparent region for it. The Hardware Composer HAL then decides per-layer
  whether the display hardware can scan the video plane out directly ("device composition")
  instead of the GPU compositing it ("client composition").
  https://source.android.com/docs/core/graphics/arch-sv-glsv
  https://source.android.com/docs/core/graphics/hwc
  In Compose this is literally spelled as an argument:
  `zOrder = AndroidExternalSurfaceZOrder.Behind | MediaOverlay | OnTop`.
- **GTK4** offers the same choice explicitly: the offload subsurface goes **above** the
  main surface (direct scanout, the fast case) or **below** it "when UI elements appear
  over the video", in which case "the compositor still handles composition."
  https://blog.gtk.org/2023/11/15/introducing-graphics-offload/
- **Windows** states the rule as guidance rather than mechanism: "**Don't draw XAML
  elements on top of video when it's in embedded mode. If you do, the framework is forced
  to do a little extra work to compose the scene.** Placing transport controls below an
  embedded media element instead of on top of the video is a good example of optimizing
  for this situation." And for the full-window case: "For the most efficient media
  playback, set the size of a MediaPlayerElement to be the width and height of the screen
  and don't display other XAML elements", hiding captions and transport controls with
  `Visibility="Collapsed"` "when they are not needed to put media playback back into its
  most efficient state."
  https://learn.microsoft.com/en-us/windows/apps/develop/performance/optimize-animations-and-media

### What the hybrid forbids

This is the part to be honest about, because the restrictions are real and they are the
same on all four platforms:

1. **Nothing of kaya's may be drawn ON the video.** Captions, transport controls, a
   timestamp, a watermark, a focus ring — if it overlaps the video rectangle, either it
   forces the compositor off the fast path (Windows: "extra work"; GTK: subsurface goes
   *below*; Android: HWC falls back to client composition) or, in the strictest
   configurations, it is simply painted under the video and invisible. Android's own docs
   flag exactly this as SurfaceView's weak spot resolved only by ordering:
   "SurfaceView has performance advantages when compositing UI elements layered over
   videos" — i.e. the layering is what you must get right.
2. **No blending between two clips.** A crossfade needs both frames in one buffer; two
   compositor layers can only be alpha-blended by the compositor, which several of these
   paths (opaque overlay planes, `SwapChainPanel` with no transparency) do not support.
3. **No per-frame effects.** A tiny-skia blur, a colour grade, a mask, a rounded corner
   over the video — all require the pixels, which kaya will not have. GTK names the
   corner-rounding case specifically as something that "interfere[s] with subsurface usage".
4. **No animating or transforming the video rectangle.** Microsoft: "Animating a
   MediaPlayerElement is a similarly bad idea. Beyond the performance detriment, it can
   cause tearing or other artifacts." Android's `SurfaceView` is historically the widget
   that does not animate or scroll cleanly (which is exactly why `TextureView` exists, and
   why Media3 says use TextureView only "where smooth animations or scrolling of the video
   surface is required prior to Android 7.0").
5. **No `expect_ink` over the video.** kaya's harness reads its own raster; a
   compositor-owned surface is not in it. Every video observable would have to be a
   different kind of assertion (frame counters, presentation timestamps, platform
   screenshot), and the byte-frozen cross-platform string discipline that scenes rely on
   does not survive a real decoder's output anyway.
6. **Two content models forever.** Layout, clipping, scrolling, z-order and the a11y tree
   all have to be taught that one leaf is not kaya's pixels. The rounded-corner example is
   the canary: the moment a video sits inside a clipped scroller with a corner radius,
   three of the four backends silently leave the fast path.

### The escape hatch each platform gives back

Every platform offers an in-tree variant that lifts restrictions 1-4 at the cost of the
performance: Android's `AndroidEmbeddedExternalSurface`/`TextureView`, GTK's plain
`GtkPicture` without `GtkGraphicsOffload`, WinUI's frame-server-into-a-Win2D-image path,
Apple's `CAMetalLayer`/`Image`-per-frame. So the honest shape of the design space is a
**two-tier** one, and every platform already models it that way:

| tier | what you get | what you pay |
|---|---|---|
| **overlay / offload** (SurfaceView `Behind`, GTK offload subsurface, SwapChainPanel, AVSampleBufferDisplayLayer as a sibling layer) | up to 50% less power (Chromium's figure), decoder-to-display zero copy, hardware scanout | UI beside the video, not over it; no effects, no blend, no transform |
| **embedded** (AndroidEmbeddedExternalSurface, GtkPicture + memory/GL texture, Image + frame server, Image(decorative:) per frame) | video is a normal element: clip it, round it, overlay it, animate it | "every visible pixel is composited twice" (Android's words), plus whatever copies the path makes |

kaya's canvas rule ("kaya rasterizes, backends blit") survives intact under either tier —
it just does not extend to video. What the rule cannot survive is video frames going
through tiny-skia: that is the six-copy, ~4.85 GB/s-at-1080p60 path of section A1, on a
rasterizer whose own README says it does not do non-RGBA8888 images and does not do GPU.

---

## Sources (all URLs cited above, collected)

- tiny-skia README: https://github.com/linebender/tiny-skia/blob/main/README.md
- tiny-skia benches: https://github.com/linebender/tiny-skia/blob/main/benches/README.md
- libyuv README: https://chromium.googlesource.com/libyuv/libyuv/+/HEAD/README.md
- Mozilla bug 1256475 (libyuv timings): https://bugzilla.mozilla.org/show_bug.cgi?id=1256475
- Snapdragon 8 Elite Gen 5 product brief: https://www.qualcomm.com/content/dam/qcomm-martech/dm-assets/documents/Snapdragon-8-Elite-Gen-5-product-brief.pdf
- Notebookcheck SD 8 Elite Gen 5 (84.8 GB/s): https://www.notebookcheck.net/Qualcomm-Snapdragon-8-Elite-Gen-5-for-Galaxy-Processor-Benchmarks-and-Specs.1271123.0.html
- Apple M4 Pro / M4 Max newsroom: https://www.apple.com/newsroom/2024/10/apple-introduces-m4-pro-and-m4-max/
- Flutter Texture widget: https://api.flutter.dev/flutter/widgets/Texture-class.html
- Flutter TextureLayer: https://api.flutter.dev/flutter/rendering/TextureLayer-class.html
- Flutter TextureBox: https://api.flutter.dev/flutter/rendering/TextureBox-class.html
- Flutter SurfaceProducer breaking change: https://docs.flutter.dev/release/breaking-changes/android-surface-plugins
- Flutter issue 159162 (FlutterTexture redesign): https://github.com/flutter/flutter/issues/159162
- AVSampleBufferDisplayLayer: https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer
- CVMetalTextureCacheCreateTextureFromImage: https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)
- AVPlayerItemVideoOutput: https://developer.apple.com/documentation/avfoundation/avplayeritemvideooutput
- Apple QA1781 (IOSurface-backed CVPixelBuffers): https://developer.apple.com/library/ios/qa/qa1781/_index.html
- Apple DTS, CAMetalLayer vs AVSampleBufferDisplayLayer: https://developer.apple.com/forums/thread/756206
- Android SurfaceTexture: https://developer.android.com/reference/android/graphics/SurfaceTexture
- AHardwareBuffer: https://developer.android.com/ndk/reference/group/a-hardware-buffer
- Compose AndroidExternalSurface kdoc: https://composables.com/foundation/androidexternalsurface
- Compose AndroidEmbeddedExternalSurface kdoc: https://composables.com/docs/androidx.compose.foundation/foundation/composables/AndroidEmbeddedExternalSurface
- Media3 surface types: https://developer.android.com/media/media3/ui/surface
- AOSP SurfaceView: https://source.android.com/docs/core/graphics/arch-sv-glsv
- AOSP TextureView: https://source.android.com/docs/core/graphics/arch-tv
- AOSP Hardware Composer HAL: https://source.android.com/docs/core/graphics/hwc
- AOSP graphics architecture: https://source.android.com/docs/core/graphics/architecture
- GdkPaintable: https://docs.gtk.org/gdk4/iface.Paintable.html
- GdkMemoryTexture: https://docs.gtk.org/gdk4/class.MemoryTexture.html
- GtkPicture: https://docs.gtk.org/gtk4/class.Picture.html
- GtkGLArea: https://docs.gtk.org/gtk4/class.GLArea.html
- GTK graphics offload announcement: https://blog.gtk.org/2023/11/15/introducing-graphics-offload/
- Centricular, dmabuf import in the GTK4 sink: https://centricular.com/devlog/2024-04/gtk4-dmabuf-import/
- gtk4paintablesink: https://gstreamer.freedesktop.org/documentation/gtk4/index.html
- WinUI SwapChainPanel: https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.swapchainpanel
- DirectX and XAML interop: https://learn.microsoft.com/en-us/windows/uwp/gaming/directx-and-xaml-interop
- Composition brushes: https://learn.microsoft.com/en-us/windows/uwp/composition/composition-brushes
- Visual layer overview: https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/composition
- MediaPlayer frame server mode: https://learn.microsoft.com/en-us/windows/apps/develop/media-playback/play-audio-and-video-with-mediaplayer
- CopyFrameToVideoSurface: https://learn.microsoft.com/en-us/uwp/api/windows.media.playback.mediaplayer.copyframetovideosurface
- WinUI media/animation optimization: https://learn.microsoft.com/en-us/windows/apps/develop/performance/optimize-animations-and-media
- dotnet/wpf#6411 (WriteableBitmap 70-90ms at 1080p): https://github.com/dotnet/wpf/issues/6411
- dotnet/wpf#8045 (WriteableBitmap.Lock cliff): https://github.com/dotnet/wpf/issues/8045
- Chromium VideoNG: https://developer.chrome.com/docs/chromium/videong
- Chromium video playback and compositor: https://www.chromium.org/developers/design-documents/video-playback-and-compositor/
- Compose performance: https://developer.android.com/develop/ui/compose/performance

STATUS: COMPLETE.
