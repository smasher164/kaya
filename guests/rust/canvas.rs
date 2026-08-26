//! The canvas depth scene (docs/canvas-plan.md): a small value-over-time
//! chart, drawn by the CORE and blitted by the backend. The byte-frozen
//! contract is tools/scenes/canvas.steps.
//!
//! IT DRAWS THE PORTFOLIO CHART'S VOCABULARY, not a test figure, because
//! that is the artifact this feature exists for (§10): a filled area
//! under a polyline, gridlines, an axis, and tick labels in two faces —
//! kaya's embedded default and an app-supplied asset override.
//!
//! EVERY COORDINATE IS IN THE VIEWBOX, which is what makes one op stream
//! identical on five platforms and in eight languages (§3.2). Nothing
//! here knows the canvas's rendered size, and it does not need to: the
//! core rasterizes at box-times-scale and the backend blits.

use kaya::{FillRule, Paint, TextAlign, TextBaseline, Viewbox};

/// The plot's rectangle inside the viewbox. THE FIGURE IS INSET ON
/// PURPOSE: a drawing that fills its box makes `expect_drawing`'s ink
/// bounds 0,0,100,100 whatever the transform does, and an inverted y
/// axis or a drawing pushed into a corner would then move nothing the
/// scene can see (docs/canvas-plan.md §7.2).
const PLOT: (f64, f64, f64, f64) = (40.0, 10.0, 290.0, 100.0);

/// The series, in viewbox units. FIXED INPUTS, so the byte-frozen hash
/// stays honest — the portfolio's own standing discipline
/// (docs/portfolio-plan.md §0).
const SERIES: [(f64, f64); 7] = [
    (40.0, 88.0),
    (81.0, 74.0),
    (123.0, 80.0),
    (165.0, 51.0),
    (206.0, 57.0),
    (248.0, 30.0),
    (290.0, 20.0),
];

/// The three gridline heights, which are also the tick label anchors.
const TICKS: [(f64, &str); 3] = [(32.0, "$60k"), (55.0, "$40k"), (78.0, "$20k")];

const BOX: Viewbox = Viewbox(300.0, 120.0);

pub(crate) fn app(ctx: kaya::AppCtx) {
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("canvas").size(480.0, 360.0);
        // The asset-override face, read through the one resolver: an
        // app's own typeface is an ordinary asset name, and the drawing
        // declares what it draws with (§4.2).
        let title = tx.signal("portfolio value");
        let root = tx
            .column(|tx| {
                tx.label(title); // label#0
                let chart = tx.canvas(BOX).a11y_id("chart").a11y_label("Portfolio value").id();
                tx.draw(chart, |d| {
                    let (l, t, r, b) = PLOT;
                    // The plot ground: the PLOT RECT, not the box, so
                    // the axis gutter stays transparent and the ink
                    // bounds are the figure's rather than the viewbox's.
                    d.move_to(l, t)
                        .line_to(r, t)
                        .line_to(r, b)
                        .line_to(l, b)
                        .close()
                        .fill(Paint::Ground, FillRule::Nonzero);
                    // Gridlines, one point wide at every canvas size — a
                    // width is in points and does not carry the viewbox
                    // stretch (§3.2 rule 3).
                    for (y, _) in TICKS {
                        d.move_to(l, y).line_to(r, y);
                    }
                    d.stroke(Paint::Grid, 1.0);
                    // The area under the series, closed down to the
                    // plot's baseline and back.
                    d.polyline(&SERIES)
                        .line_to(r, b)
                        .line_to(l, b)
                        .close()
                        .fill(Paint::SeriesFill, FillRule::Nonzero);
                    d.polyline(&SERIES).stroke(Paint::Series, 2.0);
                    // The axis, and its labels in kaya's own embedded
                    // face — `""` is the reserved default, so this draws
                    // text on a lane whose asset root never staged.
                    d.move_to(l, t).line_to(l, b).stroke(Paint::Axis, 1.0);
                    d.font("", 11.0, 400);
                    for (y, text) in TICKS {
                        d.text(l - 4.0, y, text, Paint::Axis, TextAlign::End, TextBaseline::Middle);
                    }
                    // And one label in an APP'S OWN face, named as an
                    // ordinary asset: the override half of §4.2, and the
                    // only way a scene can see that both routes are one
                    // resolver.
                    //
                    // TOP-LEFT, NOT TOP-RIGHT: the first capture had it
                    // trailing-anchored and it sat on top of the series,
                    // which every scene assertion was green through —
                    // the look-bug class §7.3 says only a human looking
                    // at a picture catches.
                    d.font("fonts/sora-wght.ttf", 13.0, 700);
                    d.text(l + 8.0, t + 3.0, "Q3", Paint::Series, TextAlign::Start, TextBaseline::Top);
                });
            })
            .id();
        tx.mount(root);
    });

    // Nothing to handle: pointer events on a canvas stay deferred, so
    // this scene has no occurrence at all (§2.1). The app thread still
    // has to stay alive to hold the scene up.
    loop {
        let _ = ctx.next();
    }
}

fn main() {
    kaya::run(app)
}
