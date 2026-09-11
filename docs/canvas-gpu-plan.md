# Canvas rendering: vello_cpu, a GPU path, and zero-copy presentation (design pass; rulings TAKEN 2026-09-10)

The maintainer's question, 2026-09-10: "is zero copy gpu rasterization
really not accessible on GTK without dmabuf? can you do some research
around the rust crate ecosystem as well as how this feature could work
across platforms and come back with a clear plan?" The research record is
docs/probes/canvas-gpu-research-2026-09-10.md (every claim carries its
URL or file:line; inferences are marked). This document is the plan
built on it: the direct answer, the crates, one mechanism per platform,
what the harness keeps, and three slices each opened by the measurement
that decides it.

The maintainer took all six rulings the same day ("i'm cool with this
plan. i'd like to tackle this now"), and slice 1 was built on them (§10
records it).

Nothing here touches the wire or a binding. docs/canvas-plan.md's ruling
2 pins the rasterizer as an implementation detail behind the op stream,
and that is what makes every move below a core-and-backend change with
zero binding churn. Two of its rulings are amended by this plan, and both
amendments are the maintainer's call (§4).

## 0. The mechanism, from zero

A canvas today is a pixel buffer. The app declares ops (five geometry ops
plus text), the core rasterizes them on the CPU with tiny-skia into a
premultiplied RGBA8 buffer, and each backend BLITS that buffer with the
image machinery it already has: a `GdkMemoryTexture` on GTK
(crates/kaya/src/gtk.rs), a `CGImage` on SwiftUI, a `WriteableBitmap` on
WinUI, an `ImageBitmap` on Compose. The harness hashes the core's buffer
at a canonical scale (`expect_drawing_hash`, one string on five lanes)
and samples the backend's own surface at flat interiors (`expect_ink`,
±1 per channel).

"Zero-copy" means: the pixels the renderer produced are the pixels the
platform's compositor reads, with no CPU touch and no crossing of the
bus in between. On a GPU path that needs two things: the renderer draws
into GPU memory the toolkit can composite, and the toolkit is TOLD about
that memory rather than handed bytes.

The five platforms split two ways on that:

- **Four toolkits hand out a native surface.** SwiftUI gives an
  `NSView`/`UIView` a `CAMetalLayer` can be installed under; Compose
  gives a `SurfaceView` whose `ANativeWindow` a renderer presents into;
  WinUI gives a `SwapChainPanel`. wgpu creates a presentation surface
  from each of those directly. The renderer draws, the toolkit
  composites the layer. Zero copy is the default shape.
- **GTK4 composites everything itself.** GSK, GTK's scene-graph
  renderer, owns the window's surface and accepts exactly one currency
  from a widget: a `GdkTexture`. There is no wgpu surface for a GTK
  widget. So on GTK the question is not "where do I present" but "which
  KIND of GdkTexture does GSK take without copying", and the answer
  depends on which renderer GSK is running.

GSK 4.18 has two GPU renderers (the old GL renderer is gone in 4.18;
`GSK_RENDERER=gl` warns and gives the new one). Which one runs is
decided per display in `gsk/gskrenderer.c` lines 704-719: Vulkan is
picked as PRIMARY only on Wayland, on a device that is not a CPU, with
dmabuf formats exposed; the new GL renderer (ngl) is refused as primary
on llvmpipe; then both are tried again as fallbacks with the gates
skipped; then cairo. So a real GPU on X11 runs ngl, a real GPU on
Wayland runs Vulkan, and a software stack runs ngl as its fallback.

What each renderer does with each kind of texture, read off the 4.18
source rather than the 2024 blog post (which predates the Vulkan
renderer's dmabuf bridge):

| you hand GSK | under ngl (the GL renderer) | under the Vulkan renderer |
| --- | --- | --- |
| `GdkGLTexture` whose context is SHARED with GSK's | zero copy: the GL texture name is bound directly, after a `glWaitSync` on your fence (`gsk/gpu/gskglframe.c` 79-101) | zero copy ONLY IF `gdk_gl_context_export_dmabuf` succeeds (EGL with the dmabuf export extension, Linux); otherwise GPU→CPU→GPU (`gsk/gpu/gskvulkanframe.c` 162-223) |
| `GdkGLTexture` in an UNSHARED context | GPU→CPU→GPU round trip | GPU→CPU→GPU round trip |
| `GdkDmabufTexture` | zero copy (imported as an EGLImage) | zero copy (imported as a `VkImage`) |
| `GdkMemoryTexture` (today) | one upload per changed frame | one upload per changed frame |

"Shared" means `gdk_gl_context_is_shared()` says the texture's GL context
and GSK's are in one share group, which is true when the context came
from GDK's own `gdk_display_create_gl_context()` and false for a context
kaya created itself through EGL or GLX.

## 1. The direct answer

**Zero-copy on GTK4 is reachable without dmabuf, but only under GTK's
GL renderer, and only if the GL context comes from GDK.** Ask GDK for a
context, realize it, make it current, tell wgpu to adopt it, render into
a GL texture, and hand GSK a `GdkGLTexture` built from that texture's
name with a fence. GSK's GL renderer binds the name straight into its
frame; nothing is copied and nothing is imported. GSK's Vulkan renderer
has no such door: its only route to a GL texture goes THROUGH a dmabuf
export, and if that export fails GDK downloads the pixels and re-uploads
them. So the honest shape of the answer is a conditional:

- On X11 with any GPU, on Wayland without a Vulkan-capable GPU, and in
  kaya's own linux lane (llvmpipe, no Vulkan ICD at all, measured in §2),
  GTK runs ngl and the GL-texture route is genuinely zero-copy.
- On Wayland with a real GPU, GTK runs Vulkan and dmabuf is the only
  zero-copy currency. The GL-texture route still WORKS there (GDK's own
  bridge exports it), and on a Mesa stack with EGL the export normally
  succeeds, so it is zero-copy in practice on the common desktop and a
  copy on a stack whose export fails.

This is exactly the mechanism GStreamer's `gtk4paintablesink` ships
(`video/gtk4/src/sink/imp.rs` 1102-1131 and `frame.rs` 511-539 in
gst-plugins-rs): GDK's context, wrapped for the sink's own renderer, one
`GdkGLTextureBuilder` per frame with `set_sync` and a release callback.
Its README lists the same context types for macOS and Windows, so the
GL-texture route is not Linux-only; on kaya it is only needed on Linux
because the other four backends have a surface to present into.

Given that kaya's canvas re-rasters on data, scale and appearance change
rather than per frame (docs/canvas-plan.md §1.3), the recommendation is:
take the GL-texture route on GTK because it is a day's work and the lane
can see it; keep the `GdkMemoryTexture` readback as the fallback that
always works; and leave dmabuf where docs/canvas-plan.md's ruling 16
already put it, the Image widget's high-rate arm.

## 2. Ground truth measured before anything was priced

The linux lane's image, run by hand on 2026-09-10 (`docker run --rm
kaya-linux:latest`):

- GTK 4.18.6, libadwaita 1.7.6, Mesa 25.0.7. `swrast_dri.so` is present
  under the DRI directory, so llvmpipe (software OpenGL) IS in the
  container. Nothing under tools/ sets `GSK_RENDERER` or any Mesa knob.
- `libvulkan1` (the loader) is installed but `/usr/share/vulkan/icd.d` is
  EMPTY: `mesa-vulkan-drivers` is not installed, because tools/linux/Dockerfile
  installs with `--no-install-recommends`. A Vulkan instance in that
  container has zero physical devices. Lavapipe (software Vulkan) is one
  apt package away, and adding it WOULD move GSK's renderer under every
  linux leg: GSK refuses a `VK_PHYSICAL_DEVICE_TYPE_CPU` device as its
  primary choice, but the fallback pass skips that check and tries
  Vulkan before GL (`gsk/gskrenderer.c` 655-656 and 715-717, read on
  2026-09-10; the research record's §5 inferred the opposite and is
  corrected at its head). So a wgpu GL path leaves GTK where it is, and a
  wgpu Vulkan path changes what GTK runs on the lane, which is measured
  with `GSK_DEBUG=renderer` before it is taken (§8, slice 2).
- Both sessions the lane runs, Xvfb on X11 and headless sway on Wayland,
  therefore land on the ngl renderer over llvmpipe today.

So docs/canvas-plan.md §1.4's second reason for refusing GPU rendering,
"the linux lane has no GPU", is true of hardware acceleration and false
of whether a GL code path can execute there. A wgpu GL path runs in the
container with no Dockerfile change.

The versions that fix what "the crate ecosystem" means on this date:
vello_cpu 0.2.0 (2026-08-07), vello_common 0.2.0, vello_hybrid 0.2.0
(the repo has renamed it `vello_gpu`; the crates.io name `vello_gpu`
0.1.0 is a reservation, so the crate to depend on is still
`vello_hybrid`), classic vello 0.10.0 (now under `research/` in the
repo, called experimental by its own README), wgpu and wgpu-hal 30.0.1,
raw-window-handle 0.6.2, gtk4-rs with `gdk::GLTextureBuilder` (GTK ≥
4.12). kaya today: tiny-skia 0.12.0, harfrust 0.13.3, skrifa 0.46.2.

## 3. The crate ecosystem, and what each piece covers

The earlier question this session, "is there no library that handles all
of the zero-copy per-platform texture stuff for you?", has a precise
answer now:

- **wgpu handles surface CREATION on four of the five platforms.**
  `SurfaceTarget::DisplayAndWindow` over a raw window handle covers
  AppKit (`ns_view`, through `raw_window_metal::Layer::from_ns_view`),
  UIKit (`ui_view`), and Android (`a_native_window`);
  `SurfaceTargetUnsafe::SwapChainPanel` covers WinUI 3 and has since
  wgpu 0.18 (2023-10-25), dx12 backend only. Surface creation on Metal
  must be on the main thread (a documented panic).
- **Nothing handles the GTK handover.** GSK accepts a `GdkTexture`, not
  a surface. The pieces exist separately: wgpu-hal's
  `gles::Adapter::new_external` adopts a GL context somebody else made
  current (it never touches EGL itself, so a GDK context created through
  EGL or GLX both work given a symbol loader), and gtk4-rs exposes
  `GLTextureBuilder` with `set_sync` and `build_with_release_func`. The
  one thing that assembles them is `gtk4paintablesink`, and it is a
  GStreamer sink, not a library kaya can call. The assembly is about a
  hundred lines, and §6 prices it.
- **wgpu cannot render INTO GTK's own framebuffer.** `GtkGLArea` binds a
  non-zero FBO before its `render` signal; wgpu-hal has the internal
  `TextureInner::ExternalNativeFramebuffer` for that and no public
  constructor for it (searched: the variant appears at its definition
  and in four consumer arms, nowhere constructed). So the GtkGLArea
  route would end in a raw `glBlitFramebuffer`, one intra-GPU copy, and
  is dominated by the GdkGLTexture route.
- **The two vello GPU renderers are not interchangeable.** Classic
  `vello` renders with compute shaders into a `STORAGE_BINDING` texture
  and cannot run on GL ES; `vello_hybrid` does path processing on the
  CPU and only compositing on the GPU, asks for `Features::empty()` and
  WebGL2-downlevel limits in its own examples, and is the one that can
  run through wgpu's GLES backend, which is the backend a GDK context
  forces. vello's README says the hybrid (now `vello_gpu`) is the one
  "aimed to be the main Vello implementation for production use-cases".
- **vello_cpu is immediate-mode, not scene-based.** `RenderContext` with
  `set_paint` / `set_fill_rule` / `set_stroke` / `fill_path(&BezPath)` /
  `stroke_path` / `flush` / `render(&mut Pixmap)`. No `Scene` type; the
  shared-scene-encoding idea docs/canvas-plan.md killed as a wire format
  is not even the shape of the modern crate. The CPU and GPU crates
  share the geometry front end (`vello_common`) but not a public scene
  kaya could hand to either, so a GPU path builds its own op walk, which
  is the same walk the CPU path does.

## 4. Rulings proposed

| # | ruling | status |
| --- | --- | --- |
| G1 | **vello_cpu replaces tiny-skia, and kaya keeps its own text.** harfrust shapes and skrifa outlines glyphs into paths today; the swap feeds those PATHS to vello_cpu's `fill_path`, never its `glyph_run`, so the text half of every frozen hash changes engine for nothing. vello's own text is moving onto its `glifo` crate, which is one more reason not to depend on it. This is docs/canvas-plan.md ruling 14's lever 4 being taken, which that ruling already calls a standing evaluation, so it needs no ruling change. | TAKEN 2026-09-10 |
| G2 | **The canonical raster is pinned at `Level::fallback()` and `num_threads: 0`; the on-screen raster runs `Level::new()` with threads.** vello's snapshot corpus asserts byte-exact output across SIMD levels by default (threshold 0), with a handful of named tolerance exceptions, and its own example says scalar fallback "reduces the possibility of slight pixel differences when running on different platforms". The canonical raster is already a separate render from the screen's (docs/canvas-plan.md §7.1), so pinning costs nothing on screen, and the belt-and-braces keeps `expect_drawing_hash` ONE string. A gate holds the pinned settings, because a raster that quietly moved to `Level::new()` for the hash goes green on five aarch64 lanes and red on the first x86_64 one. | TAKEN 2026-09-10 |
| G3 | **A GPU display path is taken, subject to one measurement.** This is lever 5 leaving RESERVED, and it amends ruling 2's "GPU rendering for this buffer is refused ON PRINCIPLE" to: refused for the CANONICAL raster, which stays CPU and stays the thing kaya freezes and reasons about; the DISPLAY may be drawn by the GPU. The measurement gate: at kaya's real canvas sizes, vello_hybrid including its readback must beat multithreaded vello_cpu decisively, or slice 2 stops with "vello_cpu with threads, no GPU", which would be a fine outcome. | TAKEN 2026-09-10 |
| G4 | **One device owner in the core.** A new file under crates/kaya/src/, `canvas/gpu.rs`, creates the one wgpu instance, adapter and device; backends receive a texture or surface handle and never name a vello or wgpu type. tools/check-canvas-blit.py grows the clause: exactly one file constructs the device, and the four backend arms may name a handle but never a renderer type. "Kaya rasterizes, backends blit" survives with "blit" now including "composite the texture kaya gave you". | TAKEN 2026-09-10 |
| G5 | **Device-or-CPU is a measured answer, not an allowlist.** At device acquisition kaya renders vello's own eight-feature probe scene (`vello_common::probe`, tolerance 3 per channel against its bundled reference) and falls back to vello_cpu on anything but `Success`. That is a diagnostic that prints only what it measured (CLAUDE.md invariant 3). `KAYA_CANVAS_RENDERER=cpu|gpu` pins either for a lane. | TAKEN 2026-09-10 |
| G6 | **GTK takes the GL-texture route; readback is the fallback; dmabuf stays the Image widget's.** §1's answer as a ruling. The dmabuf export bridge under GSK's Vulkan renderer is GDK's own and costs kaya nothing to use; a kaya-side dmabuf export (raw `ash` through `Device::as_hal`, `VK_KHR_external_memory_fd`, `VK_EXT_image_drm_format_modifier`, none of which wgpu wraps) is NOT built for the canvas, and is the Image widget's business when its high-rate arm comes (docs/canvas-plan.md ruling 16). | TAKEN 2026-09-10 |

What the harness keeps under G3 is already written down in
docs/canvas-plan.md §15.3 lever 5 and is restated in §7 with the one new
verb it needs.

## 5. Presentation per platform

All from wgpu-hal 30.0.1's surface code and the toolkits' own APIs; the
research record has the file:line for each.

| backend | wgpu takes | the host supplies | zero copy? | measurement first |
| --- | --- | --- | --- | --- |
| SwiftUI / macOS | `RawWindowHandle::AppKit { ns_view }`; wgpu installs a `CAMetalLayer` under the view (`wgpu-hal/src/metal/mod.rs` 164-186) | an `NSViewRepresentable`; size, `contentsScale`, resize and appearance callbacks; surface creation on the main thread | yes, Metal presents the layer | that a Metal layer under a SwiftUI view still passes through `KayaRender`'s a11y wrapper and the appearance override (tools/check-universal-props.py and tools/check-appearance.py both have clauses a new view layer could bypass) |
| SwiftUI / iOS | `RawWindowHandle::UiKit { ui_view }`, same arm | a `UIViewRepresentable` | yes | same, once macOS is done |
| WinUI 3 | `SurfaceTargetUnsafe::SwapChainPanel(ptr)`, dx12 backend | a `SwapChainPanel` in the XAML tree, its `ISwapChainPanelNative` pointer, `CompositionScaleChanged` and `SizeChanged` | yes, DXGI presents the swap chain | that a `SwapChainPanel` can be reached through kaya's generated WinUI bindings at all: `ISwapChainPanelNative` is COM, not WinRT, and tools/winui-bindgen emits WinRT |
| Compose / Android | `RawWindowHandle::AndroidNdk { a_native_window }`, Vulkan or GLES | an `AndroidView` hosting a `SurfaceView`; `ANativeWindow_fromSurface` on the holder's `Surface`; surfaceCreated/Changed/Destroyed owned by the host | yes | surface lifecycle under the lane's `remount-*` legs: Compose's mount is re-entrant by design, and a wgpu surface outliving its `SurfaceView` is a crash, not a red leg |
| GTK4 | nothing: no surface. wgpu-hal `gles::Adapter::new_external` over GDK's own context; a GL texture per in-flight frame | `gdk_display_create_gl_context()` + `realize()` + `make_current()`; `GLTextureBuilder` with `set_id`, `set_sync`, `build_with_release_func`; every wgpu call inside `make_current` (the adapter's documented contract), the device dropped inside one too | under ngl yes; under Vulkan via GDK's dmabuf export | §6's probe |

The `wgpu` calls on GTK ride a contract worth stating once: the adopted
context must be current whenever wgpu touches anything from that adapter,
including drop. That makes wgpu's lifetime GTK's problem and is the one
piece of the GTK arm that is harder than the other four.

## 6. GTK: the five options priced, and the measurement that decides

| option | mechanism | copies | requires | verdict |
| --- | --- | --- | --- | --- |
| (i) `GtkGLArea` + wgpu adopting its context | render into wgpu's texture, `glBlitFramebuffer` into the area's FBO from `render` | one intra-GPU blit (no public wgpu constructor for an external FBO) | ngl or Vulkan (GTK wraps the area's texture itself) | dominated by (ii) |
| (ii) shared `GdkGLContext` → `GdkGLTexture` | the `gtk4paintablesink` pattern, §1 | zero under ngl; zero under Vulkan when GDK's export works | GTK ≥ 4.12 for the builder; a GDK-created context | **TAKE** |
| (iii) kaya exports a dmabuf → `GdkDmabufTexture` | wgpu Vulkan + raw `ash` for the fd export | zero under both renderers | Linux only; GTK ≥ 4.14; extensions wgpu does not wrap | the Image widget's arm, not the canvas's (G6) |
| (iv) `GtkGraphicsOffload` | bypass GSK, hand the compositor a dmabuf subsurface | zero | Wayland only, GTK ≥ 4.14, a dmabuf, nothing drawn over it | a modifier on (iii) for video; wrong shape for a canvas under labels |
| (v) readback → `GdkMemoryTexture` | today's blit with a GPU in front | GPU→CPU (`copy_texture_to_buffer` + `map_async`, a sync point per frame) then GDK's upload | nothing; works on every renderer including llvmpipe under Xvfb | the always-works fallback |

**The one-afternoon measurement that settles (ii):** a probe inside the
lane's container, under both Xvfb and headless sway, that creates GDK's
context, adopts it with `new_external`, renders one frame with
vello_hybrid into a GL texture, hands GSK the `GdkGLTexture`, and
prints `GSK_DEBUG=renderer`. It answers two things: (a) whether wgpu's
GLES adapter comes up on a GDK-created context at all (on X11 that
context may be `GdkX11GLContextGLX`, and wgpu's gles backend is written
against GL ES semantics; if that fails, `gdk_gl_context_set_allowed_apis`
to GLES, GTK ≥ 4.12, and re-measure), and (b) whether GSK takes the
zero-copy branch, visible because `gskglframe.c` line 83 gates on
`gdk_gl_context_is_shared`. Only a red on both readings makes dmabuf
necessary for the canvas, and that is a separate L on its own.

## 7. The harness: what survives, and the one new verb

| observable | after the vello_cpu swap | under a GPU display path |
| --- | --- | --- |
| `expect_drawing_hash` (FNV over the core's canonical raster) | survives as ONE string after a re-freeze, given G2's pin and the slice-1 measurement | unaffected: it never reads the screen |
| `expect_drawing` (op count + normalized ink bounds) | survives; a sub-pixel AA change can move a bound by a hundredth | survives |
| `expect_ink` (±1 per channel at flat interiors) | survives | survives, and this is the claim the design leans on: a flat interior is a constant colour, and edges are where two rasterizers disagree |
| captures | change once, reviewed once | change per vendor |

**Why a GPU CANONICAL raster is not proposed anywhere in this plan:** the
WebGPU spec concedes machine-specific rasterization artifacts (§2.2.2),
Skia describes its GPU antialiasing as chosen per surface and primitive,
and vello, which owns both renderers and targets one reference set,
still needs a `hybrid_tolerance` knob and a tolerance of 3 in its device
probe. A GPU buffer is a buffer no scene can freeze, exactly as
docs/canvas-plan.md §1.4 said; what changes is that the FROZEN buffer
is not the one on screen.

**The new verb.** `expect_drawing_matches <target> <max_channel_delta>
<max_differing_fraction>`: render the same op list through both paths on
the machine under test and compare with vello's own shape, a per-channel
threshold plus an allowed count of differing pixels. It catches "the GPU
path drew something else entirely" while tolerating "the GPU path's AA is
a shade different", and it reads two artifacts rather than the model
(§7.1's discipline). The two numbers are ruled once and pinned in all
three harnesses by tools/check-verbs.py, the ±1 tolerance's shape.

**The linux lane's honest limit.** The lane runs a software rasterizer,
so it can prove the GPU code path EXECUTES and agrees within tolerance;
it cannot prove anything about a real driver. That is the same limit as
the x86_64-under-emulation half of the cross-ISA probe
(docs/measurements/canvas-cross-isa-2026-08-26.txt) and is written down
the same way. A wgpu GL path needs no Dockerfile change and leaves GSK
on ngl; a Vulkan path needs `mesa-vulkan-drivers`, which moves GSK to its
Vulkan renderer on lavapipe as well (§2), so the whole linux lane is
re-run and read before that package is taken.

**The gate clause** is G4's: tools/check-canvas-blit.py holds one device
owner, and no backend names a renderer type. Its negative doctors a copy
of a backend to construct a device and demands the red.

## 8. Build order: three slices, each opened by the measurement that decides it

Costs use the roadmap's calibration (S about a day, M one to two, L two
to four, XL four to seven); the canvas itself cost three days.

### Slice 1: the vello_cpu swap (M). Needs no ruling.

1. **The measurement first, half a day, and it is the whole risk.** A
   probe renders kaya's own op streams (the canvas scene's figure, the
   portfolio chart, one text-heavy drawing) at canonical scale through
   vello_cpu 0.2.0 under `Level::fallback()` × `Level::new()` ×
   `num_threads ∈ {0, 2, 4}`, natively on the mac and under x86_64
   emulation, hashing each buffer. It answers whether SIMD level,
   thread count or ISA moves a byte. Its record is
   docs/measurements/canvas-cross-isa-2026-08-26.txt's successor, one
   axis wider, and it decides whether the frozen hash stays one string.
2. crates/kaya/Cargo.toml swaps tiny-skia for vello_cpu (kurbo comes
   with it). crates/kaya/src/canvas.rs's `rasterize()` and glyph sink
   take the call-for-call mapping in the research record's §1 table:
   `Pixmap::new` (u16 dimensions, kaya already clamps at 16384),
   `BezPath` for `PathBuilder`, `set_paint` / `set_fill_rule` /
   `set_stroke`, `flush()` before `render()`, `data_as_u8_slice()` out.
   Same layout, same premultiplication, so all four blit arms are
   untouched. Text keeps harfrust + skrifa and feeds paths (G1).
3. **Watch the stroke.** kaya deliberately inherits tiny-skia's default
   joins, caps and miter limit; `kurbo::Stroke`'s defaults are another
   library's. Pin kaya's own values explicitly so the look moves only
   where the plan says it moves.
4. `hash()` is unchanged and its VALUES move: every `expect_drawing_hash`
   string in tools/scenes is re-frozen, and a capture round follows
   (docs/canvas-plan.md §1.4 budgeted exactly this).
5. **A free lever to take in the same slice:** `aliasing_threshold:
   Option<u8>` is in vello_common and vello_cpu already; it is
   docs/canvas-plan.md §15.3 lever 2 (the per-canvas aliasing knob)
   arriving as a prop rather than as work. Whether to spell it in nine
   bindings now or later is a sweep question for the build, not a
   blocker.
6. **The guard:** the probe checked in as a measurement file, and a
   check clause holding the canonical raster's `RenderSettings` at the
   pinned level and thread count (G2), watched red with the level
   perturbed.

### Slice 2: a GPU path with readback, and the device-or-CPU policy (L). Needs G3, G4, G5.

1. **The measurement first:** at the portfolio chart's size, the lane's
   1600×1000 and a phone's 1200×2400, time vello_cpu single-threaded,
   vello_cpu multithreaded, and vello_hybrid on wgpu INCLUDING
   `copy_texture_to_buffer`, `map_async` and the 256-byte row de-pad. If
   the GPU is not decisively ahead of threaded vello_cpu at those sizes,
   slice 2 stops here and the record says so: §15.3's own table already
   moves the failing phone frame from 171% of budget to 55% with four
   threads, before vello_cpu's 5 to 18× multiplier.
2. If the GPU wins: `vello_hybrid` (not classic vello), one device owner
   in the new `canvas/gpu.rs` under crates/kaya/src/, vello's probe at
   acquisition, the env override, the readback into today's four blit
   arms. Readback is not zero-copy and is not the point of this slice;
   it is the honest way to have a SECOND implementation of the canonical
   raster a lane can compare (the new verb), and it is the path every
   backend runs until its slice-3 arm lands.
3. The verb, its two numbers, the check-verbs clause pinning them, the
   check-canvas-blit clause (G4), and the Dockerfile change only if the
   Vulkan backend is chosen, with `GSK_DEBUG=renderer` read on the lane
   before and after.

### Slice 3: zero-copy presentation, per backend (XL across five, landed depth-first). Needs G6.

Ordered by cost to prove, each with its opening measurement from §5:

1. macOS (S to M): `NSViewRepresentable`, Metal layer, the a11y and
   appearance clauses re-run.
2. iOS (S): same file, `from_ui_view`.
3. Windows (M): `SwapChainPanel`; the bindgen reach measured first.
4. Android (M): `SurfaceView` under `AndroidView`; the remount legs
   first.
5. GTK4 (L): §6's probe first, then the `gtk4paintablesink` shape, with
   the readback arm kept as the fallback the lane runs if the probe says
   no. GTK is last because it is the only backend where the mechanism
   itself is the open question.

A backend that has not taken its arm keeps slice 2's readback, so at no
point is there a platform with no GPU path and no CPU path; the CPU path
is always there, since the canonical raster never leaves it.

## 9. What this plan does not do, and what it asks

- It does not touch the op vocabulary, the wire, or any binding. Nine
  bindings see nothing; the sweep verdict is the same in all nine:
  nothing to do.
- It does not build a dmabuf exporter for the canvas (G6). If the
  maintainer wants the Image widget's high-rate arm, that is its own
  design pass and this plan's §6 (iii) is its starting point.
- It does not freeze a GPU raster anywhere. Per-config goldens arrive
  only with ops that have no CPU reference, and this plan adds none.
- **Asks:** G3 and G6 amend docs/canvas-plan.md rulings 2 and 14 and are
  the maintainer's call. G1, G2, G4 and G5 follow from rulings already
  taken and can be ratified by "go ahead". Slice 1 can start on either
  answer.

## 10. Slice 1, built 2026-09-10

- **The measurement first**, as §8 said: docs/measurements/canvas-vello-determinism-2026-09-10.txt.
  Every cell of scalar × NEON/AVX2 × {0, 2, 4} threads × {aarch64,
  x86_64} agreed on all three of kaya's op streams, and the probe's
  tiny-skia hash of the canvas figure equalled the scene's frozen string,
  which is how the probe was known to measure kaya's pipeline and not a
  neighbour. The probe source is beside the record.
- **The swap**: crates/kaya/Cargo.toml carries vello_cpu 0.2.0 (std and
  the u8 pipeline; `multithreading` off in this slice, since the crate
  builds a thread pool per context and at kaya's sizes that pool cost
  more than it saved — on since 2026-09-11 with the context kept, §11)
  and names fearless_simd's
  `force_support_fallback` feature, which is where `Level::fallback()`
  lives. crates/kaya/src/canvas.rs rasterizes through `RenderContext`
  onto kurbo paths: `CANONICAL_SETTINGS` (scalar, one thread) for
  `probe()`, `screen_settings()` (`Level::new()`, one thread) for the
  screen, text kept on harfrust + skrifa and fed as paths (G1), and the
  stroke pinned to the values kaya always drew with — butt caps, miter
  joins, limit 4 — because kurbo's own defaults are round on both.
- **The hashes moved once.** canvas.steps 7ae0a9280909ee7b (was
  e5ac8a2c0b240633), portfolio.steps 6b2cf4b8a3f05415 / 3864e7eaa9a194b7
  / 2a0b4ef7e4c99502, sizepolicy.steps UNCHANGED at 8185fc030ee419b6:
  its figure is axis-aligned rectangles on integer edges, so no
  antialiasing is involved and the two rasterizers agree byte for byte.
  The two unit tests that pin hashes moved with them.
- **The guard**: tools/check-canvas-blit.py clause 6 holds the pin —
  the constant's two fields, `probe()` passing it, `rasterize()` passing
  the screen settings with `Level::new()`, and the u8 pipeline alone —
  with five watched negatives on doctored copies of canvas.rs, each
  seen firing.
- **Not taken in this slice**: `aliasing_threshold` as a prop (§8 item
  5) — a binding-surface sweep of its own, on the ledger.
- **The matrices.** #1 on the swapped tree: mac 440, linux 765, windows
  277 and android 143 legs green with the 58-gate sweep, every canvas leg
  on every lane green (the iOS canvas legs in 4-5s), and ONE red leg, iOS
  links-swiftui, where act two never wrote a verdict after the link
  door — the app-links door, not the raster, on a host at load 88. Read
  from the recorder: the driver looked for SpringBoard's confirmation
  once, 0.05s after `openurl`, saw nothing, and nothing followed; the
  same device asked and passed the moment the lane ran alone. Fixed at
  the cause (the door polls for the alert until the verdict, the expiry
  sentence tells its two causes apart; docs/traps.md), the late arm
  watched printing under `KAYA_IOS_LATE_ALERT_TEST`, and #2 on the final
  tree is recorded in the commit.

## 11. Slice 2's measurement, taken 2026-09-10: the GPU path is not taken

docs/measurements/canvas-gpu-timing-2026-09-10.txt. At every size kaya
draws — the chart at its own 280x180, the lane's 1600x1000, a phone's
1200x2400 — vello_hybrid on Metal is 3-20x SLOWER than vello_cpu, with
or without the readback, and threaded vello_cpu with a reused context
draws every phone-size frame in under a millisecond. G3's named stop
applies: slice 2 ends with "vello_cpu with threads, no GPU", and slice
3 (zero-copy presentation per backend, G6's GTK route included) is not
built, because there is no GPU frame to present. The plan's research
stands as the record of how it would be done if a canvas ever needs it,
and the probe is a `cargo run` away.

The maintainer's follow-up, whether slice 3's presented surface (no
readback) would have changed the verdict, is measured in the same
record: the pipelined, no-readback shape loses too, and the fill-heavy
case that a GPU fine stage exists for is where the hybrid's own CPU
half becomes the bottleneck (10ms of strips at 800 full-screen fills
against vello_cpu's whole 5ms threaded frame). Only the all-GPU
classic vello escapes that, and it is the experimental one. The
chicken-and-egg is real in principle and not yet in practice: 800
translucent full-screen fills per frame at phone resolution sit at a
third of the budget on threads, and the trigger for revisiting is a
canvas that misses that budget on a phone-class core, which is a
measurement rather than a feeling.

Classic vello, the all-GPU compute renderer, was measured too, at the
maintainer's request (the same record): its CPU side is nearly nothing
and it beats the hybrid everywhere, and it still loses to vello_cpu on
8 threads on every valid scene (one row within 0.2ms), with a ~0.5ms
per-frame pipeline floor even pipelined; at 800 full-screen fills its
default bump buffers overflowed and it drew nothing, silently, the
failure the research named. The phone-class core was measured the same night
(docs/measurements/canvas-gpu-timing-iphone-2026-09-10.txt, an iPhone 17
Pro through tools/ios/gpuprobe/build.py): five phone threads keep every
scene inside the frame budget, 800 full-screen fills at 9.5ms, so the
ruling stands as a matter of budget — with one refinement on the record:
the all-GPU renderer beats the phone's cores 2x on the many-small-paths
scene, so a canvas drawing tens of thousands of paths per frame is where
classic vello is measured again.

What survives from slice 2 is the threads: above about a megapixel, 8
workers on a reused context are 1.7-2.5x faster than one, and their
bytes equal the single-threaded bytes in every cell measured. BUILT
2026-09-11: the screen raster draws through a context kept per thread
and resized in place (`Context::Screen` in crates/kaya/src/canvas.rs),
takes `screen_threads(pixels)` workers above `SCREEN_THREADS_ABOVE`
(one megapixel, the measured crossover) and one below, with
`multithreading` on the dependency; the canonical raster stays scalar,
single-threaded and on a fresh context under G2, and check-canvas-blit's
clause 6 holds the threads rule beside the pin (a sixth watched
negative). A unit test draws small, large and small again through the
kept context and holds every picture equal to a fresh context's.
