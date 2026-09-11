//! Slice 2's opening measurement (docs/canvas-gpu-plan.md §8): at kaya's real
//! canvas sizes, vello_cpu on one thread, vello_cpu on the host's threads with
//! the context reused, and vello_hybrid on wgpu with and without the readback
//! to bytes. Same op streams as the determinism probe, fitted by kaya's own
//! uniform-fit rule; the hybrid's bytes compared to the CPU's.

use std::time::Instant;

use skrifa::instance::Size;
use skrifa::outline::{DrawSettings, OutlinePen};
use skrifa::{FontRef, MetadataProvider};
use vello_cpu::color::{AlphaColor, Srgb};
use vello_cpu::kurbo::{BezPath, Cap, Join, Point, Stroke};
use vello_cpu::peniko::Fill;
use vello_cpu::{Level, PixmapMut, RenderContext, RenderSettings, Resources};

const FONT: &[u8] = include_bytes!("../sora-wght.ttf");

#[derive(Clone, Copy, PartialEq)]
enum Paint { Series, SeriesFill, Grid, Axis, Ground }
fn color(p: Paint) -> AlphaColor<Srgb> {
    let packed: u32 = match p {
        Paint::Series => 0x1C71D8FF, Paint::SeriesFill => 0x1C71D833, Paint::Grid => 0xE1E4EAFF,
        Paint::Axis => 0x4A5160FF, Paint::Ground => 0xFFFFFFFF,
    };
    AlphaColor::<Srgb>::from_rgba8(((packed >> 24) & 0xFF) as u8, ((packed >> 16) & 0xFF) as u8, ((packed >> 8) & 0xFF) as u8, (packed & 0xFF) as u8)
}
#[derive(Clone, Copy)] enum Align { Start, Middle, End }
#[derive(Clone, Copy)] enum Baseline { Top, Middle }
enum Op {
    MoveTo(f64, f64), LineTo(f64, f64), Close,
    Stroke { paint: Paint, width: f64 }, Fill { paint: Paint },
    Font { size: f64, weight: f64 },
    Text { x: f64, y: f64, paint: Paint, align: Align, baseline: Baseline, text: String },
}
struct Drawing { name: String, viewbox: (f64, f64), ops: Vec<Op> }
struct D(Vec<Op>);
impl D {
    fn m(&mut self, x: f64, y: f64) -> &mut Self { self.0.push(Op::MoveTo(x, y)); self }
    fn l(&mut self, x: f64, y: f64) -> &mut Self { self.0.push(Op::LineTo(x, y)); self }
    fn close(&mut self) -> &mut Self { self.0.push(Op::Close); self }
    fn polyline(&mut self, pts: &[(f64, f64)]) -> &mut Self { for (i, (x, y)) in pts.iter().enumerate() { if i == 0 { self.m(*x, *y); } else { self.l(*x, *y); } } self }
    fn stroke(&mut self, paint: Paint, width: f64) -> &mut Self { self.0.push(Op::Stroke { paint, width }); self }
    fn fill(&mut self, paint: Paint) -> &mut Self { self.0.push(Op::Fill { paint }); self }
    fn font(&mut self, size: f64, weight: f64) -> &mut Self { self.0.push(Op::Font { size, weight }); self }
    fn text(&mut self, x: f64, y: f64, t: &str, paint: Paint, align: Align, baseline: Baseline) -> &mut Self { self.0.push(Op::Text { x, y, paint, align, baseline, text: t.to_string() }); self }
}

fn portfolio_chart() -> Drawing {
    let (left, top, right, bottom) = (44.0, 12.0, 274.0, 150.0);
    let n = 90usize; let mut v = Vec::with_capacity(n); let mut seed: u64 = 0x9E37_79B9_7F4A_7C15; let mut value = 61_250.0_f64;
    for _ in 0..n { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; value += ((seed % 2001) as f64 - 1000.0) / 10.0; v.push(value); }
    let (lo, hi) = v.iter().fold((f64::MAX, f64::MIN), |(a, b), x| (a.min(*x), b.max(*x)));
    let floor = (lo / 1000.0).floor() * 1000.0; let ceiling = (hi / 1000.0).ceil() * 1000.0;
    let x_at = |i: usize| left + (right - left) * i as f64 / (n - 1) as f64;
    let y_at = |c: f64| bottom - (bottom - top) * (c - floor) / (ceiling - floor);
    let points: Vec<(f64, f64)> = v.iter().enumerate().map(|(i, c)| (x_at(i), y_at(*c))).collect();
    let mut grid = Vec::new(); let mut g = floor; while g <= ceiling { grid.push(g); g += 1000.0; }
    let mut d = D(Vec::new());
    d.m(left, top).l(right, top).l(right, bottom).l(left, bottom).close().fill(Paint::Ground);
    for c in &grid { d.m(left, y_at(*c)).l(right, y_at(*c)); }
    d.stroke(Paint::Grid, 1.0);
    d.polyline(&points).l(right, bottom).l(left, bottom).close().fill(Paint::SeriesFill);
    d.polyline(&points).stroke(Paint::Series, 1.5);
    d.m(left, top).l(left, bottom).l(right, bottom).stroke(Paint::Axis, 1.0);
    let mark = 2.5; let (px, py) = points[n - 1]; let x = px.max(left + mark).min(right - mark); let y = py.max(top + mark).min(bottom - mark);
    d.m(x - mark, y - mark).l(x + mark, y - mark).l(x + mark, y + mark).l(x - mark, y + mark).close().fill(Paint::Series);
    d.font(9.0, 400.0);
    for c in &grid { d.text(left - 4.0, y_at(*c), &format!("${}", (*c as i64) / 100), Paint::Axis, Align::End, Baseline::Middle); }
    d.text(left, bottom + 5.0, "2026-06-12", Paint::Axis, Align::Start, Baseline::Top);
    d.text(right, bottom + 5.0, "2026-09-10", Paint::Axis, Align::End, Baseline::Top);
    Drawing { name: format!("portfolio chart ({} ops)", d.0.len()), viewbox: (280.0, 180.0), ops: d.0 }
}
fn text_page() -> Drawing {
    let mut d = D(Vec::new());
    d.m(0.0, 0.0).l(400.0, 0.0).l(400.0, 300.0).l(0.0, 300.0).close().fill(Paint::Ground);
    let mut y = 6.0;
    for i in 0..14 {
        let size = 8.0 + i as f64; let weight = 300.0 + (i % 6) as f64 * 100.0;
        d.font(size, weight);
        let (x, align) = match i % 3 { 0 => (8.0, Align::Start), 1 => (200.0, Align::Middle), _ => (392.0, Align::End) };
        d.text(x, y, "The quick brown fox jumps over the lazy dog 0123456789", if i % 2 == 0 { Paint::Axis } else { Paint::Series }, align, Baseline::Top);
        y += size * 1.4;
    }
    Drawing { name: format!("text page ({} ops)", d.0.len()), viewbox: (400.0, 300.0), ops: d.0 }
}
/// docs/canvas-plan.md §15.2's headroom unit: 2000 moderate antialiased path fills.
fn octagons() -> Drawing {
    let mut d = D(Vec::new()); let mut seed: u64 = 0xA5A5_5A5A_1234_5678;
    d.m(0.0, 0.0).l(800.0, 0.0).l(800.0, 500.0).l(0.0, 500.0).close().fill(Paint::Ground);
    for i in 0..2000 {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17;
        let cx = (seed % 800) as f64; let cy = ((seed >> 20) % 500) as f64; let r = 4.0 + ((seed >> 40) % 9) as f64;
        for k in 0..8 { let a = std::f64::consts::TAU * k as f64 / 8.0 + 0.3; let (x, y) = (cx + r * a.cos(), cy + r * a.sin()); if k == 0 { d.m(x, y); } else { d.l(x, y); } }
        d.close().fill(if i % 3 == 0 { Paint::Series } else if i % 3 == 1 { Paint::SeriesFill } else { Paint::Axis });
    }
    Drawing { name: format!("2000 octagons ({} ops)", d.0.len()), viewbox: (800.0, 500.0), ops: d.0 }
}

// ---- text, as canvas.rs ----
struct Sink { path: BezPath, dx: f64, dy: f64 }
impl Sink { fn at(&self, x: f32, y: f32) -> Point { Point::new(f64::from(x) + self.dx, self.dy - f64::from(y)) } }
impl OutlinePen for Sink {
    fn move_to(&mut self, x: f32, y: f32) { let p = self.at(x, y); self.path.move_to(p); }
    fn line_to(&mut self, x: f32, y: f32) { let p = self.at(x, y); self.path.line_to(p); }
    fn quad_to(&mut self, cx: f32, cy: f32, x: f32, y: f32) { let c = self.at(cx, cy); let p = self.at(x, y); self.path.quad_to(c, p); }
    fn curve_to(&mut self, a: f32, b: f32, c: f32, d: f32, x: f32, y: f32) { let c0 = self.at(a, b); let c1 = self.at(c, d); let p = self.at(x, y); self.path.curve_to(c0, c1, p); }
    fn close(&mut self) { self.path.close_path(); }
}
fn outline(px: f64, weight: f64, text: &str, x: f64, y: f64, align: Align, baseline: Baseline) -> BezPath {
    let font = FontRef::new(FONT).unwrap(); let location = font.axes().location([("wght", weight as f32)]); let size = Size::new(px as f32);
    let metrics = font.metrics(size, &location); let shaper_data = harfrust::ShaperData::new(&font);
    let instance = harfrust::ShaperInstance::from_variations(&font, [harfrust::Variation { tag: harfrust::Tag::new(b"wght"), value: weight as f32 }]);
    let shaper = shaper_data.shaper(&font).instance(Some(&instance)).build(); let upem = f64::from(shaper.units_per_em().max(1));
    let mut buffer = harfrust::UnicodeBuffer::new(); buffer.push_str(text); buffer.guess_segment_properties();
    let shaped = shaper.shape(buffer, harfrust::ShapeOptions::default()); let per_unit = px / upem;
    let advance: f64 = shaped.glyph_positions().iter().map(|p| f64::from(p.x_advance) * per_unit).sum();
    let pen_x = match align { Align::Middle => x - advance / 2.0, Align::End => x - advance, Align::Start => x };
    let ascent = f64::from(metrics.ascent); let descent = f64::from(metrics.descent).abs();
    let pen_y = match baseline { Baseline::Top => y + ascent, Baseline::Middle => y + (ascent - descent) / 2.0 };
    let outlines = font.outline_glyphs(); let mut sink = Sink { path: BezPath::new(), dx: 0.0, dy: 0.0 }; let mut cursor = pen_x;
    for (info, pos) in shaped.glyph_infos().iter().zip(shaped.glyph_positions()) {
        let glyph = outlines.get(skrifa::GlyphId::new(info.glyph_id)).unwrap();
        sink.dx = cursor + f64::from(pos.x_offset) * per_unit; sink.dy = pen_y - f64::from(pos.y_offset) * per_unit;
        glyph.draw(DrawSettings::unhinted(size, &location), &mut sink).unwrap(); cursor += f64::from(pos.x_advance) * per_unit;
    }
    sink.path
}

/// One walk over the ops for either renderer, with kaya's uniform fit baked in.
trait Target { fn fill(&mut self, p: &BezPath, c: AlphaColor<Srgb>); fn stroke(&mut self, p: &BezPath, c: AlphaColor<Srgb>, w: f64); }
impl Target for RenderContext {
    fn fill(&mut self, p: &BezPath, c: AlphaColor<Srgb>) { self.set_paint(c); self.set_fill_rule(Fill::NonZero); self.fill_path(p); }
    fn stroke(&mut self, p: &BezPath, c: AlphaColor<Srgb>, w: f64) { self.set_paint(c); self.set_stroke(Stroke::new(w).with_caps(Cap::Butt).with_join(Join::Miter).with_miter_limit(4.0)); self.stroke_path(p); }
}
impl Target for vello_hybrid::Scene {
    fn fill(&mut self, p: &BezPath, c: AlphaColor<Srgb>) { self.set_paint(c); self.set_fill_rule(Fill::NonZero); self.fill_path(p); }
    fn stroke(&mut self, p: &BezPath, c: AlphaColor<Srgb>, w: f64) { self.set_paint(c); self.set_stroke(Stroke::new(w).with_caps(Cap::Butt).with_join(Join::Miter).with_miter_limit(4.0)); self.stroke_path(p); }
}
fn walk(d: &Drawing, track: (f64, f64), t: &mut impl Target) {
    let k = (track.0 / d.viewbox.0).min(track.1 / d.viewbox.1); let (dx, dy) = ((track.0 - d.viewbox.0 * k) / 2.0, (track.1 - d.viewbox.1 * k) / 2.0);
    let mut path = BezPath::new(); let mut face = (11.0, 400.0);
    for op in &d.ops {
        match op {
            Op::MoveTo(x, y) => path.move_to(Point::new(x * k + dx, y * k + dy)),
            Op::LineTo(x, y) => path.line_to(Point::new(x * k + dx, y * k + dy)),
            Op::Close => path.close_path(),
            Op::Stroke { paint, width } => { let b = std::mem::take(&mut path); t.stroke(&b, color(*paint), width * k); }
            Op::Fill { paint } => { let b = std::mem::take(&mut path); t.fill(&b, color(*paint)); }
            Op::Font { size, weight } => face = (*size, *weight),
            Op::Text { x, y, paint, align, baseline, text } => { let p = outline(face.0 * k, face.1, text, x * k + dx, y * k + dy, *align, *baseline); t.fill(&p, color(*paint)); }
        }
    }
}

fn median(mut v: Vec<f64>) -> f64 { v.sort_by(|a, b| a.partial_cmp(b).unwrap()); v[v.len() / 2] }
fn diff(a: &[u8], b: &[u8]) -> (usize, u8, f64) {
    let mut differing = 0usize; let mut max = 0u8; let n = a.len() / 4;
    for (pa, pb) in a.chunks(4).zip(b.chunks(4)) { let mut any = false; for i in 0..4 { let d = pa[i].abs_diff(pb[i]); if d > 0 { any = true; max = max.max(d); } } if any { differing += 1; } }
    (differing, max, 100.0 * differing as f64 / n as f64)
}

struct Gpu { device: wgpu::Device, queue: wgpu::Queue, adapter_name: String, backend: String }
fn gpu() -> Gpu {
    let instance = wgpu::Instance::default();
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions { power_preference: wgpu::PowerPreference::HighPerformance, force_fallback_adapter: false, compatible_surface: None })).expect("adapter");
    let info = adapter.get_info();
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor { label: Some("probe"), required_features: wgpu::Features::empty(), ..Default::default() })).expect("device");
    Gpu { device, queue, adapter_name: info.name, backend: format!("{:?}", info.backend) }
}

/// One hybrid frame: build the scene (CPU), render (GPU), then optionally read back de-padded bytes.
fn hybrid_frame(g: &Gpu, renderer: &mut vello_hybrid::Renderer, resources: &mut vello_hybrid::Resources, scene: &mut vello_hybrid::Scene, texture: &wgpu::Texture, view: &wgpu::TextureView, d: &Drawing, track: (f64, f64), w: u16, h: u16, readback: bool) -> (Option<Vec<u8>>, f64, f64) {
    let t0 = Instant::now();
    scene.reset(); walk(d, track, scene);
    let t_build = t0.elapsed().as_secs_f64() * 1000.0;
    let mut encoder = g.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
    renderer.render(scene, resources, &g.device, &g.queue, &mut encoder, &vello_hybrid::RenderSize { width: w.into(), height: h.into() }, view, &vello_hybrid::TextureBindings::new()).unwrap();
    if !readback {
        g.queue.submit([encoder.finish()]); g.device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
        return (None, t0.elapsed().as_secs_f64() * 1000.0, t_build);
    }
    let bytes_per_row = (u32::from(w) * 4).next_multiple_of(256);
    let buffer = g.device.create_buffer(&wgpu::BufferDescriptor { label: None, size: u64::from(bytes_per_row) * u64::from(h), usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ, mapped_at_creation: false });
    encoder.copy_texture_to_buffer(
        wgpu::TexelCopyTextureInfo { texture, mip_level: 0, origin: wgpu::Origin3d::ZERO, aspect: wgpu::TextureAspect::All },
        wgpu::TexelCopyBufferInfo { buffer: &buffer, layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(bytes_per_row), rows_per_image: None } },
        wgpu::Extent3d { width: w.into(), height: h.into(), depth_or_array_layers: 1 });
    g.queue.submit([encoder.finish()]);
    let slice = buffer.slice(..);
    slice.map_async(wgpu::MapMode::Read, |r| r.unwrap());
    g.device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
    let mut out = vec![0u8; usize::from(w) * usize::from(h) * 4];
    { let data = slice.get_mapped_range(); let row = usize::from(w) * 4; for y in 0..usize::from(h) { out[y * row..(y + 1) * row].copy_from_slice(&data[y * bytes_per_row as usize..y * bytes_per_row as usize + row]); } }
    buffer.unmap();
    (Some(out), t0.elapsed().as_secs_f64() * 1000.0, t_build)
}

fn breakdown() {
    let g = gpu();
    println!("BREAKDOWN of one vello_hybrid frame, median of 15 after 3 warm-ups; then a burst of 20 frames with ONE wait at the end");
    println!("{:<26} {:<16} {:>9} {:>9} {:>9} {:>9} {:>11} | {:>14} {:>12}", "drawing", "track", "strips", "encode", "submit", "wait", "frame", "burst/frame", "cpu MT ref");
    let threads = (std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).saturating_sub(1)).min(8) as u16;
    let drawings = [portfolio_chart(), text_page(), octagons()];
    let tracks: [(&str, (f64, f64)); 2] = [("native", (0.0, 0.0)), ("phone 1200x2400", (1200.0, 2400.0))];
    for d in &drawings {
        for (tname, track) in &tracks {
            let track = if *tname == "native" { d.viewbox } else { *track };
            let (w, h) = (track.0.round() as u16, track.1.round() as u16);
            let texture = g.device.create_texture(&wgpu::TextureDescriptor { label: None, size: wgpu::Extent3d { width: w.into(), height: h.into(), depth_or_array_layers: 1 }, mip_level_count: 1, sample_count: 1, dimension: wgpu::TextureDimension::D2, format: wgpu::TextureFormat::Rgba8Unorm, usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC, view_formats: &[] });
            let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
            let (mut renderer, mut resources) = vello_hybrid::Renderer::new(&g.device, &vello_hybrid::RenderTargetConfig { format: texture.format(), width: w.into(), height: h.into() });
            let mut scene = vello_hybrid::Scene::new_with(w, h, Level::new());
            let (mut ts, mut te, mut tsub, mut tw, mut tf) = (vec![], vec![], vec![], vec![], vec![]);
            for i in 0..18 {
                let t0 = Instant::now();
                scene.reset(); walk(d, track, &mut scene);
                let a = t0.elapsed().as_secs_f64() * 1000.0;
                let t1 = Instant::now();
                let mut encoder = g.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
                renderer.render(&scene, &mut resources, &g.device, &g.queue, &mut encoder, &vello_hybrid::RenderSize { width: w.into(), height: h.into() }, &view, &vello_hybrid::TextureBindings::new()).unwrap();
                let b = t1.elapsed().as_secs_f64() * 1000.0;
                let t2 = Instant::now();
                g.queue.submit([encoder.finish()]);
                let c = t2.elapsed().as_secs_f64() * 1000.0;
                let t3 = Instant::now();
                g.device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
                let dd = t3.elapsed().as_secs_f64() * 1000.0;
                if i >= 3 { ts.push(a); te.push(b); tsub.push(c); tw.push(dd); tf.push(t0.elapsed().as_secs_f64() * 1000.0); }
            }
            // BURST: 20 frames encoded and submitted back to back, one wait.
            let tb = Instant::now();
            for _ in 0..20 {
                scene.reset(); walk(d, track, &mut scene);
                let mut encoder = g.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
                renderer.render(&scene, &mut resources, &g.device, &g.queue, &mut encoder, &vello_hybrid::RenderSize { width: w.into(), height: h.into() }, &view, &vello_hybrid::TextureBindings::new()).unwrap();
                g.queue.submit([encoder.finish()]);
            }
            g.device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
            let burst = tb.elapsed().as_secs_f64() * 1000.0 / 20.0;
            // cpu MT reference, context reused
            let mut ctxm = RenderContext::new_with(w, h, RenderSettings { level: Level::new(), num_threads: threads });
            let mut bufm = vec![0u8; usize::from(w) * usize::from(h) * 4];
            let mut tm = Vec::new();
            for i in 0..18 { let t = Instant::now(); ctxm.reset(); walk(d, track, &mut ctxm); ctxm.flush(); ctxm.render(PixmapMut::new(w, h, &mut bufm).unwrap(), &mut Resources::new()); if i >= 3 { tm.push(t.elapsed().as_secs_f64() * 1000.0); } }
            println!("{:<26} {:<16} {:>7.2}ms {:>7.2}ms {:>7.2}ms {:>7.2}ms {:>9.2}ms | {:>12.2}ms {:>10.2}ms", d.name, tname, median(ts), median(te), median(tsub), median(tw), median(tf), burst, median(tm));
        }
    }
}

/// The fill-heavy case: `n` large overlapping quads, each covering about
/// 60% of the box, half of them the translucent series fill so every pixel
/// blends many times — the shape a GPU fine stage scales on.
fn big_fills(n: usize) -> Drawing {
    let mut d = D(Vec::new()); let mut seed: u64 = 0x1234_5678_9ABC_DEF1;
    d.m(0.0, 0.0).l(800.0, 0.0).l(800.0, 500.0).l(0.0, 500.0).close().fill(Paint::Ground);
    for i in 0..n {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17;
        let cx = 200.0 + (seed % 400) as f64; let cy = 120.0 + ((seed >> 20) % 260) as f64;
        let a = ((seed >> 40) % 360) as f64 * std::f64::consts::PI / 180.0;
        let (hw, hh) = (310.0, 190.0);
        for (k, (x, y)) in [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].iter().enumerate() {
            let (rx, ry) = (cx + x * a.cos() - y * a.sin(), cy + x * a.sin() + y * a.cos());
            if k == 0 { d.m(rx, ry); } else { d.l(rx, ry); }
        }
        d.close().fill(if i % 2 == 0 { Paint::SeriesFill } else if i % 4 == 1 { Paint::Grid } else { Paint::Series });
    }
    Drawing { name: format!("{n} big fills"), viewbox: (800.0, 500.0), ops: d.0 }
}

fn fills() {
    let g = gpu();
    let threads = (std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).saturating_sub(1)).min(8) as u16;
    println!("FILL-HEAVY FRAMES at phone size 1200x2400 (2.88 Mpx) and desk 1600x1000; median of 15 after 3 warm-ups; burst = 20 frames in flight, one wait");
    println!("{:<16} {:<16} {:>9} {:>9} {:>11} {:>13} {:>12}", "drawing", "track", "cpu 1T", "cpu MT", "gpu frame", "gpu burst/fr", "strips (cpu)");
    for n in [10usize, 50, 200, 800] {
        let d = big_fills(n);
        for (tname, track) in [("phone 1200x2400", (1200.0, 2400.0)), ("desk 1600x1000", (1600.0, 1000.0))] {
            let (w, h) = (track.0 as u16, track.1 as u16);
            let pixels = usize::from(w) * usize::from(h);
            let mut ctx1 = RenderContext::new_with(w, h, RenderSettings { level: Level::new(), num_threads: 0 });
            let mut buf = vec![0u8; pixels * 4]; let mut t1 = Vec::new();
            for i in 0..18 { let t = Instant::now(); ctx1.reset(); walk(&d, track, &mut ctx1); ctx1.flush(); ctx1.render(PixmapMut::new(w, h, &mut buf).unwrap(), &mut Resources::new()); if i >= 3 { t1.push(t.elapsed().as_secs_f64() * 1000.0); } }
            let mut ctxm = RenderContext::new_with(w, h, RenderSettings { level: Level::new(), num_threads: threads });
            let mut tm = Vec::new();
            for i in 0..18 { let t = Instant::now(); ctxm.reset(); walk(&d, track, &mut ctxm); ctxm.flush(); ctxm.render(PixmapMut::new(w, h, &mut buf).unwrap(), &mut Resources::new()); if i >= 3 { tm.push(t.elapsed().as_secs_f64() * 1000.0); } }
            let texture = g.device.create_texture(&wgpu::TextureDescriptor { label: None, size: wgpu::Extent3d { width: w.into(), height: h.into(), depth_or_array_layers: 1 }, mip_level_count: 1, sample_count: 1, dimension: wgpu::TextureDimension::D2, format: wgpu::TextureFormat::Rgba8Unorm, usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC, view_formats: &[] });
            let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
            let (mut renderer, mut resources) = vello_hybrid::Renderer::new(&g.device, &vello_hybrid::RenderTargetConfig { format: texture.format(), width: w.into(), height: h.into() });
            let mut scene = vello_hybrid::Scene::new_with(w, h, Level::new());
            let mut tf = Vec::new(); let mut ts = Vec::new();
            for i in 0..18 {
                let t0 = Instant::now(); scene.reset(); walk(&d, track, &mut scene); let a = t0.elapsed().as_secs_f64() * 1000.0;
                let mut encoder = g.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
                renderer.render(&scene, &mut resources, &g.device, &g.queue, &mut encoder, &vello_hybrid::RenderSize { width: w.into(), height: h.into() }, &view, &vello_hybrid::TextureBindings::new()).unwrap();
                g.queue.submit([encoder.finish()]); g.device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
                if i >= 3 { tf.push(t0.elapsed().as_secs_f64() * 1000.0); ts.push(a); }
            }
            let tb = Instant::now();
            for _ in 0..20 {
                scene.reset(); walk(&d, track, &mut scene);
                let mut encoder = g.device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
                renderer.render(&scene, &mut resources, &g.device, &g.queue, &mut encoder, &vello_hybrid::RenderSize { width: w.into(), height: h.into() }, &view, &vello_hybrid::TextureBindings::new()).unwrap();
                g.queue.submit([encoder.finish()]);
            }
            g.device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
            let burst = tb.elapsed().as_secs_f64() * 1000.0 / 20.0;
            println!("{:<16} {:<16} {:>7.2}ms {:>7.2}ms {:>9.2}ms {:>11.2}ms {:>10.2}ms", d.name, tname, median(t1), median(tm), median(tf), burst, median(ts));
        }
    }
}

fn main() {
    if std::env::args().nth(1).as_deref() == Some("breakdown") { breakdown(); return; }
    if std::env::args().nth(1).as_deref() == Some("fills") { fills(); return; }
    let threads = (std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).saturating_sub(1)).min(8) as u16;
    let g = gpu();
    println!("host: {} threads available; vello_cpu MT uses {threads}; Level::new() = {:?}; GPU adapter {:?} via {}", std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0), Level::new(), g.adapter_name, g.backend);
    let drawings = [portfolio_chart(), text_page(), octagons()];
    let tracks: [(&str, (f64, f64)); 3] = [("native", (0.0, 0.0)), ("desk 1600x1000", (1600.0, 1000.0)), ("phone 1200x2400", (1200.0, 2400.0))];
    println!();
    println!("{:<26} {:<16} {:>10} {:>9} {:>9} {:>11} {:>12} {:>9}   {}", "drawing", "track", "pixels", "cpu 1T", "cpu MT", "gpu render", "gpu+readback", "build", "hybrid vs cpu bytes");
    const N: usize = 15;
    for d in &drawings {
        for (tname, track) in &tracks {
            let track = if *tname == "native" { d.viewbox } else { *track };
            let (w, h) = (track.0.round() as u16, track.1.round() as u16);
            let pixels = usize::from(w) * usize::from(h);
            // vello_cpu, one thread, context reused
            let mut ctx1 = RenderContext::new_with(w, h, RenderSettings { level: Level::new(), num_threads: 0 });
            let mut buf1 = vec![0u8; pixels * 4];
            let mut t1 = Vec::new();
            for i in 0..N + 3 { let t = Instant::now(); ctx1.reset(); walk(d, track, &mut ctx1); ctx1.flush(); ctx1.render(PixmapMut::new(w, h, &mut buf1).unwrap(), &mut Resources::new()); if i >= 3 { t1.push(t.elapsed().as_secs_f64() * 1000.0); } }
            // vello_cpu, host threads, context reused (the pool amortized)
            let mut ctxm = RenderContext::new_with(w, h, RenderSettings { level: Level::new(), num_threads: threads });
            let mut bufm = vec![0u8; pixels * 4];
            let mut tm = Vec::new();
            for i in 0..N + 3 { let t = Instant::now(); ctxm.reset(); walk(d, track, &mut ctxm); ctxm.flush(); ctxm.render(PixmapMut::new(w, h, &mut bufm).unwrap(), &mut Resources::new()); if i >= 3 { tm.push(t.elapsed().as_secs_f64() * 1000.0); } }
            let mt_exact = buf1 == bufm;
            // vello_hybrid on wgpu
            let texture = g.device.create_texture(&wgpu::TextureDescriptor { label: None, size: wgpu::Extent3d { width: w.into(), height: h.into(), depth_or_array_layers: 1 }, mip_level_count: 1, sample_count: 1, dimension: wgpu::TextureDimension::D2, format: wgpu::TextureFormat::Rgba8Unorm, usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC, view_formats: &[] });
            let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
            let (mut renderer, mut resources) = vello_hybrid::Renderer::new(&g.device, &vello_hybrid::RenderTargetConfig { format: texture.format(), width: w.into(), height: h.into() });
            let mut scene = vello_hybrid::Scene::new_with(w, h, Level::new());
            let mut tg = Vec::new(); let mut tgr = Vec::new(); let mut tb = Vec::new(); let mut last = None;
            for i in 0..N + 3 { let (_, ms, b) = hybrid_frame(&g, &mut renderer, &mut resources, &mut scene, &texture, &view, d, track, w, h, false); if i >= 3 { tg.push(ms); tb.push(b); } }
            for i in 0..N + 3 { let (bytes, ms, _) = hybrid_frame(&g, &mut renderer, &mut resources, &mut scene, &texture, &view, d, track, w, h, true); if i >= 3 { tgr.push(ms); } last = bytes; }
            let (differing, max, pct) = diff(&buf1, last.as_ref().unwrap());
            println!("{:<26} {:<16} {:>10} {:>8.2}ms {:>8.2}ms {:>10.2}ms {:>11.2}ms {:>8.2}ms   {differing} px differ ({pct:.2}%), max delta {max}{}", d.name, tname, pixels, median(t1), median(tm), median(tg), median(tgr), median(tb), if mt_exact { "" } else { "  [MT bytes != 1T bytes]" });
        }
        println!();
    }
}
