//! The canvas size-policy scene (tools/scenes/sizepolicy.steps). ALL FOUR
//! CANVASES GROW, or an ungrown track IS its viewbox and nothing differs.

use kaya::{FillRule, Paint, Viewbox};

/// The declared box of the two CONSTANT-mode canvases.
const BOX: Viewbox = Viewbox(300.0, 120.0);

#[derive(Clone)]
enum Msg {}

/// A rectangle at `l..r` and `t..b` as FRACTIONS of the box.
fn panel(d: &mut kaya::Draw, box_: Viewbox, l: f64, t: f64, r: f64, b: f64, paint: Paint) {
    let (w, h) = (box_.0, box_.1);
    d.move_to(l * w, t * h)
        .line_to(r * w, t * h)
        .line_to(r * w, b * h)
        .line_to(l * w, b * h)
        .close()
        .fill(paint, FillRule::Nonzero);
}

/// The centre probe point is opaque, which is what `expect_ink` rests on,
/// and EVERY VERTICAL EDGE IS 0 OR 1 because a ~90pt track rounds an inset
/// 40 to 39 (docs/traps.md: A canvas's inset edges).
fn figure(d: &mut kaya::Draw, box_: Viewbox) {
    panel(d, box_, 0.05, 0.0, 0.95, 1.0, Paint::Ground);
    panel(d, box_, 0.25, 0.0, 0.75, 1.0, Paint::SeriesFill);
}

/// The bar's RIGHT EDGE is the frame number: the scene asserts exact frames.
fn bar(d: &mut kaya::Draw, box_: Viewbox, frame: u32) {
    let right = 0.35 + 0.10 * f64::from(frame);
    panel(d, box_, 0.25, 0.0, right, 1.0, Paint::Axis);
}

/// The guest reads the time it was HANDED, never a clock of its own.
fn frame_of(time: f64) -> u32 {
    (time * 60.0).round().max(0.0) as u32
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<Msg>::new();
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("sizepolicy").size(480.0, 420.0);
        let root = tx
            .column(|tx| {
                // SCALE, the default: declared by writing nothing.
                let fit = tx
                    .canvas(BOX)
                    .grow(1.0)
                    .a11y_id("fit")
                    .a11y_label("Scaled panel")
                    .id();
                tx.draw(fit, |d| figure(d, BOX));

                // FIXED: drawn at BOX, blitted 1:1, the leftover is margin.
                let mark = tx
                    .canvas(BOX)
                    .grow(1.0)
                    .fixed()
                    .a11y_id("mark")
                    .a11y_label("Fixed mark")
                    .id();
                tx.draw(mark, |d| figure(d, BOX));

                // REDRAW: this viewbox is only the size before the first answer.
                tx.canvas(BOX)
                    .grow(1.0)
                    .a11y_id("live")
                    .a11y_label("Redrawn panel")
                    .on_draw(&msgs, |d, size| figure(d, size));

                // TICK: once a frame, at the time the platform supplied.
                tx.canvas(BOX)
                    .grow(1.0)
                    .a11y_id("clock")
                    .a11y_label("Animated bar")
                    .on_tick(&msgs, |d, size, time| bar(d, size, frame_of(time)));
            })
            .id();
        tx.mount(root);
    });

    // Every occurrence here is a canvas ask, answered inside `next`.
    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
