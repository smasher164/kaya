//! The canvas depth scene (tools/scenes/canvas.steps). EVERY COORDINATE IS
//! IN THE VIEWBOX: nothing here knows the canvas's rendered size.

use kaya::{FillRule, Paint, TextAlign, TextBaseline, Viewbox};

/// INSET ON PURPOSE: a drawing that fills its box reads 0,0,100,100.
const PLOT: (f64, f64, f64, f64) = (40.0, 10.0, 290.0, 100.0);

/// In viewbox units, and FIXED, so the byte-frozen hash stays honest.
const SERIES: [(f64, f64); 7] = [
    (40.0, 88.0),
    (81.0, 74.0),
    (123.0, 80.0),
    (165.0, 51.0),
    (206.0, 57.0),
    (248.0, 30.0),
    (290.0, 20.0),
];

/// The gridline heights, which are also the tick label anchors.
const TICKS: [(f64, &str); 3] = [(32.0, "$60k"), (55.0, "$40k"), (78.0, "$20k")];

const BOX: Viewbox = Viewbox(300.0, 120.0);

pub(crate) fn app(ctx: kaya::AppCtx) {
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("canvas").size(480.0, 360.0);
        let title = tx.signal("portfolio value");
        let root = tx
            .column(|tx| {
                tx.label(title); // label#0
                let chart = tx.canvas(BOX).a11y_id("chart").a11y_label("Portfolio value").id();
                tx.draw(chart, |d| {
                    let (l, t, r, b) = PLOT;
                    // The PLOT RECT, not the box: the gutter stays clear.
                    d.move_to(l, t)
                        .line_to(r, t)
                        .line_to(r, b)
                        .line_to(l, b)
                        .close()
                        .fill(Paint::Ground, FillRule::Nonzero);
                    // A width is in points and takes no viewbox stretch.
                    for (y, _) in TICKS {
                        d.move_to(l, y).line_to(r, y);
                    }
                    d.stroke(Paint::Grid, 1.0);
                    d.polyline(&SERIES)
                        .line_to(r, b)
                        .line_to(l, b)
                        .close()
                        .fill(Paint::SeriesFill, FillRule::Nonzero);
                    d.polyline(&SERIES).stroke(Paint::Series, 2.0);
                    // `""` is the reserved default face, so these draw with
                    // no asset staged.
                    d.move_to(l, t).line_to(l, b).stroke(Paint::Axis, 1.0);
                    d.font("", 11.0, 400);
                    for (y, text) in TICKS {
                        d.text(l - 4.0, y, text, Paint::Axis, TextAlign::End, TextBaseline::Middle);
                    }
                    // TOP-LEFT, NOT TOP-RIGHT: trailing-anchored it sat on
                    // the series, with every assertion green through it.
                    d.font("fonts/sora-wght.ttf", 13.0, 700);
                    d.text(l + 8.0, t + 3.0, "Q3", Paint::Series, TextAlign::Start, TextBaseline::Top);
                });
            })
            .id();
        tx.mount(root);
    });

    // No occurrence at all: the app thread just holds the scene up.
    loop {
        let _ = ctx.next();
    }
}

fn main() {
    kaya::run(app)
}
