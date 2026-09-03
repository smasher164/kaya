//! The canvas raster: validate the op stream, fold it into paths and
//! shaped text, resolve the paint roles, and hand out PIXELS. Every
//! backend's canvas arm is a blit; nothing below this module reaches a
//! platform (docs/canvas-plan.md §1.1, ruling 1).
//!
//! The refusals live here and nowhere else, which is the point: there is
//! one place that draws, so there is one place that can disagree.

use crate::protocol::Value;
use crate::wire;

use skrifa::MetadataProvider;
use skrifa::instance::Size;
use skrifa::outline::{DrawSettings, OutlinePen};
use skrifa::raw::FontRef;

/// Which palette a raster resolves its paint roles against. The ONLY
/// thing a platform contributes to a drawing (§6).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Light,
    Dark,
}

/// The scale and appearance a window is presenting at. Backends report
/// it; the core re-rasters (§5). `scale` is the TRUE scale, never the
/// rounded one — GTK is the backend that can hand back a fraction.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Presentation {
    pub scale: f64,
    pub mode: Mode,
}

impl Default for Presentation {
    fn default() -> Self {
        Presentation { scale: CANONICAL_SCALE, mode: Mode::Light }
    }
}

/// The scale and the appearance the §7.1 hash is taken at, pinned by the
/// verb rather than read from the lane's display: one frozen string on
/// five platforms needs every input to be one thing.
pub(crate) const CANONICAL_SCALE: f64 = 1.0;
pub(crate) const CANONICAL_MODE: Mode = Mode::Light;

/// `KAYA_APPEARANCE=light|dark`, the harness's per-process appearance, for
/// the two backends written in Rust.
///
/// UNSET RETURNS None AND NOTHING IS INSTALLED — the platform default, byte
/// for byte (tools/check-appearance.py's inert clause). A value that is
/// neither word panics rather than being ignored: a typo would otherwise
/// run a whole leg under the host's palette and freeze a wrong string.
///
/// This does NOT change what a backend REPORTS. Each backend installs the
/// override on its own toolkit and then reads that toolkit back as it
/// always did, so the report keeps coming from the platform rather than
/// from this variable — which is what makes the dark leg a real proof and
/// not a self-fulfilling one.
///
/// CFG'd TO ITS TWO CALLERS. gtk.rs and winui/mod.rs are the only users
/// and each compiles on one target, so on a mac host this is dead code
/// and rustc says so. NOT wired into the raster's mode selection, which
/// would be the same self-fulfilling defect the gate refuses: the core
/// takes its mode from the backend's presentation report, never from
/// this variable.
#[cfg(any(target_os = "windows", target_os = "linux"))]
pub(crate) fn appearance_override() -> Option<Mode> {
    let want = std::env::var("KAYA_APPEARANCE").ok()?;
    match want.as_str() {
        "light" => Some(Mode::Light),
        "dark" => Some(Mode::Dark),
        other => panic!("kaya: KAYA_APPEARANCE={other} is not a mode; use light or dark"),
    }
}

/// A validated drawing: the viewbox plus the op stream folded into a
/// form that cannot fail again. Held on the widget so a scale or
/// appearance change re-rasters without re-validating.
#[derive(Debug, Clone, PartialEq)]
pub struct Drawing {
    pub viewbox: (f64, f64),
    ops: Vec<Op>,
}

impl Drawing {
    /// How many ops the fold will replay — `expect_drawing`'s first
    /// field.
    pub fn op_count(&self) -> usize {
        self.ops.len()
    }
}

#[derive(Debug, Clone, PartialEq)]
enum Op {
    MoveTo(f64, f64),
    LineTo(f64, f64),
    Close,
    Stroke { paint: i64, width: f64 },
    Fill { paint: i64, even_odd: bool },
    Font { asset: String, size: f64, weight: f64 },
    Text { x: f64, y: f64, paint: i64, align: i64, baseline: i64, text: String },
}

/// What one canvas rasterized to. `pixels` is premultiplied RGBA8, the
/// layout the apply record carries and every backend blits.
pub struct Raster {
    pub width: u32,
    pub height: u32,
    pub scale: f64,
    pub pixels: Vec<u8>,
}

/// What the harness reads back: the canonical raster's fingerprint plus
/// the two legible facts. ONE answer for five platforms, computed in the
/// core, because a per-backend answer is exactly what the buffer exists
/// to remove (§7.1).
pub struct Probe {
    pub hash: u64,
    pub ops: usize,
    /// Ink bounds in hundredths of the canvas's own box, l/t/r/b. `None`
    /// when nothing reached a pixel.
    pub ink: Option<(i64, i64, i64, i64)>,
}

// ---------------------------------------------------------------------
// Validation (§3.5)
// ---------------------------------------------------------------------

/// Read the guest's flat op stream, refusing before anything draws. The
/// `Err` carries the whole sentence: the caller does not compose prose,
/// and a font asset the resolver cannot answer for raises the
/// RESOLVER'S OWN sentence rather than a second vocabulary for the same
/// failure (§3.5).
pub fn validate(viewbox: (f64, f64), stream: &[Value]) -> Result<Drawing, String> {
    let (vb_w, vb_h) = viewbox;
    for (which, n) in [("width", vb_w), ("height", vb_h)] {
        if !n.is_finite() || n <= 0.0 {
            return Err(format!(
                "kaya: a canvas viewbox {which} is {n}; a viewbox is the drawing's \
                 coordinate system AND its natural size, so both dimensions must be \
                 finite and positive"
            ));
        }
    }

    let mut ops = Vec::new();
    let mut at = 0usize;
    // A path is BUILT then PAINTED then cleared — the shape a path
    // rasterizer natively has — so a paint op with nothing built is a
    // refusal rather than a silent no-op.
    let mut subpath = false;
    let mut built = false;
    let mut font_selected = false;

    while at < stream.len() {
        let code = match &stream[at] {
            Value::I64(n) => *n,
            other => {
                return Err(format!(
                    "kaya: a canvas op stream is opcodes and operands; value {at} is \
                     {} where an opcode was expected",
                    shown(other)
                ));
            }
        };
        let name = wire::vocab_name(wire::DRAW_OPS, code).ok_or_else(|| {
            format!(
                "kaya: {code} is not a canvas opcode; the vocabulary is {}",
                vocabulary(wire::DRAW_OPS)
            )
        })?;
        let arity = match code {
            wire::DRAW_MOVE_TO | wire::DRAW_LINE_TO => 2,
            wire::DRAW_CLOSE => 0,
            wire::DRAW_STROKE => 2,
            wire::DRAW_FILL => 2,
            wire::DRAW_FONT => 3,
            wire::DRAW_TEXT => 6,
            _ => unreachable!("draw_op_name answered for {code}"),
        };
        if at + arity >= stream.len() {
            return Err(format!(
                "kaya: the canvas op `{name}` at value {at} takes {arity} operands and \
                 the stream ends after {}",
                stream.len() - at - 1
            ));
        }
        let operands = &stream[at + 1..=at + arity];
        at += arity + 1;

        match code {
            wire::DRAW_MOVE_TO => {
                let (x, y) = (coord(name, "x", &operands[0])?, coord(name, "y", &operands[1])?);
                ops.push(Op::MoveTo(x, y));
                subpath = true;
                built = true;
            }
            wire::DRAW_LINE_TO => {
                if !subpath {
                    return Err(
                        "kaya: a canvas `line_to` before any `move_to` has no point to \
                         extend from"
                            .to_owned(),
                    );
                }
                let (x, y) = (coord(name, "x", &operands[0])?, coord(name, "y", &operands[1])?);
                ops.push(Op::LineTo(x, y));
            }
            wire::DRAW_CLOSE => {
                if !subpath {
                    return Err(
                        "kaya: a canvas `close` with no open subpath closes nothing".to_owned()
                    );
                }
                ops.push(Op::Close);
                subpath = false;
            }
            wire::DRAW_STROKE | wire::DRAW_FILL => {
                // THE OPERANDS ARE READ BEFORE THE STATE IS CHECKED, so
                // the refusal below names the paint it was handed rather
                // than only what was missing (invariant 3: a diagnostic
                // prints what it measured).
                let paint = enum_operand(name, "paint", wire::PAINTS, &operands[0])?;
                let role = wire::vocab_name(wire::PAINTS, paint).unwrap_or("?");
                if code == wire::DRAW_STROKE {
                    let width = coord(name, "width", &operands[1])?;
                    if width <= 0.0 {
                        return Err(format!(
                            "kaya: a canvas stroke width is {width}; a width is in \
                             device-independent points and must be positive"
                        ));
                    }
                    if !built {
                        return Err(format!(
                            "kaya: a canvas `stroke` with paint `{role}` and width \
                             {width} has no path built — a drawing builds a path with \
                             move_to/line_to/close and then paints it, and the paint \
                             clears it"
                        ));
                    }
                    ops.push(Op::Stroke { paint, width });
                } else {
                    let rule = enum_operand(name, "fill rule", wire::FILL_RULES, &operands[1])?;
                    let spelled = wire::vocab_name(wire::FILL_RULES, rule).unwrap_or("?");
                    if !built {
                        return Err(format!(
                            "kaya: a canvas `fill` with paint `{role}` and rule \
                             `{spelled}` has no path built — a drawing builds a path \
                             with move_to/line_to/close and then paints it, and the \
                             paint clears it"
                        ));
                    }
                    ops.push(Op::Fill { paint, even_odd: rule == wire::FILL_EVEN_ODD });
                }
                subpath = false;
                built = false;
            }
            wire::DRAW_FONT => {
                let asset = string_operand(name, "asset", &operands[0])?;
                let size = coord(name, "size", &operands[1])?;
                if size <= 0.0 {
                    return Err(format!(
                        "kaya: a canvas font size is {size}; a size is in \
                         device-independent points and must be positive"
                    ));
                }
                let weight = match &operands[2] {
                    Value::I64(n) => *n as f64,
                    other => {
                        return Err(format!(
                            "kaya: a canvas font weight is {}, wanted a whole number",
                            shown(other)
                        ));
                    }
                };
                // The resolver answers for the reserved name and for the
                // app's own assets alike; its sentence is the one the
                // guest already knows.
                crate::assets::font_bytes(&asset)?;
                ops.push(Op::Font { asset, size, weight });
                font_selected = true;
            }
            wire::DRAW_TEXT => {
                if !font_selected {
                    return Err(
                        "kaya: a canvas `text` with no `font` selected — a text op draws \
                         with the face the last `font` op named, and there has not been \
                         one"
                            .to_owned(),
                    );
                }
                let x = coord(name, "x", &operands[0])?;
                let y = coord(name, "y", &operands[1])?;
                let paint = enum_operand(name, "paint", wire::PAINTS, &operands[2])?;
                let align = enum_operand(name, "align", wire::TEXT_ALIGNS, &operands[3])?;
                let baseline =
                    enum_operand(name, "baseline", wire::TEXT_BASELINES, &operands[4])?;
                let text = string_operand(name, "string", &operands[5])?;
                if text.contains('\n') || text.contains('\r') {
                    return Err(format!(
                        "kaya: the canvas text {text:?} carries a line break; a text op \
                         draws ONE LINE with its anchor at (x, y), and line breaking is a \
                         layout engine kaya's canvas deliberately does not have \
                         (docs/canvas-plan.md §3.3)"
                    ));
                }
                ops.push(Op::Text { x, y, paint, align, baseline, text });
            }
            _ => unreachable!("draw_op_name answered for {code}"),
        }
    }

    Ok(Drawing { viewbox, ops })
}

fn shown(v: &Value) -> String {
    match v {
        Value::Bool(b) => format!("the boolean {b}"),
        Value::I64(n) => format!("the whole number {n}"),
        Value::F64(n) => format!("the number {n}"),
        Value::Str(s) => format!("the string {s:?}"),
        Value::Blob(_) => "a blob".to_owned(),
    }
}

fn vocabulary(table: &[(i64, &str)]) -> String {
    table.iter().map(|(v, n)| format!("{n} ({v})")).collect::<Vec<_>>().join(", ")
}

/// An f64 operand that has to be a real number. i64 is accepted because
/// a guest writing `0` in a dynamically typed binding sends one.
fn coord(op: &str, which: &str, v: &Value) -> Result<f64, String> {
    let n = match v {
        Value::F64(n) => *n,
        Value::I64(n) => *n as f64,
        other => {
            return Err(format!(
                "kaya: the canvas op `{op}`'s {which} is {}, wanted a number",
                shown(other)
            ));
        }
    };
    if !n.is_finite() {
        return Err(format!(
            "kaya: the canvas op `{op}`'s {which} is {n}; a coordinate that is not \
             finite has no place on any raster"
        ));
    }
    Ok(n)
}

fn enum_operand(op: &str, which: &str, table: &[(i64, &str)], v: &Value) -> Result<i64, String> {
    let n = match v {
        Value::I64(n) => *n,
        other => {
            return Err(format!(
                "kaya: the canvas op `{op}`'s {which} is {}, wanted one of {}",
                shown(other),
                vocabulary(table)
            ));
        }
    };
    if table.iter().any(|(v, _)| *v == n) {
        Ok(n)
    } else {
        Err(format!(
            "kaya: {n} is not a canvas {which}; the vocabulary is {}",
            vocabulary(table)
        ))
    }
}

fn string_operand(op: &str, which: &str, v: &Value) -> Result<String, String> {
    match v {
        Value::Str(s) => Ok(s.clone()),
        other => Err(format!(
            "kaya: the canvas op `{op}`'s {which} is {}, wanted a string",
            shown(other)
        )),
    }
}

// ---------------------------------------------------------------------
// The palette (§6)
// ---------------------------------------------------------------------

/// kaya's own two-mode chart palette. Both platform vendors decline to
/// define a data-series role — Apple's semantic list and Material 3's
/// role vocabulary each have none — and every mainstream charting
/// library owns its palette, so this is the established answer rather
/// than an invention. It is also the only arrangement under which the
/// buffer is byte-identical per mode, which is what §7.1 rests on.
///
/// Packed as 0xRRGGBBAA.
const PALETTE_LIGHT: [(i64, u32); 5] = [
    (wire::PAINT_SERIES, 0x1C71D8FF),
    (wire::PAINT_SERIES_FILL, 0x1C71D833),
    (wire::PAINT_GRID, 0xE1E4EAFF),
    (wire::PAINT_AXIS, 0x4A5160FF),
    (wire::PAINT_GROUND, 0xFFFFFFFF),
];

const PALETTE_DARK: [(i64, u32); 5] = [
    (wire::PAINT_SERIES, 0x6EA8F0FF),
    (wire::PAINT_SERIES_FILL, 0x6EA8F01E),
    (wire::PAINT_GRID, 0x2C313AFF),
    (wire::PAINT_AXIS, 0xA9B1BFFF),
    (wire::PAINT_GROUND, 0x16181CFF),
];

fn resolve(paint: i64, mode: Mode) -> tiny_skia::Color {
    let table = match mode {
        Mode::Light => &PALETTE_LIGHT,
        Mode::Dark => &PALETTE_DARK,
    };
    // Validation already refused anything outside the vocabulary; the
    // fallback is unreachable and is spelled as ground rather than a
    // panic so a future role added to the spec draws SOMETHING while
    // check-verbs' fan-out is still open.
    let packed = table
        .iter()
        .find(|(role, _)| *role == paint)
        .map(|(_, c)| *c)
        .unwrap_or(0xFFFFFFFF);
    tiny_skia::Color::from_rgba8(
        ((packed >> 24) & 0xFF) as u8,
        ((packed >> 16) & 0xFF) as u8,
        ((packed >> 8) & 0xFF) as u8,
        (packed & 0xFF) as u8,
    )
}

// ---------------------------------------------------------------------
// The raster
// ---------------------------------------------------------------------

/// THE UNIFORM-FIT LETTERBOX (docs/canvas-plan.md §3.2.1, ruling 12):
/// where the viewbox lands inside a track, at ONE scale factor for both
/// axes, centred, with the leftover as margin. `k` multiplies positions,
/// stroke widths and font sizes alike — it is the SAME DRAWING at a new
/// size, which is what makes `scale` a re-raster rather than a stretch.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Fit {
    pub k: f64,
    pub ox: f64,
    pub oy: f64,
}

pub fn fit(viewbox: (f64, f64), track: (f64, f64)) -> Fit {
    let (vb_w, vb_h) = viewbox;
    let (t_w, t_h) = track;
    let k = (t_w / vb_w).min(t_h / vb_h);
    Fit { k, ox: (t_w - vb_w * k) / 2.0, oy: (t_h - vb_h * k) / 2.0 }
}

/// Rasterize the display list into a buffer `track` logical points across
/// at `p.scale` device pixels per point, with the viewbox fitted into it
/// uniformly and centred.
///
/// ONE SCALE FOR EVERYTHING, which is the correction ruling 12 made: the
/// superseded rule held stroke widths and font sizes at the device scale
/// alone so a non-uniform stretch could not produce an elliptical pen,
/// and under a uniform fit there is no such stretch to mitigate. Holding
/// the pen at 1pt while positions grew would make `scale` a third thing
/// that is neither the same drawing nor a redrawn one.
///
/// A canvas at its natural size passes `drawing.viewbox` and gets k = 1
/// with no margin, which is every caller before the size policy existed.
pub fn rasterize(drawing: &Drawing, track: (f64, f64), p: Presentation) -> Raster {
    let (t_w, t_h) = track;
    let width = ((t_w * p.scale).round() as i64).clamp(0, 16384) as u32;
    let height = ((t_h * p.scale).round() as i64).clamp(0, 16384) as u32;
    let Some(mut pixmap) = tiny_skia::Pixmap::new(width.max(1), height.max(1)) else {
        return Raster { width: 0, height: 0, scale: p.scale, pixels: Vec::new() };
    };
    if width == 0 || height == 0 {
        return Raster { width: 0, height: 0, scale: p.scale, pixels: Vec::new() };
    }

    let Fit { k, ox, oy } = fit(drawing.viewbox, track);
    let s = k * p.scale;
    let (dx, dy) = (ox * p.scale, oy * p.scale);
    let mut builder = tiny_skia::PathBuilder::new();
    // The SELECTED face or the sentence saying why there is none. Held
    // rather than refused at the `font` op, so a face nothing draws with
    // refuses nothing: the measured failure is a RUN that vanishes.
    let mut face: Option<Result<Face, String>> = None;

    for op in &drawing.ops {
        match op {
            Op::MoveTo(x, y) => builder.move_to((x * s + dx) as f32, (y * s + dy) as f32),
            Op::LineTo(x, y) => builder.line_to((x * s + dx) as f32, (y * s + dy) as f32),
            Op::Close => builder.close(),
            Op::Stroke { paint, width } => {
                let built = std::mem::replace(&mut builder, tiny_skia::PathBuilder::new());
                if let Some(path) = built.finish() {
                    let mut style = tiny_skia::Paint::default();
                    style.set_color(resolve(*paint, p.mode));
                    style.anti_alias = true;
                    // Joins, caps and the miter limit are NOT in the op
                    // vocabulary (§3.3), so they are tiny-skia's
                    // defaults and are the same number on every lane.
                    let stroke = tiny_skia::Stroke {
                        width: (width * s) as f32,
                        ..Default::default()
                    };
                    pixmap.stroke_path(
                        &path,
                        &style,
                        &stroke,
                        tiny_skia::Transform::identity(),
                        None,
                    );
                }
            }
            Op::Fill { paint, even_odd } => {
                let built = std::mem::replace(&mut builder, tiny_skia::PathBuilder::new());
                if let Some(path) = built.finish() {
                    let mut style = tiny_skia::Paint::default();
                    style.set_color(resolve(*paint, p.mode));
                    style.anti_alias = true;
                    let rule = if *even_odd {
                        tiny_skia::FillRule::EvenOdd
                    } else {
                        tiny_skia::FillRule::Winding
                    };
                    pixmap.fill_path(
                        &path,
                        &style,
                        rule,
                        tiny_skia::Transform::identity(),
                        None,
                    );
                }
            }
            Op::Font { asset, size, weight } => {
                face = Some(Face::open(asset, size * s, *weight));
            }
            Op::Text { x, y, paint, align, baseline, text } => {
                // THE RASTER RESOLVES THE FONT AGAIN and validation
                // cannot speak for the second answer, so the refusal is
                // repeated here (docs/canvas-plan.md §3.5, ruled
                // 2026-08-26). It fires before anything of this run
                // reaches the pixmap, and the unwind takes the buffer
                // with it: no half-drawn picture leaves this function.
                let face = match &face {
                    Some(Ok(face)) => face,
                    Some(Err(why)) => panic!(
                        "kaya: the canvas text run {text:?} cannot be drawn — {why}. \
                         A run dropped for want of its face leaves a picture that is \
                         wrong with nothing anywhere to say so — only §7.1's frozen \
                         hash moves — so the raster refuses as a unit instead \
                         (docs/canvas-plan.md §3.5, docs/traps.md)"
                    ),
                    // validate() refuses a `text` with no `font` before
                    // it, so a face has always been selected here (§3.5).
                    None => unreachable!("a canvas text op with no font reached the raster"),
                };
                if let Some(path) = face.outline(text, x * s + dx, y * s + dy, *align, *baseline) {
                    let mut style = tiny_skia::Paint::default();
                    style.set_color(resolve(*paint, p.mode));
                    style.anti_alias = true;
                    pixmap.fill_path(
                        &path,
                        &style,
                        tiny_skia::FillRule::Winding,
                        tiny_skia::Transform::identity(),
                        None,
                    );
                }
            }
        }
    }

    Raster { width, height, scale: p.scale, pixels: pixmap.take() }
}

/// The canonical raster and the two legible reads, all three from ONE
/// render so a scene cannot see them disagree (§7.1, §7.2).
pub fn probe(drawing: &Drawing) -> Probe {
    let raster = rasterize(
        drawing,
        drawing.viewbox,
        Presentation { scale: CANONICAL_SCALE, mode: CANONICAL_MODE },
    );
    Probe { hash: hash(&raster), ops: drawing.op_count(), ink: ink(&raster) }
}

/// FNV-1a over the buffer's dimensions and its bytes. A cryptographic
/// digest would buy nothing here — this is a change detector for a
/// frozen string, not a signature — and FNV is already the tree's
/// fingerprint of record (spec::hash).
pub fn hash(raster: &Raster) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    let mut eat = |bytes: &[u8]| {
        for b in bytes {
            h ^= u64::from(*b);
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
    };
    eat(&raster.width.to_le_bytes());
    eat(&raster.height.to_le_bytes());
    eat(&raster.pixels);
    h
}

/// The ink bounding box, read off THE PIXELS rather than off the paths:
/// the buffer starts fully transparent and every paint writes alpha, so
/// a non-zero alpha is exactly "something drew here". Normalized to
/// hundredths of the canvas's own box, which is what lets one frozen
/// string hold on five platforms whose pixel sizes all differ.
fn ink(raster: &Raster) -> Option<(i64, i64, i64, i64)> {
    if raster.width == 0 || raster.height == 0 {
        return None;
    }
    let (w, h) = (raster.width as usize, raster.height as usize);
    let (mut l, mut t, mut r, mut b) = (w, h, 0usize, 0usize);
    let mut any = false;
    for y in 0..h {
        for x in 0..w {
            if raster.pixels[(y * w + x) * 4 + 3] != 0 {
                any = true;
                l = l.min(x);
                t = t.min(y);
                r = r.max(x + 1);
                b = b.max(y + 1);
            }
        }
    }
    if !any {
        return None;
    }
    let hundredths = |n: usize, of: usize| -> i64 {
        // ONE rounding function for all four edges, the way shares()
        // rounds: the arithmetic being identical everywhere is not
        // enough, the ROUNDING has to be identical too.
        ((n as f64) * 100.0 / (of as f64)).round() as i64
    };
    Some((hundredths(l, w), hundredths(t, h), hundredths(r, w), hundredths(b, h)))
}

/// `expect_drawing`'s frozen string: how many ops the core replayed and
/// where the ink landed. Spelled here so the three harnesses compare a
/// string the core composed rather than three formatters.
pub fn drawing_observation(p: &Probe) -> String {
    match p.ink {
        Some((l, t, r, b)) => format!("{}/{l},{t},{r},{b}", p.ops),
        None => format!("{}/empty", p.ops),
    }
}

// ---------------------------------------------------------------------
// Text: shape with harfrust, outline with skrifa, fill with tiny-skia
// ---------------------------------------------------------------------

/// One selected face at one pixel size. The bytes are owned so the
/// shaper and the outline scaler both read the SAME buffer — harfrust
/// runs on read-fonts by design, so a canvas has exactly one thing
/// reading a font file (§4.1).
struct Face {
    bytes: std::sync::Arc<[u8]>,
    px: f64,
    weight: f64,
}

impl Face {
    /// The bytes, or the sentence saying which asset could not become a
    /// face. Validation already resolved this name (§3.5), so an `Err`
    /// here is an asset that vanished — or stopped being a font —
    /// between the declaration and the raster.
    fn open(asset: &str, px: f64, weight: f64) -> Result<Face, String> {
        // An unspecified name means the reserved default, and a refusal
        // may only name what it measured.
        let named = if asset.is_empty() { crate::assets::DEFAULT_FONT } else { asset };
        let bytes = crate::assets::font_bytes(asset).map_err(|why| {
            format!("the font asset {named:?} does not resolve at raster time: {why}")
        })?;
        // PARSED HERE, so bytes that resolve and are not a font are the
        // same refusal rather than the same silent drop one layer down;
        // `outline` reads these same bytes and therefore cannot fail.
        FontRef::new(&bytes).map_err(|e| {
            format!(
                "the font asset {named:?} resolves to {} bytes that are not a font \
                 kaya can read: {e}",
                bytes.len()
            )
        })?;
        Ok(Face { bytes, px, weight })
    }

    /// The whole line as ONE path in device space, already anchored.
    /// Glyph outlines are UNHINTED and antialiased by tiny-skia — the
    /// chosen trade, because hinting is per-platform flavour and
    /// byte-identity is the point (§4.1's hinting caveat).
    fn outline(
        &self,
        text: &str,
        x: f64,
        y: f64,
        align: i64,
        baseline: i64,
    ) -> Option<tiny_skia::Path> {
        // `Face::open` parsed these same bytes, so this cannot fail —
        // and says so LOUDLY rather than dropping the run, which is the
        // shape this file exists to refuse (docs/canvas-plan.md §3.5).
        let font = FontRef::new(&self.bytes)
            .expect("Face::open parsed these bytes; the raster reads the same buffer");
        let location = font.axes().location([("wght", self.weight as f32)]);
        let size = Size::new(self.px as f32);
        let metrics = font.metrics(size, &location);

        let shaper_data = harfrust::ShaperData::new(&font);
        let instance = harfrust::ShaperInstance::from_variations(
            &font,
            [harfrust::Variation {
                tag: harfrust::Tag::new(b"wght"),
                value: self.weight as f32,
            }],
        );
        let shaper = shaper_data.shaper(&font).instance(Some(&instance)).build();
        let upem = f64::from(shaper.units_per_em().max(1));

        let mut buffer = harfrust::UnicodeBuffer::new();
        buffer.push_str(text);
        buffer.guess_segment_properties();
        let shaped = shaper.shape(buffer, harfrust::ShapeOptions::default());

        let per_unit = self.px / upem;
        let advance: f64 = shaped
            .glyph_positions()
            .iter()
            .map(|p| f64::from(p.x_advance) * per_unit)
            .sum();

        let pen_x = match align {
            wire::TEXT_ALIGN_MIDDLE => x - advance / 2.0,
            wire::TEXT_ALIGN_END => x - advance,
            _ => x,
        };
        let ascent = f64::from(metrics.ascent);
        let descent = f64::from(metrics.descent).abs();
        let pen_y = match baseline {
            wire::TEXT_BASELINE_TOP => y + ascent,
            wire::TEXT_BASELINE_BOTTOM => y - descent,
            wire::TEXT_BASELINE_MIDDLE => y + (ascent - descent) / 2.0,
            _ => y,
        };

        let outlines = font.outline_glyphs();
        let mut sink = GlyphSink { builder: tiny_skia::PathBuilder::new(), dx: 0.0, dy: 0.0 };
        let mut cursor = pen_x;
        for (info, pos) in shaped.glyph_infos().iter().zip(shaped.glyph_positions()) {
            let glyph = outlines.get(skrifa::GlyphId::new(info.glyph_id))?;
            sink.dx = cursor + f64::from(pos.x_offset) * per_unit;
            // The font's y axis points UP and the raster's points DOWN,
            // so the sink negates; the offset is added in font space
            // and therefore negated with it.
            sink.dy = pen_y - f64::from(pos.y_offset) * per_unit;
            let settings = DrawSettings::unhinted(size, &location);
            glyph.draw(settings, &mut sink).ok()?;
            cursor += f64::from(pos.x_advance) * per_unit;
        }
        sink.builder.finish()
    }
}

/// Receives one glyph's outline and lays it into the line's path at the
/// pen position, flipping the font's y-up convention to the raster's
/// y-down.
struct GlyphSink {
    builder: tiny_skia::PathBuilder,
    dx: f64,
    dy: f64,
}

impl GlyphSink {
    fn at(&self, x: f32, y: f32) -> (f32, f32) {
        ((f64::from(x) + self.dx) as f32, (self.dy - f64::from(y)) as f32)
    }
}

impl OutlinePen for GlyphSink {
    fn move_to(&mut self, x: f32, y: f32) {
        let (x, y) = self.at(x, y);
        self.builder.move_to(x, y);
    }

    fn line_to(&mut self, x: f32, y: f32) {
        let (x, y) = self.at(x, y);
        self.builder.line_to(x, y);
    }

    fn quad_to(&mut self, cx: f32, cy: f32, x: f32, y: f32) {
        let (cx, cy) = self.at(cx, cy);
        let (x, y) = self.at(x, y);
        self.builder.quad_to(cx, cy, x, y);
    }

    fn curve_to(&mut self, cx0: f32, cy0: f32, cx1: f32, cy1: f32, x: f32, y: f32) {
        let (cx0, cy0) = self.at(cx0, cy0);
        let (cx1, cy1) = self.at(cx1, cy1);
        let (x, y) = self.at(x, y);
        self.builder.cubic_to(cx0, cy0, cx1, cy1, x, y);
    }

    fn close(&mut self) {
        self.builder.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn op(code: i64) -> Value {
        Value::I64(code)
    }

    fn n(v: f64) -> Value {
        Value::F64(v)
    }

    fn s(v: &str) -> Value {
        Value::Str(v.to_owned())
    }

    /// A square drawn with the five geometry ops, plus one label.
    fn chart() -> Vec<Value> {
        vec![
            op(wire::DRAW_MOVE_TO), n(10.0), n(10.0),
            op(wire::DRAW_LINE_TO), n(90.0), n(10.0),
            op(wire::DRAW_LINE_TO), n(90.0), n(40.0),
            op(wire::DRAW_CLOSE),
            op(wire::DRAW_FILL), op(wire::PAINT_SERIES_FILL), op(wire::FILL_NONZERO),
            op(wire::DRAW_MOVE_TO), n(10.0), n(45.0),
            op(wire::DRAW_LINE_TO), n(90.0), n(45.0),
            op(wire::DRAW_STROKE), op(wire::PAINT_GRID), n(1.0),
            op(wire::DRAW_FONT), s(""), n(11.0), op(400),
            op(wire::DRAW_TEXT), n(50.0), n(40.0), op(wire::PAINT_AXIS),
            op(wire::TEXT_ALIGN_MIDDLE), op(wire::TEXT_BASELINE_ALPHABETIC), s("$40k"),
        ]
    }

    /// THE SCENE'S OWN OP STREAM, byte for byte what guests/rust/canvas.rs
    /// declares (tools/scenes/canvas.steps). Written out here rather than
    /// derived, so the core's tests can sample the pixels the five lanes
    /// argue about without a guest process.
    fn scene_chart() -> Vec<Value> {
        const PLOT: (f64, f64, f64, f64) = (40.0, 10.0, 290.0, 100.0);
        const SERIES: [(f64, f64); 7] = [
            (40.0, 88.0),
            (81.0, 74.0),
            (123.0, 80.0),
            (165.0, 51.0),
            (206.0, 57.0),
            (248.0, 30.0),
            (290.0, 20.0),
        ];
        const TICKS: [(f64, &str); 3] = [(32.0, "$60k"), (55.0, "$40k"), (78.0, "$20k")];
        let (l, t, r, b) = PLOT;
        let mut v = Vec::new();
        let move_to = |v: &mut Vec<Value>, x: f64, y: f64| {
            v.extend([op(wire::DRAW_MOVE_TO), n(x), n(y)]);
        };
        move_to(&mut v, l, t);
        for (x, y) in [(r, t), (r, b), (l, b)] {
            v.extend([op(wire::DRAW_LINE_TO), n(x), n(y)]);
        }
        v.push(op(wire::DRAW_CLOSE));
        v.extend([op(wire::DRAW_FILL), op(wire::PAINT_GROUND), op(wire::FILL_NONZERO)]);
        for (y, _) in TICKS {
            move_to(&mut v, l, y);
            v.extend([op(wire::DRAW_LINE_TO), n(r), n(y)]);
        }
        v.extend([op(wire::DRAW_STROKE), op(wire::PAINT_GRID), n(1.0)]);
        let polyline = |v: &mut Vec<Value>| {
            for (i, (x, y)) in SERIES.iter().enumerate() {
                let code = if i == 0 { wire::DRAW_MOVE_TO } else { wire::DRAW_LINE_TO };
                v.extend([op(code), n(*x), n(*y)]);
            }
        };
        polyline(&mut v);
        v.extend([op(wire::DRAW_LINE_TO), n(r), n(b)]);
        v.extend([op(wire::DRAW_LINE_TO), n(l), n(b)]);
        v.push(op(wire::DRAW_CLOSE));
        v.extend([op(wire::DRAW_FILL), op(wire::PAINT_SERIES_FILL), op(wire::FILL_NONZERO)]);
        polyline(&mut v);
        v.extend([op(wire::DRAW_STROKE), op(wire::PAINT_SERIES), n(2.0)]);
        move_to(&mut v, l, t);
        v.extend([op(wire::DRAW_LINE_TO), n(l), n(b)]);
        v.extend([op(wire::DRAW_STROKE), op(wire::PAINT_AXIS), n(1.0)]);
        v.extend([op(wire::DRAW_FONT), s(""), n(11.0), op(400)]);
        for (y, text) in TICKS {
            v.extend([
                op(wire::DRAW_TEXT), n(l - 4.0), n(y), op(wire::PAINT_AXIS),
                op(wire::TEXT_ALIGN_END), op(wire::TEXT_BASELINE_MIDDLE), s(text),
            ]);
        }
        v.extend([op(wire::DRAW_FONT), s("fonts/sora-wght.ttf"), n(13.0), op(700)]);
        v.extend([
            op(wire::DRAW_TEXT), n(l + 8.0), n(t + 3.0), op(wire::PAINT_SERIES),
            op(wire::TEXT_ALIGN_START), op(wire::TEXT_BASELINE_TOP), s("Q3"),
        ]);
        v
    }

    /// WHAT THE CORE PUTS AT THE SCENE'S TWO PROBE POINTS, pinned here
    /// so a figure or palette edit reddens in this suite in a second
    /// rather than on five lanes in ten minutes.
    ///
    /// BOTH POINTS ARE OPAQUE IN THE CORE, and `expect_ink` rests on
    /// that: the sampling backends drop the alpha byte and report RGB
    /// straight (crates/kaya/src/winui/mod.rs's `sample_shot`,
    /// gtk.rs's `canvas_ink`), so a probe point whose alpha fell below
    /// 255 would read darkened toward the compositor's ground with no
    /// diagnostic saying why, while the hash stayed green.
    ///
    /// THE SCENE FREEZES THESE BYTES, and `expect_ink` compares them
    /// within ±1 per channel: the mac reads D2E2F7 back off its own
    /// window where the core wrote D2E3F7, because that window's backing
    /// store carries the display's profile (docs/traps.md, "a canvas ink
    /// read crosses the display's colour space"; ruled 2026-08-26,
    /// docs/canvas-plan.md §7.2). So a probe colour whose channels move
    /// by MORE than one here is a re-freeze, not a rounding.
    #[test]
    fn the_scene_probe_points_are_opaque_and_pinned() {
        // This stream NAMES A FONT ASSET, and assets::tests move
        // KAYA_ASSET_DIR out from under the whole process — see
        // crate::assets::serially.
        let _serial = crate::assets::serially();
        let d = validate((300.0, 120.0), &scene_chart()).expect("the scene's stream validates");
        assert_eq!(d.op_count(), 41, "tools/scenes/canvas.steps freezes 41 ops");
        let p = probe(&d);
        // THE EARLIER WALL. The raster now REFUSES a run whose font will
        // not resolve (ruled 2026-08-26, see
        // a_vanished_font_refuses_the_run_rather_than_dropping_it), so
        // the hash can no longer move for this reason in silence — but
        // this assert reaches it FIRST and names the asset before the
        // frozen hash is compared, which is the difference between
        // "the font is gone" and "the picture changed". Measured
        // 2026-08-26: this test failed 8/8 against one build with
        // c4fa15caf170a5ff, which is EXACTLY this scene with its one
        // disk-resolved run (`Q3`, fonts/sora-wght.ttf) missing — the
        // three tick labels use the embedded default and were fine
        // (docs/traps.md).
        assert!(
            crate::assets::font_bytes("fonts/sora-wght.ttf").is_ok(),
            "the scene's disk-resolved font did not resolve, so its `Q3` run is about \
             to be dropped from the raster with no other symptom: {}",
            crate::assets::asset_why_not("fonts/sora-wght.ttf")
        );
        assert_eq!(
            format!("{:016x}", p.hash),
            "e5ac8a2c0b240633",
            "tools/scenes/canvas.steps freezes this hash (c4fa15caf170a5ff was this \
             scene with the `Q3` run dropped for want of its font, which the raster \
             refuses now rather than draws)"
        );
        assert_eq!(drawing_observation(&p), "41/2,8,97,83");
        // BOTH MODES, because the scene's `expect_ink` names both and the
        // DISPLAY raster uses whichever the host reports (§6). The two
        // strings are DERIVED HERE and copied into tools/scenes/canvas.steps;
        // neither is ever typed from a platform's read.
        let ink = |mode: Mode, label: &str| -> String {
            let r = rasterize(&d, d.viewbox, Presentation { scale: 1.0, mode });
            let at = |px: f64, py: f64| -> [u8; 4] {
                let x = ((r.width as f64) * px / 100.0) as usize;
                let y = ((r.height as f64) * py / 100.0) as usize;
                let i = (y * r.width as usize + x) * 4;
                [r.pixels[i], r.pixels[i + 1], r.pixels[i + 2], r.pixels[i + 3]]
            };
            let ground = at(15.0, 20.0);
            let filled = at(70.0, 63.0);
            println!("core {label} at 15,20 = {ground:02X?}; at 70,63 = {filled:02X?}");
            // OPACITY IS THE PRECONDITION for sampling at all: a
            // translucent probe point reads the compositor's ground
            // instead of the palette's.
            assert_eq!(ground[3], 255, "{label} 15,20 must be opaque: {ground:02X?}");
            assert_eq!(filled[3], 255, "{label} 70,63 must be opaque: {filled:02X?}");
            format!(
                "{label} {:02X}{:02X}{:02X}/{:02X}{:02X}{:02X}",
                ground[0], ground[1], ground[2], filled[0], filled[1], filled[2]
            )
        };
        assert_eq!(
            format!("{} {}", ink(Mode::Light, "light"), ink(Mode::Dark, "dark")),
            "light FFFFFF/D2E3F7 dark 16181C/212A35",
            "tools/scenes/canvas.steps freezes exactly this string, and expect_ink \
             allows each channel ±1 around EACH MODE's half"
        );
    }

    /// THE SIZE-POLICY SCENE'S OWN FIGURES, byte for byte what
    /// guests/rust/sizepolicy.rs declares (tools/scenes/sizepolicy.steps).
    /// Written out here for scene_chart's reason: the core's tests can
    /// sample the pixels five lanes will argue about without a guest
    /// process.
    fn panel(v: &mut Vec<Value>, box_: (f64, f64), l: f64, t: f64, r: f64, b: f64, paint: i64) {
        let (w, h) = box_;
        v.extend([op(wire::DRAW_MOVE_TO), n(l * w), n(t * h)]);
        for (x, y) in [(r, t), (r, b), (l, b)] {
            v.extend([op(wire::DRAW_LINE_TO), n(x * w), n(y * h)]);
        }
        v.push(op(wire::DRAW_CLOSE));
        v.extend([op(wire::DRAW_FILL), op(paint), op(wire::FILL_NONZERO)]);
    }

    fn scene_figure(box_: (f64, f64)) -> Vec<Value> {
        let mut v = Vec::new();
        panel(&mut v, box_, 0.05, 0.0, 0.95, 1.0, wire::PAINT_GROUND);
        panel(&mut v, box_, 0.25, 0.0, 0.75, 1.0, wire::PAINT_SERIES_FILL);
        v
    }

    fn scene_bar(box_: (f64, f64), frame: u32) -> Vec<Value> {
        let mut v = Vec::new();
        let right = 0.35 + 0.10 * f64::from(frame);
        panel(&mut v, box_, 0.25, 0.0, right, 1.0, wire::PAINT_AXIS);
        v
    }

    /// WHAT tools/scenes/sizepolicy.steps FREEZES, derived here and
    /// copied there — never typed from a platform's read, and never
    /// guessed (the dark ink pair was guessed wrong by one on two
    /// channels before the canvas scene derived it, docs/traps.md).
    ///
    /// THE FIGURE IS FRACTIONS OF WHATEVER BOX IT IS HANDED, which is
    /// what lets one frozen string hold for four canvases whose tracks
    /// differ on every platform: the bounds normalize to the same
    /// hundredths at 300x120 and at whatever the mac column assigns.
    #[test]
    fn the_size_policy_scene_expectations_are_derived() {
        let _serial = crate::assets::serially();
        // Two boxes far apart in size AND aspect: the frozen strings
        // below have to be the same at both, or they are not byte-shared
        // and the scene cannot hold on five platforms.
        for box_ in [(300.0, 120.0), (461.0, 87.0)] {
            let d = validate(box_, &scene_figure(box_)).expect("the figure validates");
            let p = probe(&d);
            assert_eq!(drawing_observation(&p), "12/5,0,95,100", "figure at {box_:?}");
            for frame in [1u32, 3] {
                let d = validate(box_, &scene_bar(box_, frame)).expect("the bar validates");
                let want = match frame {
                    1 => "6/25,0,45,100",
                    _ => "6/25,0,65,100",
                };
                assert_eq!(drawing_observation(&probe(&d)), want, "bar {frame} at {box_:?}");
            }
        }
        // THE TWO CONSTANT-MODE CANVASES KEEP §7.1's PRIMARY OBSERVABLE,
        // and this is the amendment made concrete: `scale` and `fixed`
        // declare the drawing a constant function of the track, so their
        // op stream is a pure function of the guest's declaration and
        // hashes to one string on five platforms. The redraw and tick
        // canvases beside them have NO frozen hash — their streams are
        // functions of a track the platforms legitimately differ on —
        // and the scene says so out loud.
        let constant = validate((300.0, 120.0), &scene_figure((300.0, 120.0))).unwrap();
        assert_eq!(
            format!("{:016x}", probe(&constant).hash),
            "8185fc030ee419b6",
            "tools/scenes/sizepolicy.steps freezes this hash for canvas@fit and canvas@mark"
        );

        // The one probe point every canvas in that scene can be sampled
        // at: the CENTRE. A `scale` canvas letterboxes its figure inside
        // the track and a `fixed` one is centred inside it by the
        // backend, so an edge probe would land in margin on one and in
        // ink on another — the centre is inside the figure for all four.
        let d = validate((300.0, 120.0), &scene_figure((300.0, 120.0))).unwrap();
        let at_centre = |mode: Mode, label: &str| -> String {
            let r = rasterize(&d, d.viewbox, Presentation { scale: 1.0, mode });
            let x = r.width as usize / 2;
            let y = r.height as usize / 2;
            let i = (y * r.width as usize + x) * 4;
            let px = [r.pixels[i], r.pixels[i + 1], r.pixels[i + 2], r.pixels[i + 3]];
            println!("core {label} at 50,50 = {px:02X?}");
            // OPACITY IS THE PRECONDITION for sampling at all: the
            // backends drop the alpha byte, so a translucent probe point
            // would read darkened toward the compositor's ground with no
            // diagnostic saying why.
            assert_eq!(px[3], 255, "{label} 50,50 must be opaque: {px:02X?}");
            format!("{label} {:02X}{:02X}{:02X}", px[0], px[1], px[2])
        };
        assert_eq!(
            format!("{} {}", at_centre(Mode::Light, "light"), at_centre(Mode::Dark, "dark")),
            "light D2E3F7 dark 212A35",
            "tools/scenes/sizepolicy.steps freezes exactly this string"
        );
    }

    /// THE PORTFOLIO'S DRAWN MARK, byte for byte what
    /// guests/python/portfolio.py declares — `fixed`'s forcing artifact
    /// (docs/canvas-plan.md §3.2.1, ruling 3). Here for scene_figure's
    /// reason: the strings tools/scenes/portfolio.steps freezes are
    /// DERIVED from the core's own raster, never typed from a lane.
    fn portfolio_mark() -> Vec<Value> {
        let line = [(2.0, 13.0), (9.0, 7.0), (16.0, 11.0), (26.0, 3.0)];
        let area: Vec<(f64, f64)> =
            line.iter().copied().chain([(26.0, 26.0), (2.0, 26.0)]).collect();
        let mut v = Vec::new();
        let poly = |v: &mut Vec<Value>, pts: &[(f64, f64)]| {
            for (i, (x, y)) in pts.iter().enumerate() {
                let code = if i == 0 { wire::DRAW_MOVE_TO } else { wire::DRAW_LINE_TO };
                v.extend([op(code), n(*x), n(*y)]);
            }
        };
        for paint in [wire::PAINT_GROUND, wire::PAINT_SERIES_FILL] {
            poly(&mut v, &area);
            v.push(op(wire::DRAW_CLOSE));
            v.extend([op(wire::DRAW_FILL), op(paint), op(wire::FILL_NONZERO)]);
        }
        poly(&mut v, &line);
        v.extend([op(wire::DRAW_STROKE), op(wire::PAINT_SERIES), n(2.0)]);
        v
    }

    #[test]
    fn the_portfolio_mark_expectations_are_derived() {
        let _serial = crate::assets::serially();
        let box_ = (28.0, 28.0);
        let d = validate(box_, &portfolio_mark()).expect("the mark validates");
        let p = probe(&d);
        assert_eq!(
            (drawing_observation(&p), format!("{:016x}", p.hash)),
            ("21/4,7,96,93".to_string(), "29abce8483ccc343".to_string()),
            "tools/scenes/portfolio.steps freezes these two"
        );
        // THE CENTRE, and only the centre: a `fixed` canvas is placed in
        // a track it does not fill, and `expect_ink` samples hundredths
        // of the canvas's OWN BOX — so an edge probe would land in the
        // letterbox margin the backend leaves around it.
        let at_centre = |mode: Mode, label: &str| -> String {
            let r = rasterize(&d, d.viewbox, Presentation { scale: 1.0, mode });
            let x = r.width as usize / 2;
            let y = r.height as usize / 2;
            let i = (y * r.width as usize + x) * 4;
            let px = [r.pixels[i], r.pixels[i + 1], r.pixels[i + 2], r.pixels[i + 3]];
            println!("core mark {label} at 50,50 = {px:02X?}");
            assert_eq!(px[3], 255, "{label} 50,50 must be opaque: {px:02X?}");
            format!("{label} {:02X}{:02X}{:02X}", px[0], px[1], px[2])
        };
        assert_eq!(
            format!("{} {}", at_centre(Mode::Light, "light"), at_centre(Mode::Dark, "dark")),
            "light D2E3F7 dark 212A35",
            "tools/scenes/portfolio.steps freezes exactly this string"
        );
    }

    #[test]
    fn a_drawing_rasterizes_and_probes() {
        let drawing = validate((100.0, 50.0), &chart()).expect("the chart validates");
        assert_eq!(drawing.op_count(), 10);
        let p = probe(&drawing);
        assert_ne!(p.hash, 0);
        let (l, t, r, b) = p.ink.expect("the chart put ink on the raster");
        // The figure spans x 10..90 of a 100-WIDE box (10..90 hundredths)
        // and y 10..45.5 of a 50-TALL one (20..91 hundredths); the
        // stroke's half width and the glyph's descender widen it by a
        // point or two, never by a quadrant. The two denominators being
        // different is the whole reason the fractions are per-axis.
        assert!((8..=12).contains(&l), "left {l}");
        assert!((18..=22).contains(&t), "top {t}");
        assert!((88..=92).contains(&r), "right {r}");
        assert!((88..=94).contains(&b), "bottom {b}");
        assert_eq!(drawing_observation(&p), format!("10/{l},{t},{r},{b}"));
    }

    /// The raster is a pure function of the declaration: the same ops
    /// twice are the same bytes twice. Byte-identity across LANES is the
    /// cross-ISA measurement (docs/measurements/), which no unit test on
    /// one machine can make.
    #[test]
    fn the_same_declaration_is_the_same_bytes() {
        let a = validate((100.0, 50.0), &chart()).unwrap();
        let b = validate((100.0, 50.0), &chart()).unwrap();
        assert_eq!(probe(&a).hash, probe(&b).hash);
    }

    /// A one-tenth-of-a-unit move reddens the HASH and leaves the ink
    /// bounds alone — the pair that proves the hash does work the
    /// bounds cannot (§7.4).
    #[test]
    fn the_hash_sees_what_the_bounds_cannot() {
        let plain = validate((100.0, 50.0), &chart()).unwrap();
        let mut moved = chart();
        moved[15] = n(45.1);
        let moved = validate((100.0, 50.0), &moved).unwrap();
        let (a, b) = (probe(&plain), probe(&moved));
        assert_ne!(a.hash, b.hash, "a tenth of a unit must move the hash");
        assert_eq!(a.ink, b.ink, "and must not move the ink bounds");
    }

    /// The two modes are two different buffers, which is the whole
    /// reason only the mode bit crosses (§6).
    #[test]
    fn the_appearance_mode_changes_the_pixels() {
        let d = validate((100.0, 50.0), &chart()).unwrap();
        let light = rasterize(&d, d.viewbox, Presentation { scale: 1.0, mode: Mode::Light });
        let dark = rasterize(&d, d.viewbox, Presentation { scale: 1.0, mode: Mode::Dark });
        assert_ne!(hash(&light), hash(&dark));
        assert_eq!(light.width, dark.width);
    }

    #[test]
    fn the_scale_changes_the_pixel_count_and_not_the_bounds() {
        let d = validate((100.0, 50.0), &chart()).unwrap();
        let one = rasterize(&d, d.viewbox, Presentation { scale: 1.0, mode: Mode::Light });
        let two = rasterize(&d, d.viewbox, Presentation { scale: 2.0, mode: Mode::Light });
        assert_eq!((one.width * 2, one.height * 2), (two.width, two.height));
        // Same figure, same fractions of the box.
        assert_eq!(ink(&one).map(|b| b.0), ink(&two).map(|b| b.0));
    }

    /// EVERY REFUSAL IN §3.5, MADE TO FIRE. A wall nobody has watched
    /// refuse is a guess about a state nobody has reached (invariant 3);
    /// `cargo test -- --nocapture` prints the sentence each one gives.
    #[test]
    fn every_refusal_says_what_is_wrong() {
        let seen = |vb: (f64, f64), ops: Vec<Value>| -> String {
            let e = validate(vb, &ops).expect_err("this stream must be refused");
            println!("canvas refusal: {e}");
            e
        };

        let e = seen((0.0, 50.0), vec![]);
        assert!(e.contains("viewbox width is 0"), "{e}");
        let e = seen((100.0, f64::NAN), vec![]);
        assert!(e.contains("viewbox height is NaN"), "{e}");

        let e = seen((100.0, 50.0), vec![op(99)]);
        assert!(e.contains("99 is not a canvas opcode"), "{e}");
        let e = seen((100.0, 50.0), vec![n(1.0)]);
        assert!(e.contains("where an opcode was expected"), "{e}");

        let e = seen((100.0, 50.0), vec![op(wire::DRAW_MOVE_TO), n(1.0)]);
        assert!(e.contains("takes 2 operands and the stream ends after 1"), "{e}");

        let e = seen((100.0, 50.0), vec![op(wire::DRAW_MOVE_TO), n(f64::INFINITY), n(0.0)]);
        assert!(e.contains("is not finite"), "{e}");

        let e = seen((100.0, 50.0), vec![op(wire::DRAW_LINE_TO), n(1.0), n(1.0)]);
        assert!(e.contains("before any `move_to`"), "{e}");

        let e = seen((100.0, 50.0), vec![op(wire::DRAW_CLOSE)]);
        assert!(e.contains("no open subpath"), "{e}");

        let e = seen(
            (100.0, 50.0),
            vec![op(wire::DRAW_STROKE), op(wire::PAINT_GRID), n(1.0)],
        );
        assert!(e.contains("`stroke` with paint `grid` and width 1") && e.contains("no path built"), "{e}");
        let e = seen(
            (100.0, 50.0),
            vec![op(wire::DRAW_FILL), op(wire::PAINT_AXIS), op(wire::FILL_EVEN_ODD)],
        );
        assert!(e.contains("`fill` with paint `axis` and rule `even_odd`"), "{e}");

        let e = seen(
            (100.0, 50.0),
            vec![
                op(wire::DRAW_MOVE_TO), n(0.0), n(0.0),
                op(wire::DRAW_STROKE), op(42), n(1.0),
            ],
        );
        assert!(e.contains("42 is not a canvas paint"), "{e}");

        let e = seen(
            (100.0, 50.0),
            vec![
                op(wire::DRAW_MOVE_TO), n(0.0), n(0.0),
                op(wire::DRAW_STROKE), op(wire::PAINT_GRID), n(0.0),
            ],
        );
        assert!(e.contains("stroke width is 0"), "{e}");

        let e = seen(
            (100.0, 50.0),
            vec![
                op(wire::DRAW_MOVE_TO), n(0.0), n(0.0),
                op(wire::DRAW_FILL), op(wire::PAINT_GRID), op(7),
            ],
        );
        assert!(e.contains("7 is not a canvas fill rule"), "{e}");

        let e = seen((100.0, 50.0), vec![op(wire::DRAW_FONT), s(""), n(0.0), op(400)]);
        assert!(e.contains("font size is 0"), "{e}");

        let e = seen(
            (100.0, 50.0),
            vec![op(wire::DRAW_FONT), s("fonts/nope.ttf"), n(11.0), op(400)],
        );
        assert!(e.contains("no asset named \"fonts/nope.ttf\""), "the resolver's own sentence: {e}");

        let e = seen(
            (100.0, 50.0),
            vec![
                op(wire::DRAW_TEXT), n(0.0), n(0.0), op(wire::PAINT_AXIS),
                op(wire::TEXT_ALIGN_START), op(wire::TEXT_BASELINE_TOP), s("hi"),
            ],
        );
        assert!(e.contains("no `font` selected"), "{e}");

        let e = seen(
            (100.0, 50.0),
            vec![
                op(wire::DRAW_FONT), s(""), n(11.0), op(400),
                op(wire::DRAW_TEXT), n(0.0), n(0.0), op(wire::PAINT_AXIS),
                op(9), op(wire::TEXT_BASELINE_TOP), s("hi"),
            ],
        );
        assert!(e.contains("9 is not a canvas align"), "{e}");

        let e = seen(
            (100.0, 50.0),
            vec![
                op(wire::DRAW_FONT), s(""), n(11.0), op(400),
                op(wire::DRAW_TEXT), n(0.0), n(0.0), op(wire::PAINT_AXIS),
                op(wire::TEXT_ALIGN_START), op(9), s("hi"),
            ],
        );
        assert!(e.contains("9 is not a canvas baseline"), "{e}");

        let e = seen(
            (100.0, 50.0),
            vec![
                op(wire::DRAW_FONT), s(""), n(11.0), op(400),
                op(wire::DRAW_TEXT), n(0.0), n(0.0), op(wire::PAINT_AXIS),
                op(wire::TEXT_ALIGN_START), op(wire::TEXT_BASELINE_TOP), s("two\nlines"),
            ],
        );
        assert!(e.contains("carries a line break"), "{e}");
    }

    /// THE RASTER-TIME FONT REFUSAL, both branches made to print
    /// (invariant 3; ruled 2026-08-26). Validation resolves every
    /// `draw_font` asset and the raster resolves it AGAIN — so an asset
    /// that vanishes in between used to drop the run, leaving §7.1's
    /// frozen hash as the only symptom (docs/traps.md). The resolver is
    /// doctored HERE, between the two, which is the state no scene can
    /// reach.
    #[test]
    fn a_vanished_font_refuses_the_run_rather_than_dropping_it() {
        // The doctoring is the process-wide asset root: every test in
        // the crate that resolves an asset takes this lock
        // (crate::assets::serially).
        let _serial = crate::assets::serially();

        let stream = |asset: &str| {
            vec![
                op(wire::DRAW_FONT), s(asset), n(13.0), op(700),
                op(wire::DRAW_TEXT), n(10.0), n(30.0), op(wire::PAINT_SERIES),
                op(wire::TEXT_ALIGN_START), op(wire::TEXT_BASELINE_TOP), s("Q3"),
            ]
        };
        // VALIDATION PASSES FIRST, against the real root: the window this
        // refusal closes opens only after a drawing has been accepted.
        let d = validate((100.0, 50.0), &stream("fonts/sora-wght.ttf"))
            .expect("the disk-resolved font validates against the real asset root");
        let whole = probe(&d).hash;

        let refusal = |d: &Drawing| -> String {
            let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                rasterize(d, (100.0, 50.0), Presentation::default())
            }));
            // Not `expect_err`: a Raster is pixels and does not print.
            let Err(payload) = caught else {
                panic!("the raster must refuse a run whose font is gone, not draw it");
            };
            let said = payload
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| payload.downcast_ref::<&'static str>().map(|s| (*s).to_owned()))
                .expect("the refusal carries its sentence");
            println!("canvas raster refusal: {said}");
            said
        };

        // BRANCH 1: the asset vanishes between validate and raster.
        let nowhere =
            std::env::temp_dir().join(format!("kaya-canvas-nofont-{}", std::process::id()));
        std::fs::create_dir_all(&nowhere).unwrap();
        // SAFETY: single-threaded test section under `serially()`.
        unsafe { std::env::set_var(crate::assets::ENV_VAR, &nowhere) };
        let gone = refusal(&d);
        // The RUN and the ASSET, both named, plus the resolver's own words.
        assert!(gone.contains("\"Q3\""), "the run is named: {gone}");
        assert!(gone.contains("\"fonts/sora-wght.ttf\""), "the asset is named: {gone}");
        assert!(gone.contains("does not resolve at raster time"), "{gone}");
        assert!(gone.contains("no asset named"), "the resolver's own sentence: {gone}");

        // BRANCH 2: the name resolves and the bytes are not a font.
        std::fs::create_dir_all(nowhere.join("fonts")).unwrap();
        std::fs::write(nowhere.join("fonts/sora-wght.ttf"), b"not a font at all").unwrap();
        let unreadable = refusal(&d);
        assert!(unreadable.contains("\"Q3\""), "{unreadable}");
        assert!(unreadable.contains("are not a font kaya can read"), "{unreadable}");
        assert!(unreadable.contains("17 bytes"), "it counted what it read: {unreadable}");

        unsafe { std::env::remove_var(crate::assets::ENV_VAR) };
        let _ = std::fs::remove_dir_all(&nowhere);

        // AND THE RESTORE IS WATCHED: with the real root back, the same
        // drawing rasters again and hashes what it hashed before, so the
        // two reds above were the doctoring and not a broken raster.
        assert_eq!(probe(&d).hash, whole, "the real root draws the run again");

        // The RESERVED default cannot vanish — it is compiled in — and
        // that is the half the embedding buys: with no asset root at all,
        // a canvas still draws text.
        let embedded = validate((100.0, 50.0), &stream("")).expect("the reserved default");
        unsafe { std::env::set_var(crate::assets::ENV_VAR, &nowhere) };
        let drawn = rasterize(&embedded, (100.0, 50.0), Presentation::default());
        unsafe { std::env::remove_var(crate::assets::ENV_VAR) };
        assert!(ink(&drawn).is_some(), "the embedded face still put ink on the raster");
    }

    /// Text reaches the raster: the same figure with and without its
    /// label is two different buffers, so a shaper that silently drew
    /// nothing could not pass.
    #[test]
    fn text_puts_ink_on_the_raster() {
        let with = validate((100.0, 50.0), &chart()).unwrap();
        let without: Vec<Value> = chart()[..chart().len() - 11].to_vec();
        let without = validate((100.0, 50.0), &without).unwrap();
        assert_ne!(probe(&with).hash, probe(&without).hash);
        // And the label alone, on an otherwise blank canvas.
        let only = validate(
            (100.0, 50.0),
            &vec![
                op(wire::DRAW_FONT), s(""), n(20.0), op(600),
                op(wire::DRAW_TEXT), n(50.0), n(25.0), op(wire::PAINT_AXIS),
                op(wire::TEXT_ALIGN_MIDDLE), op(wire::TEXT_BASELINE_MIDDLE), s("Wg"),
            ],
        )
        .unwrap();
        let p = probe(&only);
        let (l, t, r, b) = p.ink.expect("glyphs are ink");
        assert!(l < 50 && r > 50, "a middle-anchored run straddles its anchor: {l}..{r}");
        assert!(t < 50 && b > 20, "a middle baseline straddles its anchor: {t}..{b}");
    }

    /// The alignment and baseline vocabularies do what they say: the
    /// same string anchored three ways lands in three places.
    #[test]
    fn the_anchor_vocabulary_moves_the_run() {
        let run = |align: i64, baseline: i64| {
            let d = validate(
                (100.0, 50.0),
                &vec![
                    op(wire::DRAW_FONT), s(""), n(12.0), op(400),
                    op(wire::DRAW_TEXT), n(50.0), n(25.0), op(wire::PAINT_AXIS),
                    op(align), op(baseline), s("Ay"),
                ],
            )
            .unwrap();
            probe(&d).ink.expect("glyphs are ink")
        };
        let start = run(wire::TEXT_ALIGN_START, wire::TEXT_BASELINE_ALPHABETIC);
        let middle = run(wire::TEXT_ALIGN_MIDDLE, wire::TEXT_BASELINE_ALPHABETIC);
        let end = run(wire::TEXT_ALIGN_END, wire::TEXT_BASELINE_ALPHABETIC);
        assert!(end.0 < middle.0 && middle.0 < start.0, "{start:?} {middle:?} {end:?}");

        let top = run(wire::TEXT_ALIGN_START, wire::TEXT_BASELINE_TOP);
        let bottom = run(wire::TEXT_ALIGN_START, wire::TEXT_BASELINE_BOTTOM);
        assert!(top.1 > bottom.1, "top {top:?} sits below bottom {bottom:?}");
    }

    /// THE LETTERBOX ARITHMETIC (§3.2.1, ruling 12), which is the half of
    /// the size policy no scene can see: `expect_drawing`'s bounds and
    /// §7.1's hash both come from `probe`, which rasterizes at the
    /// VIEWBOX, so the fit is invisible to every canvas observable.
    ///
    /// It replaces `a_stretch_does_not_thicken_the_pen`, which proved the
    /// arithmetic of the SUPERSEDED §3.2 rule 3 (positions carry the
    /// stretch, pens do not) — the mitigation for a hazard the uniform
    /// fit removes.
    #[test]
    fn the_fit_is_uniform_and_centred() {
        // A wider track than the viewbox's aspect: k is the HEIGHT's
        // ratio and the leftover is horizontal margin, halved on each
        // side. A stretch would have taken tw/vbw on x.
        let f = fit((100.0, 50.0), (400.0, 100.0));
        assert_eq!(f.k, 2.0, "one factor, the smaller ratio: {f:?}");
        assert_eq!((f.ox, f.oy), (100.0, 0.0), "the leftover is centred: {f:?}");
        // Taller: the same the other way round.
        let f = fit((100.0, 50.0), (100.0, 200.0));
        assert_eq!((f.k, f.ox, f.oy), (1.0, 0.0, 75.0), "{f:?}");
        // The natural size is the identity, which is what makes every
        // pre-policy caller byte-identical.
        assert_eq!(fit((300.0, 120.0), (300.0, 120.0)), Fit { k: 1.0, ox: 0.0, oy: 0.0 });
    }

    /// THE PEN SCALES WITH EVERYTHING ELSE. Ruling 12 replaced §3.2's
    /// rule 3 along with the stretch it mitigated: `scale` is THE SAME
    /// DRAWING at a new size, so a 2pt rule in a box fitted at k=2 is 4
    /// device points thick, and the ROWS it covers double exactly as its
    /// length does.
    #[test]
    fn the_uniform_fit_scales_the_pen_with_the_drawing() {
        let d = validate(
            (100.0, 50.0),
            &vec![
                op(wire::DRAW_MOVE_TO), n(0.0), n(25.0),
                op(wire::DRAW_LINE_TO), n(100.0), n(25.0),
                op(wire::DRAW_STROKE), op(wire::PAINT_AXIS), n(2.0),
            ],
        )
        .unwrap();
        let rows = |r: &Raster| {
            (0..r.height as usize)
                .filter(|y| {
                    (0..r.width as usize).any(|x| r.pixels[(y * r.width as usize + x) * 4 + 3] != 0)
                })
                .count()
        };
        let natural = rasterize(&d, (100.0, 50.0), Presentation::default());
        let fitted = rasterize(&d, (200.0, 100.0), Presentation::default());
        assert_eq!((fitted.width, fitted.height), (natural.width * 2, natural.height * 2));
        assert_eq!(rows(&fitted), rows(&natural) * 2, "the pen doubled with the box");
    }

    /// A TRACK THE VIEWBOX DOES NOT MATCH LEAVES MARGIN, not a squashed
    /// picture: the buffer is the TRACK's size, and the ink sits centred
    /// inside it with the leftover untouched.
    #[test]
    fn a_mismatched_track_letterboxes_rather_than_stretching() {
        let d = validate((100.0, 50.0), &chart()).unwrap();
        // 400x100: k = min(4, 2) = 2, so the figure is 200x100 and there
        // are 100 points of margin on each side.
        let r = rasterize(&d, (400.0, 100.0), Presentation::default());
        assert_eq!((r.width, r.height), (400, 100));
        let (l, t, right, b) = ink(&r).expect("the chart put ink on the raster");
        // The natural ink spans 10..90 of a 100-wide box; inside the
        // fitted 200-wide figure at x 100..300 that is 120..280 of 400,
        // which is 30..70 hundredths. A stretch would have left it at
        // 10..90.
        assert!((28..=32).contains(&l), "left {l}");
        assert!((68..=72).contains(&right), "right {right}");
        // The vertical axis fills the fit exactly, so its fractions are
        // the natural ones — within the one hundredth the two buffers'
        // different pixel heights can round apart by.
        let natural = ink(&rasterize(&d, (100.0, 50.0), Presentation::default())).unwrap();
        assert!((t - natural.1).abs() <= 1, "top {t} vs natural {}", natural.1);
        assert!((b - natural.3).abs() <= 1, "bottom {b} vs natural {}", natural.3);
        // AND THE MARGIN IS UNTOUCHED: nothing drew in the left gutter.
        let w = r.width as usize;
        for y in 0..r.height as usize {
            for x in 0..90 {
                assert_eq!(r.pixels[(y * w + x) * 4 + 3], 0, "margin ink at {x},{y}");
            }
        }
    }
}
