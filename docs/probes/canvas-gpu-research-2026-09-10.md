# Canvas GPU research, 2026-09-10 (the record behind docs/canvas-gpu-plan.md)

Landed straight from the session that produced it, like the 2026-09-02/03
families in this directory. The maintainer's question was whether zero-copy
GPU rasterization is reachable on GTK4 without dmabuf, and what the Rust
crate ecosystem offers for a GPU canvas path on all five platforms; the
plan that answers it is docs/canvas-gpu-plan.md. The notes below are the
research agent's, verbatim but for one citation into a scratch file that
now points at the plan. ONE INFERENCE IN IT IS WRONG and is left in place
as written: §5 says a lavapipe ICD in the lane's container would leave
GSK on its GL renderer. Read against `gsk/gskrenderer.c` on the same day,
the fallback pass skips the CPU-device check (lines 655-656) and tries
Vulkan before GL (lines 715-717), so `mesa-vulkan-drivers` would move GSK
to its Vulkan renderer on lavapipe; docs/canvas-gpu-plan.md §2 carries the
corrected reading.

---

# Vello / wgpu / zero-copy presentation — research notes for kaya

Written progressively. Every claim carries the URL or `file:line` it came
from. Anything that is my inference rather than something read is marked
**[inference]**.

Research date: 2026-09-10. Repo base: `/Users/akhilindurti/Projects/kaya`
(branch `main`, HEAD `7a58125` per the session's git status).

---

## §0 — The ground truth in this tree (read first, so the rest is priced against it)

### What the canvas is today

- The architecture rule: "A canvas widget's content is a PIXEL BUFFER the
  core produced. ... No backend interprets an op." —
  `docs/canvas-plan.md:85-95` (§1.1).
- Ruling 2 (2026-08-26): "**The rasterizer is a pinned implementation
  detail behind the wire.** tiny-skia today; `vello_cpu` is explicitly
  revisitable when it stabilizes, as a one-crate swap with zero binding
  churn. GPU rendering for this buffer is refused ON PRINCIPLE." —
  `docs/canvas-plan.md:47`.
- The swap is priced in the plan already: "swapping it is a one-crate
  change in the core with zero binding churn and one observable
  consequence: the §7 hashes move, which is a scene edit and a capture
  round, not a protocol change." — `docs/canvas-plan.md:201-207`.
- The GPU refusal's two reasons, stated so they can be re-argued
  precisely: (1) "Driver-dependent antialiasing destroys the
  cross-platform byte-identity the whole harness story rests on";
  (2) "The linux lane has no GPU. It is a docker container
  (tools/linux/Dockerfile)". — `docs/canvas-plan.md:209-222`.
- Lever 5 in §15.3 already reserves the escape hatch and is the hook this
  whole research hangs on: "**A GPU display path: RESERVED, NOT
  PLANNED.** ... What ruling 14 reserves is a display path — the platform
  drawing what the user sees while the core's CPU raster stays the thing
  kaya reasons about." — `docs/canvas-plan.md:2193-2196`. And the harness
  consequence is already worked out there: `expect_drawing_hash` is
  "CPU-BY-DEFINITION" and `expect_ink` "samples the backend's own
  rendered surface, but only at centres of flat-filled regions" —
  `docs/canvas-plan.md:2198-2205`.

### The exact tiny-skia surface kaya uses (this is the swap's whole bill)

`crates/kaya/src/canvas.rs`:

| use | line | call |
| --- | --- | --- |
| pixel buffer | `canvas.rs:467` | `tiny_skia::Pixmap::new(w, h)` |
| paths | `canvas.rs:477,485-487` | `PathBuilder` + `move_to` / `line_to` / `close` |
| stroke | `canvas.rs:497-507` | `Stroke { width, ..Default::default() }`, `pixmap.stroke_path(path, paint, stroke, Transform::identity(), None)` |
| fill | `canvas.rs:516-527` | `FillRule::EvenOdd` / `Winding`, `pixmap.fill_path(...)` |
| paint | `canvas.rs:491-493` | `Paint::default()`, `set_color(Color::from_rgba8(..))`, `anti_alias = true` |
| text | `canvas.rs:553-563` | glyph outlines built into a `tiny_skia::Path` (skrifa), then `fill_path` with `FillRule::Winding` |
| output | `canvas.rs:569` | `pixmap.take()` -> `Vec<u8>`, premultiplied RGBA8 |

Notable absences, which is what makes the swap small: **no clip mask is
ever used** (`None` is passed as the mask argument at `canvas.rs:506`,
`canvas.rs:526`, `canvas.rs:562`); **no transform is ever used** —
`Transform::identity()` everywhere, because kaya bakes the viewbox fit
into the coordinates itself at `canvas.rs:474-476,485-486`; **no
gradients, no dashes, no blend modes, no joins/caps** — §3.3's vocabulary
is five geometry ops plus text (`docs/canvas-plan.md:54`), and joins/caps
are deliberately left at tiny-skia's defaults (`canvas.rs:494-496`).

So kaya's rasterizer dependency is: *build a path from lines, fill it
(NZ or EO) with a solid opaque colour, stroke it with a solid colour and
a width, antialiased, into a premultiplied RGBA8 buffer.* That is the
smallest interesting subset any 2D renderer has.

Dependency versions (`crates/kaya/Cargo.toml:27-31`, confirmed in
`Cargo.lock`): `tiny-skia 0.12.0`, `harfrust 0.13.3`, `skrifa 0.46.2`,
`read-fonts 0.43.3` (transitively).

### The four blits (what a GPU path would have to replace, per backend)

- GTK4: `gdk::MemoryTexture::new(..., MemoryFormat::R8g8b8a8Premultiplied, bytes, stride)`
  handed to a `KayaCanvas` — `crates/kaya/src/gtk.rs:8724-8742`, widget
  declared at `crates/kaya/src/gtk.rs:1803-1806`.
- SwiftUI (mac + iOS, one file): `CGImage` over the buffer with
  `CGImageAlphaInfo.premultipliedLast` —
  `swift/KayaSwiftUI.swift:14575-14590`.
- WinUI: `WriteableBitmap` — `crates/kaya/src/winui/mod.rs:75,146-147`;
  the plan notes this arm swizzles to premultiplied BGRA8
  (`docs/canvas-plan.md:1528-1534`).
- Compose: `ImageBitmap` filled from the buffer
  (`docs/canvas-plan.md:1520-1522`).

### The harness contract a GPU path has to survive

- `expect_drawing_hash <target> "<hex>"` — rasterized at canonical scale
  1.0 in canonical (light) mode, FNV-1a over `width|height|pixels`
  (`crates/kaya/src/canvas.rs:583-598`), frozen as ONE string across five
  lanes (`docs/canvas-plan.md:1204-1220`).
- `expect_ink` compares **within ±1 per channel** because a macOS
  window's backing store carries the display's colour profile — ruled
  2026-08-26, pinned in all three harnesses by `tools/check-verbs.py`
  (CLAUDE.md's check-verbs paragraph; `docs/canvas-plan.md:7.2`).
- `tools/check-canvas-blit.py` holds "KAYA RASTERIZES, BACKENDS BLIT" as
  a *static* rule: the two widget backends may not name the op vocabulary
  at all, and the interpreters may name an op constant only at its
  definition (CLAUDE.md, check-canvas-blit paragraph). **[inference]** A
  GPU display path does not violate that gate as written — the gate
  forbids backends *interpreting ops*, not backends receiving a texture —
  but the gate would need a new clause about who owns the device.

### The Linux lane's actual GPU situation — MEASURED, not assumed

Run against the lane's own image (`docker run --rm kaya-linux:latest`,
2026-09-10):

- GTK **4.18.6**, libadwaita 1.7.6 (`pkg-config --modversion gtk4`).
- Mesa **25.0.7-2+deb13u1** is installed: `libgl1-mesa-dri`,
  `mesa-libgallium`, `libglx-mesa0`, `libegl-mesa0`, `libgbm1`.
- `/usr/lib/aarch64-linux-gnu/dri/` contains **`swrast_dri.so`**,
  `kms_swrast_dri.so`, `zink_dri.so`, `virtio_gpu_dri.so`. So
  **llvmpipe (software GL) IS available in the container.**
- `libvulkan1` (the loader) is installed, but **`/usr/share/vulkan/icd.d`
  is EMPTY** and `mesa-vulkan-drivers` is **not installed** (`dpkg -l |
  grep -c mesa-vulkan` = 0). The Dockerfile installs everything with
  `--no-install-recommends` (`tools/linux/Dockerfile:27-36`), which is
  why. So **lavapipe (software Vulkan) is NOT available today** — a
  Vulkan instance in that container has zero physical devices.
- The lane runs under Xvfb (`Xvfb :$1 -screen 0 1600x1000x24`,
  `tools/linux/run-suites.sh:288`) on X11 and a **headless sway** on
  Wayland (`tools/linux/run-suites.sh:187`), 1600x1000 on both
  (`tools/linux/run-suites.sh:150`).
- Nothing in `tools/` sets `GSK_RENDERER`, `LIBGL_ALWAYS_SOFTWARE`,
  `GALLIUM_DRIVER` or any Mesa knob (grep over `tools/` returns nothing).

**Consequence, and it changes the §1.4 reason-2 refusal:** the linux lane
is not GPU-less in the sense that matters. It has a working software
OpenGL stack today. It does **not** have software Vulkan today, but
adding `mesa-vulkan-drivers` to the Dockerfile is one apt package (and
would also give GSK its Vulkan renderer). **[inference]** That makes
"the linux lane has no GPU" a statement about *hardware acceleration*,
not about *whether a wgpu/GL or wgpu/Vulkan code path can execute there*.

---

## §1 — vello_cpu: version, stability, determinism, text, API, and the swap bill

### Version and release cadence

- `vello_cpu` **0.2.0**, published **2026-08-07**
  (https://crates.io/api/v1/crates/vello_cpu). Version history: 0.0.1
  2025-05-09 · 0.0.2 2025-09-22 · 0.0.3 2025-10-03 · 0.0.4 2025-10-17 ·
  0.0.5 2026-01-08 · 0.0.6 2026-01-15 · 0.0.7 2026-03-24 · 0.0.8
  2026-05-15 · 0.0.9 2026-05-30 · **0.1.0 2026-07-29** · **0.2.0
  2026-08-07**. Nothing yanked. 3,593,074 downloads total, 2,727,736 in
  the recent window.
- Sibling crates, same cadence: `vello_common` 0.2.0 (2026-08-07),
  `vello_hybrid` 0.2.0 (2026-08-07), `vello` (the classic GPU-compute
  renderer) **0.10.0** (2026-08-14).
- **The repo has renamed `vello_hybrid` to `vello_gpu`.** `main` has
  top-level dirs `vello_cpu`, `vello_common`, `vello_gpu`,
  `vello_gpu_shaders`, `vello_tests`, `glifo`, `research/` (the classic
  compute renderer now lives under `research/`)
  (`gh api repos/linebender/vello/contents`). `vello_gpu/Cargo.toml` says
  `name = "vello_gpu"`, `version = "0.2.0"`. On crates.io `vello_gpu`
  0.1.0 (2026-08-26) is only a name reservation — "Reserving the name for
  a future crate in the Vello ecosystem", 12 downloads. So **the crate to
  depend on today is still `vello_hybrid 0.2.0`; the name it will have
  next is `vello_gpu`.**
- The `sparse_strips/` directory the task brief expected is gone; the
  crates moved to the repo root (404 on
  `sparse_strips/vello_cpu/README.md`).

### Stability — the project's own words

`vello_cpu/src/lib.rs`'s "Current state" section, verbatim
(https://raw.githubusercontent.com/linebender/vello/main/vello_cpu/src/lib.rs):

> Vello CPU is a solid CPU-only 2D renderer with broad, reliable feature
> support. It provides excellent performance across a wide range of
> workloads, with optimized SIMD implementations for all major
> architectures. The renderer is still under active development,
> however, and a few limitations remain:
> - Complex filter graphs are currently not supported at all and will
>   panic. In multi-threaded mode, even simple filters are currently
>   unsupported.
> - Parts of the API and its documentation are still suboptimal, for
>   example the `Resources` lifecycle.
> - Some exposed features remain experimental and are not recommended for
>   use, including glyph caching.
> - There is still more room for performance improvements, in particular
>   on x86 systems and also for multi-threaded rendering.

**None of the four limitations touches kaya's op vocabulary.** kaya draws
no filters, uses no glyph cache, and its raster is one-shot per size or
data change. **[inference]** On kaya's actual subset, vello_cpu 0.2.0 is
past the "not stable enough to pin" bar that ruling 2 set in August.

The root README calls the classic `vello` "experimental" and says
**Vello GPU** (ex-hybrid) is "aimed to be the main Vello implementation
for production use-cases"
(https://raw.githubusercontent.com/linebender/vello/main/README.md). MSRV
is Rust 1.89 (kaya pins 1.97.0 in `flake.nix`, so that is clear).

### Determinism — NOT GUARANTEED BY CONSTRUCTION, BUT EXACT IN PRACTICE

**READ THE "§1 AMENDMENT" SECTION BELOW WITH THIS ONE.** I wrote this
subsection first, off vello's docs, and then found its test-generation
macro, which makes the answer considerably better than the docs alone
suggest. Both halves are on the record; the amendment is the sharper one.

This is the finding that decides slice 1's shape, and vello says it in
its own docs rather than my inferring it.

`vello_cpu/examples/basic.rs`, verbatim
(https://raw.githubusercontent.com/linebender/vello/main/vello_cpu/examples/basic.rs):

> The `level` field indicates what SIMD level should be used. In the vast
> majority of cases, you should just use `Level::new` so that Vello CPU
> automatically uses an appropriate level that is available on the host
> system.
>
> There are very few reasons to override that value. One instance where
> it might be useful to override is for example when using Vello CPU to
> create reference images for test suites. In that case, you could pass
> `Level::fallback`, which indicates to Vello CPU that no
> platform-specific SIMD intrinsics should be used. **This might be
> useful because it reduces the possibility of slight pixel differences
> when running on different platforms.**

`Level`'s own docs (https://docs.rs/vello_cpu/0.2.0/vello_cpu/enum.Level.html):
"The level enum with the specific SIMD capabilities available." Variants
`Fallback` ("Scalar fallback level, i.e. no supported SIMD features are
to be used"), `Sse4_2`, `Avx2`, plus a NEON level on aarch64 and WASM
SIMD128.

Corroborating evidence that vello itself does not treat its output as
byte-stable:

- Its snapshot harness takes a **per-channel tolerance and an allowed
  differing-pixel count**: `check_ref(..., threshold: u8, diff_pixels: u32)`
  in `vello_tests/tests/util.rs:362-371`, with `diff_pixels: 0` as the
  macro default (`vello_tests/vello_dev_macros/src/test.rs`) but
  per-test overrides in the corpus — `#[vello_test(cpu_u8_tolerance = 1)]`
  (`vello_tests/tests/mix.rs`), `#[vello_test(hybrid_tolerance = 1)]`
  (`vello_tests/tests/clip.rs`), `#[vello_test(diff_pixels = 2)]` with the
  comment "It's likely that the issue comes from accumulated rounding
  errors" (`vello_tests/tests/gradient.rs`), `diff_pixels = 55` for a
  glyph test (`vello_tests/tests/glyph.rs`). All via
  `gh search code --repo linebender/vello`.
- `vello_common/src/probe.rs:43-44`: "Per-channel absolute tolerance used
  when comparing probe pixels. `const CHANNEL_TOLERANCE: u8 = 3;`" — that
  is their *device capability probe*, which compares a rendered scene
  against a bundled `probe.rgba` reference across renderers.
- Their CI runs `cargo test` on `windows-latest`, `macos-latest` and
  `ubuntu-latest` (`.github/workflows/ci.yml`, the `cargo test` job's
  matrix), i.e. AVX2 x86_64 and NEON aarch64 against **one** set of
  snapshot PNGs — so cross-SIMD differences are at most within those
  per-test tolerances, but the harness that proves it is a tolerant one,
  not an exact one.

**What this means for kaya, concretely.** `expect_drawing_hash` is FNV-1a
over the exact bytes (`crates/kaya/src/canvas.rs:586-598`) — zero
tolerance by construction. Three ways to keep it:

1. **Pin `Level::fallback` for the canonical raster.** vello's own
   recommended move for reference images. Cost: the canonical raster
   loses SIMD. **[inference]** That is acceptable *only* if the canonical
   raster is the harness's raster and the on-screen raster may use
   `Level::new()` — but §7.1 rasterizes at canonical scale/mode and the
   screen raster at the window's scale/mode, so they are already two
   different renders. kaya can therefore run the screen at full SIMD and
   the hash at `Fallback` with no contradiction.
2. **Pin `Level` to the ISA all five lanes share.** All five lanes are
   aarch64 today (`docs/canvas-plan.md:1268-1273`), so NEON is uniform —
   but that re-creates exactly the untested-cross-ISA hole §7.1 measured
   away, and makes the first x86_64 lane a red day.
3. **Keep `num_threads: 0` for the canonical raster.** Unknown whether
   thread count changes bytes — the docs say nothing
   (https://docs.rs/vello_cpu/0.2.0/vello_cpu/struct.RenderSettings.html:
   `num_threads` is documented only as "The number of worker threads that
   should be used for rendering"). **[inference]** Sparse-strip
   rasterization partitions by strip and composites in a fixed order, so
   thread count *should* not change the result; but "should" is exactly
   what §7.1's cross-ISA probe refused to accept, so this needs the same
   treatment: a measurement before a hash is frozen.

**The measurement slice 1 owes, and it is cheap:** render kaya's own
canvas scene op stream at canonical scale under
`Level::fallback()` × `Level::new()` × `num_threads ∈ {0,2,4}` on the mac
(NEON) and under x86_64 emulation, and diff the buffers. That is the
exact shape of `docs/measurements/canvas-cross-isa-2026-08-26.txt`, one
axis wider.

### Text

- `text` is a **default feature**; glyph rendering is
  `RenderContext::glyph_run(&mut self, resources, font: &FontData) -> GlyphRunBuilder`
  (https://docs.rs/vello_cpu/0.2.0/vello_cpu/struct.RenderContext.html).
- The font type is `vello_common::peniko::FontData` — peniko's `Blob`-backed
  font handle (seen in `vello_tests/tests/util.rs:19`, which imports
  `vello_common::peniko::{Blob, ColorStop, ColorStops, FontData}` and
  `skrifa::MetadataProvider` beside it).
- **Their glyph stack is moving off skrifa onto their own `glifo` crate.**
  `vello_gpu`'s `text` feature is "Glyph rendering capabilities via
  `glifo`" (`vello_gpu/Cargo.toml`), and `glifo/` is a top-level directory
  in the repo with its own glyph cache and atlas
  (`glifo/src/glyph.rs`, `glifo/src/atlas/cache.rs`). `vello_tests` still
  imports skrifa for font metadata (`vello_tests/tests/util.rs:16-17`).
  **[inference]** kaya would NOT use vello's text path: kaya already
  shapes with harfrust and outlines with skrifa into a path
  (`crates/kaya/src/canvas.rs:646,685-743`), and that path is what freezes
  the hash. Keeping kaya's own shaping and feeding vello_cpu **paths**
  keeps the text half of the hash entirely unchanged by the swap, which
  makes the swap strictly smaller. This is worth ruling explicitly.

### API surface, and whether the Scene type is shared with the GPU renderer

- `vello_cpu` is **immediate**, not scene-based: you build a
  `RenderContext`, call `set_paint` / `set_transform` / `set_fill_rule` /
  `set_stroke`, then `fill_path(&BezPath)` / `stroke_path(&BezPath)` /
  `glyph_run(..)`, then `flush()` and `render(&mut Pixmap, &mut Resources)`
  (https://docs.rs/vello_cpu/0.2.0/vello_cpu/struct.RenderContext.html).
  There is **no `Scene` type** in vello_cpu 0.2.0's public API — the
  `Scene`/`Encoding` pair belongs to the classic `vello` crate, now under
  `research/`. So the "shared scene encoding" the canvas plan already
  killed as a wire format (`docs/canvas-plan.md:2226-2237`) is not even
  the shape of the modern CPU crate.
- `vello_hybrid`/`vello_gpu` has its own `Scene`
  (`vello_gpu/src/scene.rs`), and **[inference]** from the fact that both
  read `ctx.aliasing_threshold` and route through `vello_common`'s
  `strip_generator` / `strip.rs` / `clip.rs`
  (`gh search code --repo linebender/vello "aliasing_threshold"`), the CPU
  and GPU crates share the *geometry front end* (`vello_common`) but not a
  public scene type you can hand to either.

### The one-crate swap bill, mapped call by call

| kaya today (`crates/kaya/src/canvas.rs`) | vello_cpu 0.2.0 |
| --- | --- |
| `Pixmap::new(w, h)` (u32) | `Pixmap::new(w, h)` — **u16**, so ≤ 65535; kaya already clamps to 16384 at `canvas.rs:465-466` |
| premultiplied RGBA8 out via `pixmap.take() -> Vec<u8>` | `Pixmap` is "premultiplied RGBA8 values backed by u8", row-major, "`[r, g, b, a]`"; `take()` returns `Vec<PremulRgba8>`, `data_as_u8_slice()` gives the bytes (https://docs.rs/vello_cpu/0.2.0/vello_cpu/struct.Pixmap.html) — **identical layout, identical premultiplication**, so all four blit arms are untouched |
| `PathBuilder` + `move_to`/`line_to`/`close` | `kurbo::BezPath` with the same three ops |
| `Paint::default()` + `set_color` | `set_paint(color)`; `Paint`/`PaintType` enum |
| `FillRule::{Winding, EvenOdd}` | `set_fill_rule(..)` |
| `Stroke { width, ..Default }` | `set_stroke(kurbo::Stroke)` |
| `anti_alias = true` | default; **plus** `aliasing_threshold: Option<u8>` in `vello_common::viewport` / `vello_cpu::dispatch` — kaya's §15.3 lever 2 (a per-canvas aliasing knob) arrives for free |
| `Transform::identity()` everywhere | `set_transform(Affine)`; kaya can keep baking the fit itself or hand it over |
| no clip mask (`None` at `canvas.rs:506,526,562`) | `push_clip_path` / `pop_clip_path` exist and are unused |
| text as a filled path | keep kaya's harfrust+skrifa outline; feed `fill_path` |

Two behavioural differences to watch, both **[inference]** from the docs:

- kaya's stroke leans on **tiny-skia's default joins/caps/miter**
  (`canvas.rs:494-496` says so out loud). `kurbo::Stroke`'s defaults are
  a different library's defaults, so **strokes will move pixels even at
  the same width** — that is a hash change, which the plan already
  budgets for, but it is also a *look* change worth a capture round.
- `flush()` must be called before `render()`; the docs say it is "only
  strictly necessary if you are rendering using multiple threads" but
  "it is recommended to always do this"
  (https://docs.rs/vello_cpu/0.2.0/vello_cpu/struct.RenderContext.html).

**Performance:** the canvas plan already cites vello's own chart at
"5.3-17.8x tiny-skia single-threaded" (`docs/canvas-plan.md:2005`,
https://laurenzv.github.io/vello_chart/). That is the same lever as
§15.3's measured 3.4x band tiling, multiplied rather than replaced —
vello_cpu has its own `multithreading` feature.

---

## §2 — vello (GPU) and vello_hybrid / vello_gpu: what each needs, and the readback route

### The two GPU renderers are NOT interchangeable, and only one of them can run on GL

**Classic `vello` 0.10.0** — the GPU-compute renderer, now living under
`research/` in the repo.

- Its only render entry point is
  `Renderer::render_to_texture(&self, device, queue, scene, texture: &TextureView, params)`
  (https://docs.rs/vello/latest/vello/struct.Renderer.html). There is no
  `render_to_surface` in 0.10.0's documented surface; you render to a
  texture and blit/present it yourself.
- The target texture must be **`TextureFormat::Rgba8Unorm` with
  `TextureUsages::STORAGE_BINDING`** (same page). A storage-binding
  render target is the signature of a compute-shader renderer, which is
  why it cannot run on GL ES / WebGL2.
- `RendererOptions::use_cpu` — "If true, run all stages up to fine
  rasterization on the CPU" — is explicitly "not a recommended
  configuration as it is expected to have poor performance, but it can be
  useful for debugging"
  (https://docs.rs/vello/latest/vello/struct.RendererOptions.html).
- The root README calls it "experimental"
  (https://raw.githubusercontent.com/linebender/vello/main/README.md).

**`vello_hybrid` 0.2.0 (renaming to `vello_gpu`)** — "A hybrid CPU/GPU
renderer for 2D vector graphics" that uses "the CPU for path processing
and initial geometry setup" and "the GPU for fast rendering and
compositing," minimising CPU↔GPU transfer
(https://docs.rs/vello_hybrid/latest/vello_hybrid/,
https://raw.githubusercontent.com/linebender/vello/main/vello_gpu/README.md).

- Main types: `Scene`, `Renderer` / `WebGlRenderer`, `RenderTargetConfig`,
  `RenderSize` (docs.rs, same page).
- Two backends: **wgpu** (default; "supporting hardware APIs like Vulkan,
  Metal, and DX12") and **WebGL** (GLSL shaders, browser)
  (`vello_gpu/README.md`; `vello_gpu/Cargo.toml` features:
  `default = ["wgpu", "wgpu_default", "text"]`, plus `webgl`, `probe`,
  `std`, `libm`).
- **It needs no wgpu features and runs at WebGL2 limits.** Its own
  examples ask for `required_features: wgpu::Features::empty()`
  (`vello_gpu/examples/render_to_file.rs`,
  `vello_gpu/examples/winit/src/render_context.rs`,
  `vello_gpu/examples/wgpu_webgl/src/lib.rs`) and the WebGL example asks
  for `backends: wgpu::Backends::GL` with
  `..wgpu::Limits::downlevel_webgl2_defaults()`
  (`vello_gpu/examples/wgpu_webgl/src/lib.rs`). Its shaders even
  pre-compute on the CPU what "downlevel targets do not support"
  (`vello_gpu/src/render/common.rs`). **[inference]** That means
  vello_hybrid is the only one of the two that could run through wgpu's
  **GLES backend**, which is the backend a GTK GL-context adoption would
  force.
- Known limitations, verbatim: "Mask layers, complex filter graphs as
  well as certain blend modes for non-isolated blending" are unsupported
  and "will panic"; it is "slightly less mature than its CPU-only
  counterpart Vello CPU" (docs.rs). **None of those is in kaya's op
  vocabulary.**
- It has a `render_to_file` example, so **offscreen rendering to a wgpu
  texture is a first-class path** (`vello_gpu/examples/render_to_file.rs`).

### The readback route, and what it costs

The readback route is: render into an offscreen `wgpu::Texture`, then
`CommandEncoder::copy_texture_to_buffer` into a `MAP_READ` buffer, then
`Buffer::map_async` + poll + read the slice. Two mechanical facts:

- Every row of the destination buffer must be padded to
  **`wgpu::COPY_BYTES_PER_ROW_ALIGNMENT = 256`** bytes
  (`wgpu-types/src/lib.rs:125`), so a 1920-wide RGBA8 readback is already
  aligned (7680 = 30 × 256) but an arbitrary canvas width needs a padded
  staging buffer and a de-pad pass on the CPU.
- `map_async` needs the queue to be polled and the GPU to be idle for
  that submission, i.e. **a full pipeline flush and a sync point every
  frame.**

**[inference — no measurement made here]** At 1920×1080 RGBA8 the payload
is 8.29 MB per frame. On a discrete GPU over PCIe 4.0 x16 (~25 GB/s
practical) that is ~0.33 ms of pure transfer plus the stall; on Apple
silicon unified memory `copy_texture_to_buffer` into a shared buffer is a
same-memory blit, so the cost is dominated by the sync point rather than
the bandwidth. Either way the readback re-imports the exact problem the
canvas plan already priced as "the blit is bandwidth"
(`docs/canvas-plan.md:178`, citing Chromium's "texture uploads of bitmaps
are a non-trivial bottleneck"), with a GPU round trip added in front of
it. **A GPU path whose output is read back to bytes is strictly worse
than vello_cpu for kaya's chart-shaped workloads, and only pays for
itself at a raster size or fill rate where the CPU renderer misses
frame budget.** That is a measurement, and §6 slice 2 owes it.

**What the readback route IS good for:** it is the honest way to get a
*second* implementation of the canonical raster on a GPU, which is what
lets a lane compare CPU and GPU output at all. See §5.

---

## §3 — Presentation per platform through wgpu's surface creation

All of this is from `wgpu-hal`/`wgpu` trunk, which is wgpu **30.0.1**
(docs.rs reports 30.0.1 for both `wgpu` and `wgpu-hal`).

### The two entry points

`wgpu::SurfaceTarget` (safe) has exactly two native variants
(https://raw.githubusercontent.com/gfx-rs/wgpu/trunk/wgpu/src/api/surface.rs):

- `DisplayAndWindow(Box<dyn DisplayAndWindowHandle>)` — the usual one.
  Its documented panics matter to kaya: "**On macOS/Metal: will panic if
  not called on the main thread.**"
- `Window(Box<dyn WindowHandle>)` — window handle only; requires the
  display handle to have been passed through `InstanceDescriptor::display`.

`wgpu::SurfaceTargetUnsafe` (same file) has, in full:

| variant | cfg | what it takes |
| --- | --- | --- |
| `RawHandle { raw_display_handle: Option<RawDisplayHandle>, raw_window_handle: RawWindowHandle }` | always | the rwh pair |
| `Drm { fd, plane, connector_id, width, height, refresh_rate }` | `cfg(drm)` | a KMS plane |
| `CoreAnimationLayer(*mut c_void)` | `cfg(metal)` | "Surface from `CoreAnimationLayer`" |
| `CompositionVisual(*mut c_void)` | `cfg(dx12)` | "Surface from `IDCompositionVisual`" — refcount incremented internally |
| `SurfaceHandle(*mut c_void)` | `cfg(dx12)` | a DirectComposition handle for `IDXGIFactoryMedia::CreateSwapChainForCompositionSurfaceHandle`; lifetime **not** managed |
| `SwapChainPanel(*mut c_void)` | `cfg(dx12)` | "Surface from DX12 `SwapChainPanel`" — refcount incremented internally |

**Yes, `SwapChainPanel` is a supported surface target, and has been for a
long time.** It was added in **wgpu v0.18.0 (2023-10-25)** — CHANGELOG
line "Add WinUI 3 SwapChainPanel support. By @ddrboxman in
[#4191](https://github.com/gfx-rs/wgpu/pull/4191)"
(https://raw.githubusercontent.com/gfx-rs/wgpu/trunk/CHANGELOG.md, under
`## v0.18.0 (2023-10-25)`). It is `cfg(dx12)`, i.e. **the DX12 backend
only** — a WinUI SwapChainPanel cannot be driven by wgpu's Vulkan or GL
backends.

The relevant `raw_window_handle` **0.6.2** variants and their fields
(https://docs.rs/raw-window-handle/latest/raw_window_handle/):
`AppKitWindowHandle { ns_view }`,
`UiKitWindowHandle { ui_view, ui_view_controller }`,
`AndroidNdkWindowHandle { a_native_window }`,
`Win32WindowHandle { hwnd, hinstance }`, plus `Xlib`, `Xcb`, `Wayland`,
`Drm`, `Gbm`, `WinRt`, `Web*`, `Orbital`, `OhosNdk`, `Haiku`.

### What each toolkit host must provide

| kaya backend | handle | how wgpu consumes it | what the host must supply |
| --- | --- | --- | --- |
| **SwiftUI / macOS** | `RawWindowHandle::AppKit { ns_view }` (or `SurfaceTargetUnsafe::CoreAnimationLayer`) | `wgpu-hal/src/metal/mod.rs:164-186` matches `(RawDisplayHandle::AppKit, RawWindowHandle::AppKit)` and calls `raw_window_metal::Layer::from_ns_view(handle.ns_view)`, then `Surface::new(layer)` over a `CAMetalLayer` | an `NSView` reachable from SwiftUI — i.e. an `NSViewRepresentable`. wgpu **installs a `CAMetalLayer` into that view's layer tree**. Size, `contentsScale` and the resize/appearance callbacks are the host's; surface creation must be on the **main thread** (documented panic) |
| **SwiftUI / iOS** | `RawWindowHandle::UiKit { ui_view, .. }` | same arm, `raw_window_metal::Layer::from_ui_view(handle.ui_view)` (`metal/mod.rs:169-172`) | a `UIView` via `UIViewRepresentable`; same main-thread rule |
| **Compose / Android** | `RawWindowHandle::AndroidNdk { a_native_window }` | Vulkan or GLES backend from the `ANativeWindow*` | an `AndroidView` hosting a `SurfaceView` (or `TextureView`); `ANativeWindow_fromSurface` on the `Surface` the `SurfaceHolder` hands out; the host owns surfaceCreated/Changed/Destroyed and must tear the wgpu surface down on destroy |
| **WinUI 3** | `SurfaceTargetUnsafe::SwapChainPanel(panel_ptr)` | dx12 backend, since wgpu 0.18 | a `SwapChainPanel` (or `SwapChainPanel`-derived) element in the XAML tree, its `ISwapChainPanelNative` pointer, plus `CompositionScaleChanged` / `SizeChanged` to drive reconfiguration. The `HWND` route (`Win32WindowHandle`) also exists but WinUI 3 content is XAML islands, not child HWNDs, so the panel is the right target |
| **GTK4** | — | see §4; **there is no wgpu surface for a GTK widget.** GTK owns the surface, and a `GdkSurface` is not a window handle any backend accepts | — |

**[inference]** The asymmetry is the whole story: on four of the five
backends the toolkit will hand out a native surface/layer and wgpu can
present into it directly. GTK4 is the one that will not, because GSK
composites everything itself and the only currency it accepts is a
`GdkTexture`.

---

## §4 — GTK4: the whole option space, with what each costs and copies

### First, the fact that reorganises the question: what GTK 4.18 actually runs

`gsk/gskrenderer.c` on the `gtk-4-18` branch
(https://gitlab.gnome.org/GNOME/gtk/-/raw/gtk-4-18/gsk/gskrenderer.c)
lists the renderer candidates **in order**, at lines 704-719:

```c
static struct { GType (* get_renderer) (GdkSurface *surface); }
renderer_possibilities[] = {
  { get_renderer_for_display },       /* set on the display */
  { get_renderer_for_env_var },       /* GSK_RENDERER=... */
  { get_renderer_for_backend },       /* broadway */
  { get_renderer_for_vulkan },        /* #ifdef GDK_RENDERING_VULKAN */
  { get_renderer_for_gl },
  { get_renderer_for_vulkan_fallback },
  { get_renderer_for_gl_fallback },
  { get_renderer_fallback },          /* cairo */
};
```

and the two gates are explicit:

- `vulkan_supported_platform()` (lines 625-677) refuses Vulkan as the
  PRIMARY choice unless **the platform is Wayland** ("Not using Vulkan:
  platform is not Wayland", line 642), the physical device is **not**
  `VK_PHYSICAL_DEVICE_TYPE_CPU` ("Not using Vulkan: device is CPU", line
  662) and the Vulkan driver **exposes dmabuf formats** ("Not using
  Vulkan: no dmabuf support", line 671).
- `gl_supported_platform()` (lines 574-604) refuses GL as the PRIMARY
  choice when `glGetString(GL_RENDERER)` contains **`"llvmpipe"`**
  ("Not using GL: renderer is llvmpipe", line 599). As a *fallback* both
  gates are skipped (`as_fallback` returns TRUE early).
- GTK **4.18 removed the old GL renderer**: `GSK_RENDERER=gl` warns "The
  old GL renderer has been removed" and gives you the new one anyway
  (lines 495-499, 522-523). The surviving names are `broadway`, `cairo`,
  `opengl`/`ngl`/`gl` (all → `GSK_TYPE_GL_RENDERER`) and `vulkan`.
  `GSK_RENDERER` is documented at https://docs.gtk.org/gtk4/running.html.

So the modern default is **not** "Vulkan": it is *Vulkan on Wayland with a
real GPU that does dmabuf, otherwise the new GL (ngl) renderer, otherwise
cairo.* On X11 with a real GPU you get **ngl**, because Vulkan's primary
gate requires Wayland.

**And for kaya's own linux lane, both sessions land on ngl.** Measured in
the lane's image (§0): llvmpipe is present, no Vulkan ICD is. So on X11
Vulkan-primary is skipped (not Wayland), GL-primary is skipped
(llvmpipe), Vulkan-fallback fails (no ICD), and **GL-fallback wins →
the ngl renderer on llvmpipe**. On the headless-sway Wayland session the
same chain ends the same way. Nothing in `tools/` sets `GSK_RENDERER`, so
this is what runs today. **[inference]** — from the selection code plus
the measured package set; not from a GSK_DEBUG=renderer run, which would
be the one-command confirmation and is worth doing.

### What GSK does with each kind of texture — read off the code, not the blog

`gsk/gpu/gskglframe.c:74-124` (the **ngl** renderer's texture upload):

```c
if (GDK_IS_GL_TEXTURE (texture)) {
    if (gdk_gl_context_is_shared (GDK_GL_CONTEXT (gsk_gpu_frame_get_context (frame)),
                                  gdk_gl_texture_get_context (gl_texture))) {
        image = gsk_gl_image_new_for_texture (..., gdk_gl_texture_get_id (gl_texture), FALSE, ...);
        sync = gdk_gl_texture_get_sync (gl_texture);
        if (sync) glWaitSync (sync, 0, GL_TIMEOUT_IGNORED);
        return image;                       /* <-- the GL name is used as-is */
    }
} else if (GDK_IS_DMABUF_TEXTURE (texture)) {
    tex_id = gdk_gl_context_import_dmabuf (...);   /* EGLImage import */
    if (tex_id) return gsk_gl_image_new_for_texture (..., tex_id, TRUE, ...);
}
return GSK_GPU_FRAME_CLASS (parent)->upload_texture (...);   /* -> NULL -> CPU path */
```

`gsk/gpu/gskvulkanframe.c:162-223` (the **Vulkan** renderer's):

```c
#ifdef HAVE_DMABUF
  if (GDK_IS_GL_TEXTURE (texture)) {
      if (gdk_gl_context_is_shared (glcontext, gdk_gl_texture_get_context (gltexture))) {
          gdk_gl_context_make_current (glcontext);
          if (gdk_gl_context_export_dmabuf (..., gdk_gl_texture_get_id (gltexture), &dmabuf)) {
              image = gsk_vulkan_image_new_for_dmabuf (...);   /* GL tex -> dmabuf -> VkImage */
              ...
          }
      }
  }
  if (GDK_IS_DMABUF_TEXTURE (texture)) {
      image = gsk_vulkan_image_new_for_dmabuf (...);
      ...
  }
#endif
  return GSK_GPU_FRAME_CLASS (parent)->upload_texture (...);
```

and the shared fallback: `gsk_gpu_frame_default_upload_texture` **returns
NULL** (`gsk/gpu/gskgpuframe.c:123-129`), after which
`gsk_gpu_frame_do_upload_texture` calls
`gsk_gpu_upload_texture_op_try (...)` (`gskgpuframe.c:493-494`) — the
generic path that goes through `gdk/gdktexturedownloaderprivate.h`, i.e.
**downloads the texture to CPU memory and re-uploads it.** For a
`GdkGLTexture`, that download is `gdk_gl_texture_download` →
`gdk_gl_context_download` (`gdk/gdkgltexture.c:155-196`), which makes the
owning context current and reads the pixels back.

**So, tabulated:**

| you hand GDK | under **ngl** | under **Vulkan** |
| --- | --- | --- |
| `GdkGLTexture` in a **shared** context | **zero copy** — the GL name is bound directly, with a `glWaitSync` on your fence | **zero copy IF** `gdk_gl_context_export_dmabuf` succeeds (EGL + `EXT_image_dma_buf_export`, Linux); **otherwise GPU→CPU→GPU round trip** |
| `GdkGLTexture` in an **unshared** context | GPU→CPU→GPU round trip | GPU→CPU→GPU round trip |
| `GdkDmabufTexture` | **zero copy** — `gdk_gl_context_import_dmabuf` (EGLImage) | **zero copy** — imported as a `VkImage` |
| `GdkMemoryTexture` | one upload per changed frame | one upload per changed frame |

The GTK blog's often-quoted line — "GtkGLArea and GtkMediaStream
currently both produce GL textures that the Vulkan renderer can't
directly import" (https://blog.gtk.org/2024/01/28/new-renderers-for-gtk/,
the 4.13.6/4.14 announcement) — **is dated**: 4.18's
`gsk_vulkan_frame_upload_texture` has the dmabuf-export bridge above.
What survives of it is the shape: the Vulkan renderer's route to a GL
texture goes *through dmabuf*, so on a driver/stack where the export
fails, you are back to a copy.

### The five options, priced

**(i) `GtkGLArea` + wgpu's GL backend adopting GTK's `GdkGLContext`.**

- The mechanism exists and is public:
  `wgpu_hal::gles::Adapter::new_external(fun: impl FnMut(&str) -> *const c_void, options: GlBackendOptions) -> Option<ExposedAdapter<Api>>`
  (https://docs.rs/wgpu-hal/latest/wgpu_hal/gles/struct.Adapter.html).
  Its body is `glow::Context::from_loader_function(fun)` with
  `AdapterContext { glow, egl: None }`
  (`wgpu-hal/src/gles/egl.rs:1080-1094`) — **it adopts whatever context is
  current and never touches EGL itself**, so an EGL-created *or*
  GLX-created GTK context both work as far as wgpu is concerned; you just
  need a working symbol loader (`eglGetProcAddress` / `glXGetProcAddress`
  / `dlsym`). A separate WGL implementation exists for Windows
  (`wgpu-hal/src/gles/wgl.rs:617-634`, added in wgpu 23.0.0, CHANGELOG
  PR #6152). Introduced in **wgpu 0.13 (2022-06-30)**, "Support externally
  initialized contexts", PR #2350; `AdapterContext` made public in
  0.13.2, PR #2870.
- Its safety contract is the awkward part, quoted verbatim: "The
  underlying OpenGL ES context must be current." / "…must be current when
  interfacing with any objects returned by wgpu-hal from this adapter." /
  "…must be current when dropping this adapter and when dropping any
  objects returned from this adapter." **[inference]** In a GTK app that
  means every wgpu call must be sandwiched in `gdk_gl_context_make_current`
  and the device must be dropped inside one too — doable, but it makes
  wgpu's lifetime GTK's problem.
- **The hole: wgpu cannot render into GTK's framebuffer.** `GtkGLArea`
  binds its own non-zero FBO before the `render` signal
  (`gtk/gtkglarea.c:57-58`: "creates a custom GL framebuffer that the
  widget will do GL rendering onto … ensures that this framebuffer is the
  default GL rendering target when rendering"). wgpu-hal's GLES backend
  *has* the internal type for that — `TextureInner::ExternalNativeFramebuffer
  { inner: glow::NativeFramebuffer }`, documented "Render to a
  `glow::NativeFramebuffer`. Useful when the framebuffer to draw to has a
  non-zero framebuffer ID" (`wgpu-hal/src/gles/mod.rs:436-444`) — **but
  there is no public constructor for it.** A repo-wide search finds the
  variant only at its definition and in four consumer `match` arms
  (`mod.rs`, `queue.rs`, `device.rs`, `command.rs`); nothing in `egl.rs`,
  `wgl.rs`, `web.rs` or `emscripten.rs` builds one
  (`gh search code --repo gfx-rs/wgpu ExternalNativeFramebuffer`). So the
  practical shape is: wgpu renders into **its own** GL texture, and you
  then either (a) issue a raw `glBlitFramebuffer` into GTK's FBO from the
  `render` signal, or (b) skip `GtkGLArea` entirely and go to option (ii).
- Cost: one intra-GPU blit if you take (a). Not "zero-copy" in the strict
  sense, but no CPU touch and no bus transfer.
- Under the Vulkan renderer a `GtkGLArea` still works — GTK hands GSK a
  `GdkGLTexture` built with `GdkGLTextureBuilder` in the area's own
  context (`gtk/gtkglarea.c:487-495`, format
  `GDK_MEMORY_R8G8B8A8_PREMULTIPLIED`), which the Vulkan frame then
  dmabuf-exports per the table above.

**(ii) wgpu renders into a GL texture in a shared `GdkGLContext`, handed
to GDK as a `GdkGLTexture`.**

This is the route the reference implementation takes, and it is worth
copying almost verbatim. `gst-plugins-rs`'s `gtk4paintablesink`:

- asks **GDK** for the context — `gdk_display.create_gl_context()` then
  `realize()` then `make_current()`
  (https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs/-/raw/main/video/gtk4/src/sink/imp.rs,
  lines 1102-1131) — so the context is automatically in GDK's share
  group, which is exactly what `gdk_gl_context_is_shared` will later be
  asked about;
- then wraps that context for its own renderer, switching on the concrete
  GDK context type: `GdkX11GLContextEGL`, `GdkX11GLContextGLX`,
  `GdkWaylandGLContext`, `GdkMacosGLContext`, `GdkWin32GLContextWGL`,
  `GdkWin32GLContextEGL` (`imp.rs:1185-1197`) — note **macOS and Windows
  are in that list**, so the GL-texture route is not Linux-only;
- and per frame builds the texture:
  ```rust
  gdk::GLTextureBuilder::new()
      .set_context(Some(gdk_context))
      .set_id(texture_id as u32)
      .set_width(w).set_height(h)
      .set_format(format)
      .set_sync(Some(sync_point))
      .build_with_release_func(move || drop(frame))
  ```
  (`video/gtk4/src/sink/frame.rs:511-539`). The `set_sync` is the GL fence
  GSK will `glWaitSync` on (`gskglframe.c:96-98`), and
  `build_with_release_func` is how the producer learns GTK is done with
  the texture.
- `GdkGLTextureBuilder` is **since 4.12**, `set_format` defaults to
  `GDK_MEMORY_R8G8B8A8_PREMULTIPLIED`, and `set_id`'s contract is "The
  texture id must remain unmodified until the texture was finalized"
  (https://docs.gtk.org/gdk4/class.GLTextureBuilder.html). The older
  `gdk_gl_texture_new` is **deprecated since 4.12**
  (https://docs.gtk.org/gdk4/class.GLTexture.html).
- Cost: **zero copy under ngl** (the GL name is bound directly);
  **zero copy under Vulkan only via the dmabuf export**, else a full
  round trip. You need one texture per in-flight frame (GTK holds the
  texture until it releases it), which is why the sink keeps a cache.
- The features `gtk4paintablesink` needs to make this work on Linux are
  named in its README: `waylandegl`, `x11glx` or `x11egl`; "On Windows and
  macOS this is enabled by default"
  (https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs/-/raw/main/video/gtk4/README.md).

**(iii) Export the wgpu (Vulkan) image as a dmabuf, build a
`GdkDmabufTexture`.**

- `GdkDmabufTextureBuilder`, "Constructs `GdkTexture` objects from DMA
  buffers", **since 4.14**
  (https://docs.gtk.org/gdk4/class.DmabufTextureBuilder.html). Up to four
  planes, each with fd/offset/stride, plus fourcc and modifier. The
  reference use is `video_frame_to_dmabuf_texture` in
  `video/gtk4/src/sink/frame.rs:566-625`.
- This is the **only route that is zero-copy under BOTH renderers** (the
  table above): ngl imports it as an EGLImage, Vulkan imports it as a
  `VkImage`.
- What it costs: **Linux only**, and it needs the exporting API to
  actually export. From wgpu that means the **Vulkan backend** plus
  `VK_KHR_external_memory_fd` + `VK_EXT_image_drm_format_modifier`, which
  wgpu does not wrap — you would reach through `Device::as_hal::<Vulkan>()`
  and drive the raw `ash` calls yourself. **[inference]** That is real
  work and it is the part nobody's blog post covers; GStreamer gets its
  dmabufs from the *decoder*, not from a renderer it wrote.
- X11: `GdkDmabufTexture` works on X11 too — the ngl path imports through
  EGL, which is display-server agnostic — but **graphics offload (iv) is
  Wayland-only**, so on X11 you get the import without the passthrough.

**(iv) `GtkGraphicsOffload`.**

- "Bypasses gsk rendering by passing the content of its child directly to
  the compositor", **since 4.14**
  (https://docs.gtk.org/gtk4/class.GraphicsOffload.html). It "only
  operates on Linux with Wayland", wants "dmabuf textures (see
  `GdkDmabufTextureBuilder`)", and works best when "there are no controls
  drawn on top of the video content". `black-background` since 4.16.
  Debugging: `GDK_DEBUG=offload GDK_DEBUG=dmabuf`; and
  `GDK_DEBUG=force-offload` "Force graphics offload for all textures, even
  when slower. This allows to debug offloading in the absence of dmabufs"
  (https://docs.gtk.org/gtk4/running.html).
- **[inference]** For kaya this is a *modifier on top of (iii)*, not an
  option in its own right, and it is the wrong shape for a canvas that
  sits inside a widget tree with labels over it. It is the right shape for
  the Image widget's high-rate path (`docs/canvas-plan.md:2274-2276`,
  the ruling-16 arm), which is precisely the video case it was built for.

**(v) Readback into a `GdkMemoryTexture`.**

- This is what kaya already does, minus the GPU:
  `gdk::MemoryTexture::new(w, h, MemoryFormat::R8g8b8a8Premultiplied, bytes, stride)`
  at `crates/kaya/src/gtk.rs:8736-8742`.
- Cost with a GPU in front of it: the `copy_texture_to_buffer` +
  `map_async` sync point from §2, then GDK's own upload back to the GPU
  for compositing. Two crossings of the bus per frame.
- **[inference — arithmetic, not measured]** 1920×1080 RGBA8 = 8.29 MB.
  A `memcpy`-class copy at ~20 GB/s is ~0.4 ms; the GPU→CPU readback
  stall is the larger term and is what makes this unusable for animation
  but perfectly fine for a chart that re-rasters on data change
  (`docs/canvas-plan.md:176`). **It always works, on every GTK backend and
  every renderer, including llvmpipe under Xvfb.**

### The plain answer to "is zero-copy really not accessible on GTK without dmabuf?"

**No — zero-copy IS reachable without dmabuf, but only under GTK's GL
renderer, and only if you get your context from GDK.** `gskglframe.c`
binds a `GdkGLTexture`'s GL name directly when
`gdk_gl_context_is_shared()` says the texture's context shares with the
renderer's, with no copy and no import; that is the ngl renderer, which is
what GTK runs on X11 everywhere, on Wayland without a Vulkan-capable GPU,
and in kaya's own container. Under the **Vulkan** renderer — GTK's choice
on Wayland with a real GPU — the only zero-copy door is dmabuf, because
`gskvulkanframe.c` reaches a GL texture solely by exporting it to a dmabuf
first; if that export fails, GDK downloads and re-uploads. So "no dmabuf"
does not mean "no zero-copy"; it means "no zero-copy on the configuration
most desktop Wayland users will be running."

---

## §1 AMENDMENT — the determinism picture, sharpened

After writing §1 I read vello's test-generation macro, and it makes the
determinism answer **much better than the example comment alone
suggests.** Both halves belong on the record.

`vello_tests/vello_dev_macros/src/test.rs` generates, for **every** test
function, one test per SIMD level crossed with both pipelines:

```
{name}_cpu_u8_scalar   {name}_cpu_f32_scalar
{name}_cpu_u8_neon     {name}_cpu_f32_neon
{name}_cpu_u8_sse2     {name}_cpu_f32_sse2
{name}_cpu_u8_sse42    {name}_cpu_f32_sse42
{name}_cpu_u8_avx2     {name}_cpu_f32_avx2
{name}_cpu_u8_avx512   {name}_cpu_f32_avx512
{name}_cpu_u8_wasm     {name}_cpu_f32_wasm
{name}_hybrid          {name}_hybrid_webgl   {name}_hybrid_no_depth
```

(lines 86-160), and every one of them is compared against **the same
single reference PNG** by `check_ref(..., threshold, diff_pixels, ...)`
(lines 724, 746). The defaults are **`cpu_u8_tolerance: 0`,
`hybrid_tolerance: 0`, `diff_pixels: 0`** (`test.rs:55-70`), and
`is_pix_diff` fires on `difference > threshold` over the three colour
channels (`vello_tests/tests/util.rs:650-662`). **Threshold 0 means exact
bytes.**

So the real statement is:

- **Across SIMD levels on one machine, vello_cpu is byte-exact by
  default** — that is what the whole corpus asserts, with a handful of
  named exceptions (`cpu_u8_tolerance = 1` on two blend tests in
  `mix.rs`; `diff_pixels = 2` on a gradient test whose comment blames
  "accumulated rounding errors"; `diff_pixels = 55` on a glyph test).
- **Across machines**, CI runs that same corpus on `windows-latest`,
  `macos-latest` and `ubuntu-latest` (`.github/workflows/ci.yml`, the
  `cargo test` matrix), so aarch64/NEON and x86_64/AVX2 agree with one
  set of references — though each host only runs the levels its own CPU
  has.
- **The example's caveat is about the residual risk, not about routine
  divergence**: `Level::fallback` "reduces the possibility of slight
  pixel differences when running on different platforms"
  (`vello_cpu/examples/basic.rs`). It is a hedge, and the two `diff_pixels`
  exceptions show it is not an empty one.
- **The CPU↔GPU comparison is the one that is genuinely tolerant**:
  `hybrid_tolerance` exists as a knob at all, `clip.rs` uses
  `hybrid_tolerance = 1`, `filter.rs` uses `hybrid_tolerance = 3`, and
  vello's own device probe uses `CHANNEL_TOLERANCE: u8 = 3`
  (`vello_common/src/probe.rs:43-44`).

**Net for kaya:** a `vello_cpu` swap can plausibly keep ONE frozen
`expect_drawing_hash` string across five aarch64 lanes, exactly as
tiny-skia does today — but the claim has to be *measured* on kaya's own
op stream before a hash is frozen, and the belt-and-braces move (pin
`Level::fallback()` and `num_threads: 0` for the canonical raster only,
while the on-screen raster runs `Level::new()` with threads) costs kaya
nothing, because §7.1's canonical raster is already a separate render
from the screen's.

---

## §5 — The harness under a GPU path: what stays byte-identical and what cannot

### What kaya freezes today

- `expect_drawing_hash` — FNV-1a over `width | height | pixels` of the
  **core's** raster at canonical scale 1.0 in canonical light mode
  (`crates/kaya/src/canvas.rs:574-598`). Zero tolerance.
- `expect_drawing` — op count plus normalized ink bounds
  (`docs/canvas-plan.md:1289-1296`).
- `expect_ink` — samples the **backend's rendered surface** at probe
  points, **±1 per channel**, ruled 2026-08-26 because a macOS window's
  backing store carries the display's colour profile (CLAUDE.md's
  check-verbs paragraph; `docs/canvas-plan.md` §7.2).

### The rule that already covers this, and it is in the tree

`docs/canvas-plan.md:2198-2205` (§15.3 lever 5) already worked it out:

> `expect_drawing_hash` is CPU-BY-DEFINITION: it rasterizes at the
> canonical scale with the canonical palette and hashes the CORE's
> buffer, so it is unaffected by what draws the screen. `expect_ink`
> samples the backend's own rendered surface, but only at centres of
> flat-filled regions (§7.2's inherited discipline), and a flat fill's
> interior is where two rasterizers agree even when their antialiasing
> does not.

and the honest cost, also already written down (`:2207-2217`): "Under a
GPU display path the hash observes a different thing from what the user
sees."

### What will and will not survive, item by item

| observable | CPU renderer (vello_cpu) | GPU display path | GPU **canonical** raster |
| --- | --- | --- | --- |
| `expect_drawing_hash` | survives as ONE frozen string, after a re-freeze; needs the Level/threads measurement | **unaffected** — it never reads the screen | **dies.** Would need a per-vendor/per-driver baseline |
| `expect_drawing` (ops + normalized ink) | survives; ink bounds are read off pixels (`canvas.rs:600+`), so a sub-pixel AA change can move a bound by one hundredth | survives | survives |
| `expect_ink` (±1/channel, flat interiors) | survives | **survives, and this is the load-bearing claim.** A flat interior is a constant colour; the places two rasterizers disagree are edges and AA coverage | survives |
| captures / looks | change once, reviewed once | change per vendor | change per vendor |

### Why a GPU canonical raster cannot be frozen (evidence, not assertion)

- The canvas plan's own reason 1 stands: Skia's developers describe GPU
  antialiasing as MSAA-or-analytic chosen per surface and per primitive,
  with path renderers gated on GPU features
  (`docs/canvas-plan.md:212-217`, citing
  https://groups.google.com/g/skia-discuss/c/OUzwQqxsCmo).
- The WebGPU spec itself concedes it: §2.2.2 "Machine-specific artifacts"
  — "There are some machine-specific rasterization/precision artifacts and
  performance differences that can be observed roughly in the same way as
  in WebGL" (https://www.w3.org/TR/webgpu/#rendering-operations).
- Vello, which controls both its CPU and GPU renderers and targets them at
  the same reference images, still needs a `hybrid_tolerance` knob
  (`vello_tests/vello_dev_macros/src/test.rs:24-25`) and a
  `CHANNEL_TOLERANCE: u8 = 3` in its device probe
  (`vello_common/src/probe.rs:43-44`).
- Both giants keep per-config goldens
  (`docs/canvas-plan.md:2013`: Chromium Gold and Flutter's
  `matchesGoldenFile`).

### The verification shape I would propose

1. **The CPU renderer stays the reference, always.** `expect_drawing_hash`
   keeps hashing `canvas::probe()`'s CPU raster
   (`crates/kaya/src/canvas.rs:574-581`); nothing about it changes when a
   GPU display path lands. That preserves invariant 6 (one byte-shared
   scene) at the only place it can be preserved.
2. **The GPU frame is verified against the CPU raster, not against a
   frozen string.** A new verb — call it `expect_drawing_matches
   <target> <max_channel_delta> <max_differing_fraction>` — renders the
   same op list through both paths on the machine under test and compares
   them with vello's own shape: a per-channel threshold plus an allowed
   differing-pixel count (`get_diff` in `vello_tests/tests/util.rs:551-590`
   is the model, and `is_pix_diff` at `:650-662` is the predicate). The
   numbers are ruled once and pinned by a gate the way `expect_ink`'s ±1
   is pinned in all three harnesses today.
   **[inference]** This is the only shape that catches "the GPU path drew
   something else entirely" while tolerating "the GPU path's AA is a
   shade different", and it is a read of two artifacts rather than of the
   model, so it satisfies §7.1's discipline.
3. **`expect_ink` is the thing that proves pixels reached the window**
   and it already tolerates ±1. Leave it exactly as is; it is the check
   that fails when the blit dropped (`docs/canvas-plan.md:1231-1233`).
4. **The Linux lane.** Two facts from §0 decide it: llvmpipe is present,
   lavapipe is not. So:
   - A **wgpu GL path** through llvmpipe would run in the container today
     with no Dockerfile change. `Backends::GL` at
     `Limits::downlevel_webgl2_defaults()` is what `vello_gpu`'s own WebGL
     example asks for, so `vello_hybrid` is the renderer that fits.
   - A **wgpu Vulkan path** needs one apt package —
     `mesa-vulkan-drivers` — which would also change what GSK does: with a
     lavapipe ICD present, `vulkan_supported_platform()` still refuses
     Vulkan as primary because the device is `VK_PHYSICAL_DEVICE_TYPE_CPU`
     (`gskrenderer.c:660-664`), so GSK stays on ngl. **[inference]** That
     is a happy accident: adding lavapipe for kaya's own renderer would
     not move GTK's renderer under the lane, so the lane's GTK behaviour
     would not change underneath the change.
   - Either way the lane's GPU is a software rasterizer, so **the lane can
     prove the GPU code path executes and agrees within tolerance; it
     cannot prove anything about a real driver.** That is the same honest
     limit as the x86_64-under-emulation half of the cross-ISA probe
     (`docs/canvas-plan.md:1276-1279`), and it should be written down the
     same way.
5. **`tools/check-canvas-blit.py` needs a new clause.** Today it holds
   "kaya rasterizes, backends blit" by forbidding backends from naming the
   op vocabulary (CLAUDE.md). A GPU display path introduces a second way
   to break the rule that nothing currently watches: **a backend
   acquiring its own device or renderer.** The clause: exactly one place
   creates the `wgpu::Instance`/`Device`, and the four backend arms may
   name a texture/surface handle but never a vello type.

---

## §6 — A build order in three slices

Costs use the roadmap's own calibration
(docs/canvas-gpu-plan.md §8):
S ≈ a day, M ≈ one to two, L ≈ two to four, XL ≈ four to seven. For
reference, that table records **Canvas itself as 3 days** (2026-08-26 to
08-28).

### Slice 1 — the `vello_cpu` swap · cost **M** (one to two days)

**The measurement that settles the unknown, first, before any code
moves:** a probe that renders kaya's own canvas op streams (the canvas
scene's figure, the portfolio chart, and one text-heavy drawing) at
canonical scale through vello_cpu 0.2.0 under the cross product
`Level::fallback() × Level::new()` × `num_threads ∈ {0, 2, 4}`, on the
mac natively and under x86_64 emulation, hashing each buffer. It answers
in one run: (a) is the output identical across SIMD levels, (b) does
thread count move a byte, (c) does the ISA. This is
`docs/measurements/canvas-cross-isa-2026-08-26.txt`'s successor and it
is the thing that decides whether the frozen hash stays one string.
**Half a day, and it is the whole risk.**

Then:

- `crates/kaya/Cargo.toml:27` — swap `tiny-skia` for `vello_cpu` (+
  `kurbo` comes with it).
- `crates/kaya/src/canvas.rs` — `rasterize()` (lines 463-570) and the
  glyph sink (lines 646-780). The mapping table in §1 is the whole diff.
  Keep harfrust + skrifa and keep feeding **paths**, so the text half of
  the hash does not change engine.
- `crates/kaya/src/canvas.rs:586-598` — `hash()` is unchanged; the
  **values** move, so every `expect_drawing_hash` string in
  `tools/scenes/*.steps` is re-frozen, plus a capture round
  (`docs/canvas-plan.md:201-207` already budgeted exactly this).
- **Watch the stroke.** kaya deliberately inherits tiny-skia's default
  joins/caps/miter (`canvas.rs:494-496`); `kurbo::Stroke`'s defaults are
  a different set. Either pin kaya's own values explicitly or accept a
  visible stroke change.
- **Free win to take in the same slice:** `aliasing_threshold: Option<u8>`
  is already in `vello_common`/`vello_cpu`
  (`vello_common/src/viewport.rs`, `vello_cpu/src/dispatch/mod.rs`), which
  is §15.3's lever 2 (the per-canvas aliasing knob) arriving as a prop
  rather than as work.
- **The guard this change needs** (CLAUDE.md's "every change names its
  guard"): the probe above, checked in as a measurement file, plus a
  `check-` clause that the canonical raster's `RenderSettings` are the
  pinned ones — a raster that silently started using `Level::new()` for
  the hash would go green on every aarch64 lane and red on the first
  x86_64 one, months later, which is exactly §7.1's stated failure mode.

### Slice 2 — a GPU path with readback, and kaya's device-or-CPU policy · cost **L** (two to four days)

**The measurement that settles the unknown, first:** at kaya's real canvas
sizes (the portfolio chart; 1600×1000 on the linux lane; a phone's
1200×2400 from `docs/canvas-plan.md:2163-2168`), time
(a) vello_cpu single-threaded, (b) vello_cpu multithreaded,
(c) vello_hybrid on wgpu **including** `copy_texture_to_buffer` +
`map_async` + de-pad. If (c) is not decisively faster than (b) at kaya's
sizes, **slice 2 should stop there and the answer is "vello_cpu with
threads, no GPU"** — which would be a good outcome, because it costs
nothing to maintain. §15.3's own table already shows 4-way band tiling
moving the failing phone frame from 171% of budget to 55%, before
vello_cpu's 5.3-17.8x multiplier.

If the GPU wins:

- `vello_hybrid 0.2.0` (renaming to `vello_gpu`), **not** classic `vello`:
  it needs `Features::empty()` and downlevel-WebGL2 limits
  (`vello_gpu/examples/*`), where classic vello demands
  `STORAGE_BINDING` render targets, i.e. compute
  (https://docs.rs/vello/latest/vello/struct.Renderer.html).
- New file, `crates/kaya/src/canvas/gpu.rs`: instance/adapter/device
  acquisition, a `RenderTargetConfig`, the readback. **One place owns the
  device**, which is also the gate clause from §5.
- The **device-or-CPU policy** is the design question, and the tree
  already has the shape for it: `vello_common::probe`
  (`vello_common/src/probe.rs`) renders a fixed scene of eight features
  and compares it to a bundled `probe.rgba` within
  `CHANNEL_TOLERANCE = 3`, returning `Probe::Success` / `Error` /
  `RenderError`. **[inference]** kaya should run exactly that at device
  acquisition and fall back to `vello_cpu` on anything but `Success` —
  that turns "does this driver draw correctly" into a measured answer
  rather than an allowlist, and it is a diagnostic that can only print
  what it measured (invariant 3).
- Env override: `KAYA_CANVAS_RENDERER=cpu|gpu` so a lane can pin either,
  and so the linux lane can assert both.
- The harness verb from §5(2), plus its numbers, plus the gate that pins
  them in all three harnesses (`tools/check-verbs.py`'s existing shape for
  the ±1 tolerance).
- `tools/linux/Dockerfile` — add `mesa-vulkan-drivers` **only** if the
  Vulkan backend is chosen; the GL backend needs nothing (llvmpipe is
  already there). Either way, re-run the lane and confirm GSK's renderer
  did not move (`GSK_DEBUG=renderer`).

### Slice 3 — zero-copy presentation, per backend · cost **XL** (four to seven days), and it is really five slices

This is the one that should be split by backend and landed depth-first,
because each backend is a different mechanism with a different host
requirement (§3's table). Order by cost-to-prove:

1. **macOS / SwiftUI — S-to-M.** `NSViewRepresentable` → `ns_view` →
   `raw_window_metal::Layer::from_ns_view` → wgpu Metal surface
   (`wgpu-hal/src/metal/mod.rs:164-186`). Everything is in-process, the
   toolkit gives you the layer, and the lane can see it. **The measurement
   first:** that a `CAMetalLayer` installed under a SwiftUI view honours
   `KayaRender`'s a11y wrapper and the appearance override
   (`tools/check-universal-props.py`, `tools/check-appearance.py` both have
   clauses that a new view layer could quietly bypass).
2. **iOS — S, once macOS is done.** Same file, `from_ui_view`.
3. **Windows / WinUI — M.** `SurfaceTargetUnsafe::SwapChainPanel`, dx12
   backend, supported since wgpu 0.18 (CHANGELOG, PR #4191). **The
   measurement first:** that a `SwapChainPanel` can be added to kaya's
   generated WinUI bindings at all — `crates/kaya/src/winui/bindings.rs` is
   generated by `tools/winui-bindgen`, and `ISwapChainPanelNative` is a
   COM interface, not a WinRT one, which is the kind of thing that turns
   a two-hour job into a day.
4. **Android / Compose — M.** `AndroidView` hosting a `SurfaceView`,
   `ANativeWindow_fromSurface`, `RawWindowHandle::AndroidNdk`. **The
   measurement first:** surface lifecycle under the lane's `remount-*`
   legs — Compose's mount is re-entrant by design
   (CLAUDE.md's check-appearance paragraph) and a wgpu surface that
   outlives its `SurfaceView` is a crash, not a red leg.
5. **GTK4 — L on its own, and the route is decided by one measurement.**
   Take option (ii): ask GDK for the context
   (`gdk_display.create_gl_context()` + `realize()` + `make_current()`,
   the `gtk4paintablesink` pattern at `video/gtk4/src/sink/imp.rs:1102-1131`),
   adopt it with `wgpu_hal::gles::Adapter::new_external`
   (`wgpu-hal/src/gles/egl.rs:1080-1094`), render into a GL texture, hand
   it over with `GdkGLTextureBuilder` + `set_sync` + `build_with_release_func`
   (`video/gtk4/src/sink/frame.rs:511-539`). **The measurement that
   settles it, and it is one afternoon:** build a probe that does exactly
   that inside the lane's container under both X11 and Wayland, print
   `GSK_DEBUG=renderer`, and confirm (a) wgpu's GLES adapter comes up on
   a GDK-created context at all — on X11 that context may be
   `GdkX11GLContextGLX` rather than EGL
   (`video/gtk4/src/sink/imp.rs:1186-1191`), and wgpu's gles backend is
   written against GL ES semantics — and (b) that GSK takes the
   zero-copy branch, which you can see because `gskglframe.c:83` gates on
   `gdk_gl_context_is_shared`. If (a) fails on GLX, force
   `gdk_gl_context_set_allowed_apis` to GLES (GTK ≥ 4.12) and re-measure.
   **Only if that fails does dmabuf (option iii) become necessary**, and
   that is a separate L: it means the Vulkan backend plus raw `ash` calls
   through `Device::as_hal::<Vulkan>()` for `VK_KHR_external_memory_fd`
   and `VK_EXT_image_drm_format_modifier`, which wgpu does not wrap.
   The readback into `GdkMemoryTexture` (option v) is the fallback that
   always works and is what the lane would run if the probe says no.

**A note on ordering against the tree's own rules.** Slice 3 is a
`docs/canvas-plan.md` §0 ruling change — ruling 2 says "GPU rendering for
this buffer is refused ON PRINCIPLE" and ruling 14's lever 5 says a GPU
**display** path is "RESERVED, NOT PLANNED". Slice 2 and 3 together are
lever 5 being taken, which is the maintainer's call, not a design
inference; and slice 1 is lever 4 being taken, which ruling 14 already
describes as "a STANDING EVALUATION" rather than a new decision. So
**slice 1 needs no ruling; slices 2 and 3 do.**

---

## The answer to the maintainer's question, in one paragraph

No — zero-copy on GTK4 is reachable without dmabuf, but only on GTK's
OpenGL renderer, and the door is narrower than "hand GDK a GL texture".
GSK's GL renderer binds a `GdkGLTexture`'s texture name straight into its
own frame, with nothing copied and nothing imported, on exactly one
condition: `gdk_gl_context_is_shared()` must say the texture's context and
the renderer's context share a GL share group
(`gsk/gpu/gskglframe.c:79-101`). In practice that means you must get your
GL context *from GDK* — `gdk_display_create_gl_context()`, realize it, make
it current, and then tell wgpu to adopt it with
`wgpu_hal::gles::Adapter::new_external` — which is precisely what
GStreamer's `gtk4paintablesink` does. GSK's **Vulkan** renderer has no
such door: its only route to a GL texture is to export it as a dmabuf
first (`gsk/gpu/gskvulkanframe.c:167-203`), and if that export fails, GDK
downloads the pixels and re-uploads them. So the real shape of the answer
is a conditional: on X11 (where GTK never picks Vulkan as its primary
renderer), on Wayland without a Vulkan-capable GPU, and inside kaya's own
linux container (llvmpipe, no Vulkan ICD at all — measured), GTK runs the
`ngl` renderer and the GL-texture route is genuinely zero-copy; on Wayland
with a real GPU, GTK picks Vulkan and dmabuf is the only zero-copy
currency. Given that kaya's canvas re-rasters on data, scale and
appearance change rather than per frame (`docs/canvas-plan.md:176`), the
honest recommendation is to take the GL-texture route because it is a
day's work and it is testable on the lane, keep the `GdkMemoryTexture`
readback as the always-works fallback, and treat dmabuf as the Image
widget's business — which is where ruling 16 already put it
(`docs/canvas-plan.md:2274-2276`).

---

**Notes path:** this file (landed from the session's scratch directory, which dies on reboot).
