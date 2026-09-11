//! vello_cpu determinism probe: SIMD level x threads x ISA over kaya's own
//! canvas op streams, hashed with canvas.rs's FNV-1a. Beside it, the same
//! streams through tiny-skia 0.12.0 (kaya's rasterizer today) so the swap's
//! pixel change is measured rather than guessed.

use std::time::Instant;

use skrifa::instance::Size;
use skrifa::outline::{DrawSettings, OutlinePen};
use skrifa::{FontRef, MetadataProvider};
use vello_cpu::color::{AlphaColor, Srgb};
use vello_cpu::kurbo::{BezPath, Cap, Join, Point, Stroke};
use vello_cpu::peniko::Fill;
use vello_cpu::{Level, Pixmap, RenderContext, RenderSettings, Resources};

const FONT: &[u8] = include_bytes!("../sora-wght.ttf");

// ---- kaya's op vocabulary, palette and alignment codes (crates/kaya/src/canvas.rs) ----

#[derive(Clone, Copy, PartialEq)]
enum Paint {
    Series,
    SeriesFill,
    Grid,
    Axis,
    Ground,
}

fn rgba(p: Paint) -> (u8, u8, u8, u8) {
    let packed: u32 = match p {
        Paint::Series => 0x1C71D8FF,
        Paint::SeriesFill => 0x1C71D833,
        Paint::Grid => 0xE1E4EAFF,
        Paint::Axis => 0x4A5160FF,
        Paint::Ground => 0xFFFFFFFF,
    };
    (
        ((packed >> 24) & 0xFF) as u8,
        ((packed >> 16) & 0xFF) as u8,
        ((packed >> 8) & 0xFF) as u8,
        (packed & 0xFF) as u8,
    )
}

#[derive(Clone, Copy)]
enum Align {
    Start,
    Middle,
    End,
}
#[derive(Clone, Copy)]
enum Baseline {
    Alphabetic,
    Top,
    Middle,
    Bottom,
}

enum Op {
    MoveTo(f64, f64),
    LineTo(f64, f64),
    Close,
    Stroke { paint: Paint, width: f64 },
    Fill { paint: Paint, even_odd: bool },
    Font { size: f64, weight: f64 },
    Text { x: f64, y: f64, paint: Paint, align: Align, baseline: Baseline, text: String },
}

struct Drawing {
    name: &'static str,
    viewbox: (f64, f64),
    ops: Vec<Op>,
}

struct D(Vec<Op>);
impl D {
    fn m(&mut self, x: f64, y: f64) -> &mut Self {
        self.0.push(Op::MoveTo(x, y));
        self
    }
    fn l(&mut self, x: f64, y: f64) -> &mut Self {
        self.0.push(Op::LineTo(x, y));
        self
    }
    fn close(&mut self) -> &mut Self {
        self.0.push(Op::Close);
        self
    }
    fn polyline(&mut self, pts: &[(f64, f64)]) -> &mut Self {
        for (i, (x, y)) in pts.iter().enumerate() {
            if i == 0 {
                self.m(*x, *y);
            } else {
                self.l(*x, *y);
            }
        }
        self
    }
    fn stroke(&mut self, paint: Paint, width: f64) -> &mut Self {
        self.0.push(Op::Stroke { paint, width });
        self
    }
    fn fill(&mut self, paint: Paint) -> &mut Self {
        self.0.push(Op::Fill { paint, even_odd: false });
        self
    }
    fn font(&mut self, size: f64, weight: f64) -> &mut Self {
        self.0.push(Op::Font { size, weight });
        self
    }
    fn text(&mut self, x: f64, y: f64, t: &str, paint: Paint, align: Align, baseline: Baseline) -> &mut Self {
        self.0.push(Op::Text { x, y, paint, align, baseline, text: t.to_string() });
        self
    }
}

/// guests/rust/canvas.rs, op for op.
fn canvas_figure() -> Drawing {
    let (l, t, r, b) = (40.0, 10.0, 290.0, 100.0);
    let series = [(40.0, 88.0), (81.0, 74.0), (123.0, 80.0), (165.0, 51.0), (206.0, 57.0), (248.0, 30.0), (290.0, 20.0)];
    let ticks = [(32.0, "$60k"), (55.0, "$40k"), (78.0, "$20k")];
    let mut d = D(Vec::new());
    d.m(l, t).l(r, t).l(r, b).l(l, b).close().fill(Paint::Ground);
    for (y, _) in ticks {
        d.m(l, y).l(r, y);
    }
    d.stroke(Paint::Grid, 1.0);
    d.polyline(&series).l(r, b).l(l, b).close().fill(Paint::SeriesFill);
    d.polyline(&series).stroke(Paint::Series, 2.0);
    d.m(l, t).l(l, b).stroke(Paint::Axis, 1.0);
    d.font(11.0, 400.0);
    for (y, text) in ticks {
        d.text(l - 4.0, y, text, Paint::Axis, Align::End, Baseline::Middle);
    }
    d.font(13.0, 700.0);
    d.text(l + 8.0, t + 3.0, "Q3", Paint::Series, Align::Start, Baseline::Top);
    Drawing { name: "canvas figure (41 ops)", viewbox: (300.0, 120.0), ops: d.0 }
}

/// guests/python/portfolio.py's draw_chart, with a deterministic synthetic
/// 90-day series in place of the CSV (the shapes and counts are the point).
fn portfolio_chart() -> Drawing {
    let (left, top, right, bottom) = (44.0, 12.0, 274.0, 150.0);
    let n = 90usize;
    let mut v: Vec<f64> = Vec::with_capacity(n);
    let mut seed: u64 = 0x9E37_79B9_7F4A_7C15;
    let mut value = 61_250.0_f64;
    for _ in 0..n {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        let step = ((seed % 2001) as f64 - 1000.0) / 10.0;
        value += step;
        v.push(value);
    }
    let (lo, hi) = v.iter().fold((f64::MAX, f64::MIN), |(a, b), x| (a.min(*x), b.max(*x)));
    let floor = (lo / 1000.0).floor() * 1000.0;
    let ceiling = (hi / 1000.0).ceil() * 1000.0;
    let step = 1000.0;
    let x_at = |i: usize| left + (right - left) * i as f64 / (n - 1) as f64;
    let y_at = |c: f64| bottom - (bottom - top) * (c - floor) / (ceiling - floor);
    let points: Vec<(f64, f64)> = v.iter().enumerate().map(|(i, c)| (x_at(i), y_at(*c))).collect();
    let mut grid = Vec::new();
    let mut g = floor;
    while g <= ceiling {
        grid.push(g);
        g += step;
    }
    let mut d = D(Vec::new());
    d.m(left, top).l(right, top).l(right, bottom).l(left, bottom).close().fill(Paint::Ground);
    for c in &grid {
        d.m(left, y_at(*c)).l(right, y_at(*c));
    }
    d.stroke(Paint::Grid, 1.0);
    d.polyline(&points).l(right, bottom).l(left, bottom).close().fill(Paint::SeriesFill);
    d.polyline(&points).stroke(Paint::Series, 1.5);
    d.m(left, top).l(left, bottom).l(right, bottom).stroke(Paint::Axis, 1.0);
    let mark = 2.5;
    let (px, py) = points[n - 1];
    let x = px.max(left + mark).min(right - mark);
    let y = py.max(top + mark).min(bottom - mark);
    d.m(x - mark, y - mark).l(x + mark, y - mark).l(x + mark, y + mark).l(x - mark, y + mark).close().fill(Paint::Series);
    d.font(9.0, 400.0);
    for c in &grid {
        d.text(left - 4.0, y_at(*c), &format!("${}", (*c as i64) / 100), Paint::Axis, Align::End, Baseline::Middle);
    }
    d.text(left, bottom + 5.0, "2026-06-12", Paint::Axis, Align::Start, Baseline::Top);
    d.text(right, bottom + 5.0, "2026-09-10", Paint::Axis, Align::End, Baseline::Top);
    let count = d.0.len();
    Drawing { name: Box::leak(format!("portfolio chart ({count} ops)").into_boxed_str()), viewbox: (280.0, 180.0), ops: d.0 }
}

/// Fourteen text runs at fourteen sizes and weights: the curve-heavy case.
fn text_page() -> Drawing {
    let mut d = D(Vec::new());
    d.m(0.0, 0.0).l(400.0, 0.0).l(400.0, 300.0).l(0.0, 300.0).close().fill(Paint::Ground);
    let mut y = 6.0;
    for i in 0..14 {
        let size = 8.0 + i as f64;
        let weight = 300.0 + (i % 6) as f64 * 100.0;
        d.font(size, weight);
        let (x, align) = match i % 3 {
            0 => (8.0, Align::Start),
            1 => (200.0, Align::Middle),
            _ => (392.0, Align::End),
        };
        let paint = if i % 2 == 0 { Paint::Axis } else { Paint::Series };
        d.text(x, y, "The quick brown fox jumps over the lazy dog 0123456789", paint, align, Baseline::Top);
        y += size * 1.4;
    }
    let count = d.0.len();
    Drawing { name: Box::leak(format!("text page ({count} ops)").into_boxed_str()), viewbox: (400.0, 300.0), ops: d.0 }
}

// ---- text: harfrust shapes, skrifa outlines, as canvas.rs does ----

struct Line {
    cmds: Vec<Cmd>,
}
enum Cmd {
    M(f64, f64),
    L(f64, f64),
    Q(f64, f64, f64, f64),
    C(f64, f64, f64, f64, f64, f64),
    Z,
}

struct Sink {
    cmds: Vec<Cmd>,
    dx: f64,
    dy: f64,
}
impl Sink {
    fn at(&self, x: f32, y: f32) -> (f64, f64) {
        (f64::from(x) + self.dx, self.dy - f64::from(y))
    }
}
impl OutlinePen for Sink {
    fn move_to(&mut self, x: f32, y: f32) {
        let (x, y) = self.at(x, y);
        self.cmds.push(Cmd::M(x, y));
    }
    fn line_to(&mut self, x: f32, y: f32) {
        let (x, y) = self.at(x, y);
        self.cmds.push(Cmd::L(x, y));
    }
    fn quad_to(&mut self, cx: f32, cy: f32, x: f32, y: f32) {
        let (cx, cy) = self.at(cx, cy);
        let (x, y) = self.at(x, y);
        self.cmds.push(Cmd::Q(cx, cy, x, y));
    }
    fn curve_to(&mut self, cx0: f32, cy0: f32, cx1: f32, cy1: f32, x: f32, y: f32) {
        let (cx0, cy0) = self.at(cx0, cy0);
        let (cx1, cy1) = self.at(cx1, cy1);
        let (x, y) = self.at(x, y);
        self.cmds.push(Cmd::C(cx0, cy0, cx1, cy1, x, y));
    }
    fn close(&mut self) {
        self.cmds.push(Cmd::Z);
    }
}

fn outline(px: f64, weight: f64, text: &str, x: f64, y: f64, align: Align, baseline: Baseline) -> Line {
    let font = FontRef::new(FONT).expect("font");
    let location = font.axes().location([("wght", weight as f32)]);
    let size = Size::new(px as f32);
    let metrics = font.metrics(size, &location);
    let shaper_data = harfrust::ShaperData::new(&font);
    let instance = harfrust::ShaperInstance::from_variations(
        &font,
        [harfrust::Variation { tag: harfrust::Tag::new(b"wght"), value: weight as f32 }],
    );
    let shaper = shaper_data.shaper(&font).instance(Some(&instance)).build();
    let upem = f64::from(shaper.units_per_em().max(1));
    let mut buffer = harfrust::UnicodeBuffer::new();
    buffer.push_str(text);
    buffer.guess_segment_properties();
    let shaped = shaper.shape(buffer, harfrust::ShapeOptions::default());
    let per_unit = px / upem;
    let advance: f64 = shaped.glyph_positions().iter().map(|p| f64::from(p.x_advance) * per_unit).sum();
    let pen_x = match align {
        Align::Middle => x - advance / 2.0,
        Align::End => x - advance,
        Align::Start => x,
    };
    let ascent = f64::from(metrics.ascent);
    let descent = f64::from(metrics.descent).abs();
    let pen_y = match baseline {
        Baseline::Top => y + ascent,
        Baseline::Bottom => y - descent,
        Baseline::Middle => y + (ascent - descent) / 2.0,
        Baseline::Alphabetic => y,
    };
    let outlines = font.outline_glyphs();
    let mut sink = Sink { cmds: Vec::new(), dx: 0.0, dy: 0.0 };
    let mut cursor = pen_x;
    for (info, pos) in shaped.glyph_infos().iter().zip(shaped.glyph_positions()) {
        let glyph = outlines.get(skrifa::GlyphId::new(info.glyph_id)).expect("glyph");
        sink.dx = cursor + f64::from(pos.x_offset) * per_unit;
        sink.dy = pen_y - f64::from(pos.y_offset) * per_unit;
        let settings = DrawSettings::unhinted(size, &location);
        glyph.draw(settings, &mut sink).expect("draw");
        cursor += f64::from(pos.x_advance) * per_unit;
    }
    Line { cmds: sink.cmds }
}

// ---- the two rasterizers ----

struct Raster {
    width: u32,
    height: u32,
    pixels: Vec<u8>,
}

fn hash(r: &Raster) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    let mut eat = |bytes: &[u8]| {
        for b in bytes {
            h ^= u64::from(*b);
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
    };
    eat(&r.width.to_le_bytes());
    eat(&r.height.to_le_bytes());
    eat(&r.pixels);
    h
}

fn vello(d: &Drawing, level: Level, threads: u16) -> Raster {
    let (w, h) = (d.viewbox.0.round() as u16, d.viewbox.1.round() as u16);
    let mut ctx = RenderContext::new_with(w, h, RenderSettings { level, num_threads: threads });
    let mut path = BezPath::new();
    let mut face = (11.0, 400.0);
    let color = |p: Paint| {
        let (r, g, b, a) = rgba(p);
        AlphaColor::<Srgb>::from_rgba8(r, g, b, a)
    };
    for op in &d.ops {
        match op {
            Op::MoveTo(x, y) => path.move_to(Point::new(*x, *y)),
            Op::LineTo(x, y) => path.line_to(Point::new(*x, *y)),
            Op::Close => path.close_path(),
            Op::Stroke { paint, width } => {
                let built = std::mem::take(&mut path);
                ctx.set_paint(color(*paint));
                // tiny-skia's defaults, pinned: butt caps, miter joins, limit 4.
                ctx.set_stroke(Stroke::new(*width).with_caps(Cap::Butt).with_join(Join::Miter).with_miter_limit(4.0));
                ctx.stroke_path(&built);
            }
            Op::Fill { paint, even_odd } => {
                let built = std::mem::take(&mut path);
                ctx.set_paint(color(*paint));
                ctx.set_fill_rule(if *even_odd { Fill::EvenOdd } else { Fill::NonZero });
                ctx.fill_path(&built);
            }
            Op::Font { size, weight } => face = (*size, *weight),
            Op::Text { x, y, paint, align, baseline, text } => {
                let line = outline(face.0, face.1, text, *x, *y, *align, *baseline);
                let mut p = BezPath::new();
                for c in &line.cmds {
                    match *c {
                        Cmd::M(x, y) => p.move_to(Point::new(x, y)),
                        Cmd::L(x, y) => p.line_to(Point::new(x, y)),
                        Cmd::Q(cx, cy, x, y) => p.quad_to(Point::new(cx, cy), Point::new(x, y)),
                        Cmd::C(a, b, c2, d2, x, y) => p.curve_to(Point::new(a, b), Point::new(c2, d2), Point::new(x, y)),
                        Cmd::Z => p.close_path(),
                    }
                }
                ctx.set_paint(color(*paint));
                ctx.set_fill_rule(Fill::NonZero);
                ctx.fill_path(&p);
            }
        }
    }
    ctx.flush();
    let mut pixmap = Pixmap::new(w, h);
    ctx.render(&mut pixmap, &mut Resources::new());
    Raster { width: u32::from(w), height: u32::from(h), pixels: pixmap.data_as_u8_slice().to_vec() }
}

fn tiny(d: &Drawing) -> Raster {
    let (w, h) = (d.viewbox.0.round() as u32, d.viewbox.1.round() as u32);
    let mut pixmap = tiny_skia::Pixmap::new(w, h).unwrap();
    let mut builder = tiny_skia::PathBuilder::new();
    let mut face = (11.0, 400.0);
    let color = |p: Paint| {
        let (r, g, b, a) = rgba(p);
        tiny_skia::Color::from_rgba8(r, g, b, a)
    };
    for op in &d.ops {
        match op {
            Op::MoveTo(x, y) => builder.move_to(*x as f32, *y as f32),
            Op::LineTo(x, y) => builder.line_to(*x as f32, *y as f32),
            Op::Close => builder.close(),
            Op::Stroke { paint, width } => {
                let built = std::mem::replace(&mut builder, tiny_skia::PathBuilder::new());
                if let Some(path) = built.finish() {
                    let mut style = tiny_skia::Paint::default();
                    style.set_color(color(*paint));
                    style.anti_alias = true;
                    let stroke = tiny_skia::Stroke { width: *width as f32, ..Default::default() };
                    pixmap.stroke_path(&path, &style, &stroke, tiny_skia::Transform::identity(), None);
                }
            }
            Op::Fill { paint, even_odd } => {
                let built = std::mem::replace(&mut builder, tiny_skia::PathBuilder::new());
                if let Some(path) = built.finish() {
                    let mut style = tiny_skia::Paint::default();
                    style.set_color(color(*paint));
                    style.anti_alias = true;
                    let rule = if *even_odd { tiny_skia::FillRule::EvenOdd } else { tiny_skia::FillRule::Winding };
                    pixmap.fill_path(&path, &style, rule, tiny_skia::Transform::identity(), None);
                }
            }
            Op::Font { size, weight } => face = (*size, *weight),
            Op::Text { x, y, paint, align, baseline, text } => {
                let line = outline(face.0, face.1, text, *x, *y, *align, *baseline);
                let mut b = tiny_skia::PathBuilder::new();
                for c in &line.cmds {
                    match *c {
                        Cmd::M(x, y) => b.move_to(x as f32, y as f32),
                        Cmd::L(x, y) => b.line_to(x as f32, y as f32),
                        Cmd::Q(cx, cy, x, y) => b.quad_to(cx as f32, cy as f32, x as f32, y as f32),
                        Cmd::C(a, b2, c2, d2, x, y) => b.cubic_to(a as f32, b2 as f32, c2 as f32, d2 as f32, x as f32, y as f32),
                        Cmd::Z => b.close(),
                    }
                }
                if let Some(path) = b.finish() {
                    let mut style = tiny_skia::Paint::default();
                    style.set_color(color(*paint));
                    style.anti_alias = true;
                    pixmap.fill_path(&path, &style, tiny_skia::FillRule::Winding, tiny_skia::Transform::identity(), None);
                }
            }
        }
    }
    Raster { width: w, height: h, pixels: pixmap.take() }
}

fn diff(a: &Raster, b: &Raster) -> (usize, u8, usize) {
    assert_eq!(a.pixels.len(), b.pixels.len());
    let mut differing = 0usize;
    let mut max = 0u8;
    for (pa, pb) in a.pixels.chunks(4).zip(b.pixels.chunks(4)) {
        let mut any = false;
        for i in 0..4 {
            let d = pa[i].abs_diff(pb[i]);
            if d > 0 {
                any = true;
                max = max.max(d);
            }
        }
        if any {
            differing += 1;
        }
    }
    (differing, max, a.pixels.len() / 4)
}

fn median_ms(mut f: impl FnMut() -> Raster, n: usize) -> (Raster, f64) {
    let mut times = Vec::with_capacity(n);
    let mut last = None;
    for _ in 0..n {
        let t = Instant::now();
        let r = f();
        times.push(t.elapsed().as_secs_f64() * 1000.0);
        last = Some(r);
    }
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    (last.unwrap(), times[n / 2])
}

fn main() {
    let arch = std::env::consts::ARCH;
    let detected = Level::new();
    println!("arch {arch}; Level::new() = {detected:?}; available_parallelism = {}", std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0));
    let drawings = [canvas_figure(), portfolio_chart(), text_page()];
    let baseline = Level::baseline();
    println!("Level::baseline() = {baseline:?}; Level::fallback() = {:?}", Level::fallback());
    let levels = [("fallback", Level::fallback()), ("baseline", baseline), ("new", detected)];
    println!();
    println!("{:<28} {:<10} {:>7} {:>18} {:>9}", "drawing", "level", "threads", "hash", "ms");
    for d in &drawings {
        let mut hashes = Vec::new();
        for (lname, level) in &levels {
            for threads in [0u16, 2, 4] {
                let (r, ms) = median_ms(|| vello(d, *level, threads), 7);
                let h = hash(&r);
                hashes.push(h);
                println!("{:<28} {:<10} {:>7} {:>18x} {:>9.3}", d.name, lname, threads, h, ms);
            }
        }
        let agree = hashes.iter().all(|h| *h == hashes[0]);
        println!("{:<28} -> {}", d.name, if agree { "ALL NINE AGREE" } else { "DIVERGE" });
        let (t, tms) = median_ms(|| tiny(d), 7);
        let v = vello(d, Level::fallback(), 0);
        if let Ok(dir) = std::env::var("DUMP") {
            let stem = d.name.split(' ').next().unwrap();
            for (tag, r) in [("tiny", &t), ("vello", &v)] {
                let mut bytes = r.width.to_le_bytes().to_vec();
                bytes.extend_from_slice(&r.height.to_le_bytes());
                bytes.extend_from_slice(&r.pixels);
                std::fs::write(format!("{dir}/{stem}-{tag}.rgba"), bytes).unwrap();
            }
        }
        let (differing, max, total) = diff(&t, &v);
        println!(
            "{:<28} tiny-skia  {:>7} {:>18x} {:>9.3}   vs vello: {differing}/{total} pixels differ ({:.2}%), max channel delta {max}",
            d.name, "-", hash(&t), tms, 100.0 * differing as f64 / total as f64
        );
        println!();
    }
}
