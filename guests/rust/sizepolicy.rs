//! The canvas SIZE-POLICY scene (docs/canvas-plan.md §3.2.1): what a
//! canvas does when layout gives it a track that is not its viewbox.
//! The byte-frozen contract is tools/scenes/sizepolicy.steps.
//!
//! ALL FOUR CANVASES GROW, which is the only reason the scene can see
//! anything: an ungrown canvas is its natural size — content is the
//! floor — so its track IS its viewbox and every policy agrees. That is
//! also why no scene in the tree could reach this before
//! (docs/deferred.md, "A canvas STRETCHES ITS BUFFER").
//!
//! EVERY FIGURE IS DRAWN IN FRACTIONS OF THE BOX IT IS HANDED, so the
//! normalized ink bounds are one frozen string though the four tracks
//! differ on every platform (§7.1's amendment: a redraw canvas trades
//! the drawing hash for §7.2's pair, deliberately and out loud).

use kaya::{FillRule, Paint, Viewbox};

/// The declared box of the two CONSTANT-mode canvases. A `scale` canvas
/// keeps drawing in it at any size and a `fixed` one refuses to leave
/// it, so it is the one number the two of them disagree about.
const BOX: Viewbox = Viewbox(300.0, 120.0);

#[derive(Clone)]
enum Msg {}

/// An axis-aligned rectangle at `l..r` and `t..b` as FRACTIONS of the
/// box, filled with one paint role.
fn panel(d: &mut kaya::Draw, box_: Viewbox, l: f64, t: f64, r: f64, b: f64, paint: Paint) {
    let (w, h) = (box_.0, box_.1);
    d.move_to(l * w, t * h)
        .line_to(r * w, t * h)
        .line_to(r * w, b * h)
        .line_to(l * w, b * h)
        .close()
        .fill(paint, FillRule::Nonzero);
}

/// The figure the three drawing canvases share: a ground panel inset a
/// twentieth of the WIDTH with a translucent series panel over its
/// middle half. The centre probe point is opaque — the ground is opaque
/// and the series fill blends onto it — which is what `expect_ink` rests
/// on.
///
/// EVERY VERTICAL EDGE IS 0 OR 1, and that is arithmetic rather than
/// taste. `expect_drawing` rounds the ink bounds to HUNDREDTHS of the
/// box, so an inset edge is stable only while the box is wide enough
/// that one pixel is under half a hundredth — and four grown canvases
/// in a 420pt window are about 90pt tall each, where one pixel is 1.1
/// hundredths and a 40 rounds to 39 (measured, this file's derivation
/// test at 461x87). The horizontal edges are the discriminating ones
/// and the tracks are wide.
fn figure(d: &mut kaya::Draw, box_: Viewbox) {
    panel(d, box_, 0.05, 0.0, 0.95, 1.0, Paint::Ground);
    panel(d, box_, 0.25, 0.0, 0.75, 1.0, Paint::SeriesFill);
}

/// The animating canvas's bar, whose RIGHT EDGE is the frame number:
/// 35 hundredths plus ten per frame. The scene asserts exact frames, so
/// a clock that free-ran would put the edge somewhere else entirely.
fn bar(d: &mut kaya::Draw, box_: Viewbox, frame: u32) {
    let right = 0.35 + 0.10 * f64::from(frame);
    panel(d, box_, 0.25, 0.0, right, 1.0, Paint::Axis);
}

/// Seconds back to the frame the harness drove. The clock is the core's
/// `HARNESS_FRAME_HZ`; the guest reads the time it was HANDED and never
/// one of its own (§15.4).
fn frame_of(time: f64) -> u32 {
    (time * 60.0).round().max(0.0) as u32
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::<Msg>::new();
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("sizepolicy").size(480.0, 420.0);
        let root = tx
            .column(|tx| {
                // SCALE, the default: nothing is declared, and the core
                // re-rasterizes this same display list at whatever track
                // the column hands over, fitted uniformly and centred.
                let fit = tx
                    .canvas(BOX)
                    .grow(1.0)
                    .a11y_id("fit")
                    .a11y_label("Scaled panel")
                    .id();
                tx.draw(fit, |d| figure(d, BOX));

                // FIXED: the one true property. This one draws at BOX
                // whatever the row does with it, and the backend blits
                // it 1:1 with the leftover as margin.
                let mark = tx
                    .canvas(BOX)
                    .grow(1.0)
                    .fixed()
                    .a11y_id("mark")
                    .a11y_label("Fixed mark")
                    .id();
                tx.draw(mark, |d| figure(d, BOX));

                // REDRAW: the drawing IS a function of size, and saying
                // so is providing the function. The viewbox declared
                // here is only the size before the first answer.
                tx.canvas(BOX)
                    .grow(1.0)
                    .a11y_id("live")
                    .a11y_label("Redrawn panel")
                    .on_draw(&msgs, |d, size| figure(d, size));

                // TICK: the same, once a frame, at the time the platform
                // supplied. Under the harness that clock is the core's
                // own step and a verb advances it.
                tx.canvas(BOX)
                    .grow(1.0)
                    .a11y_id("clock")
                    .a11y_label("Animated bar")
                    .on_tick(&msgs, |d, size, time| bar(d, size, frame_of(time)));
            })
            .id();
        tx.mount(root);
    });

    // Every occurrence this scene has is a canvas ask, and the binding
    // answers those inside `next` — the loop is what keeps the app
    // thread alive to hold the scene up.
    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
