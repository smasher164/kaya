// The canvas conformance scene, Swift port — see guests/rust/canvas.rs
// for the canonical note. The core rasterizes and the backend blits
// (docs/canvas-plan.md §1.1); this guest declares an op stream and never
// touches a pixel.
//
// EVERY COORDINATE IS IN THE VIEWBOX, which is what makes one op stream
// identical on five platforms and in eight languages (§3.2). Nothing here
// knows the canvas's rendered size, and it does not need to — so this
// file is a transliteration of the Rust guest, and the hash
// tools/scenes/canvas.steps freezes is the same string on this lane.

import Foundation

let app = KayaApp()

/// The plot's rectangle inside the viewbox. THE FIGURE IS INSET ON
/// PURPOSE: a drawing that fills its box makes `expect_drawing`'s ink
/// bounds 0,0,100,100 whatever the transform does (§7.2).
let plot = (l: 40.0, t: 10.0, r: 290.0, b: 100.0)

/// The series, in viewbox units. FIXED INPUTS, so the byte-frozen hash
/// stays honest.
let series: [(Double, Double)] = [
    (40.0, 88.0),
    (81.0, 74.0),
    (123.0, 80.0),
    (165.0, 51.0),
    (206.0, 57.0),
    (248.0, 30.0),
    (290.0, 20.0),
]

/// The three gridline heights, which are also the tick label anchors.
let ticks: [(Double, String)] = [(32.0, "$60k"), (55.0, "$40k"), (78.0, "$20k")]

let box = KayaViewbox(300.0, 120.0)

app.build { tx in
    tx.window(title: "canvas", width: 480, height: 360)
    let title = tx.signal(.str("portfolio value"))
    let root = tx.column {
        tx.label(bind: title)  // label#0
        let chart = tx.canvas(box)
        tx.setA11yId(chart, "chart")
        tx.setA11yLabel(chart, "Portfolio value")
        tx.draw(chart) { d in
            // The plot ground: the PLOT RECT, not the box, so the axis
            // gutter stays transparent and the ink bounds are the
            // figure's rather than the viewbox's.
            d.moveTo(plot.l, plot.t)
                .lineTo(plot.r, plot.t)
                .lineTo(plot.r, plot.b)
                .lineTo(plot.l, plot.b)
                .close()
                .fill(.ground, rule: .nonzero)
            // Gridlines, one point wide at every canvas size — a width is
            // in points and does not carry the viewbox stretch (§3.2
            // rule 3).
            for (y, _) in ticks {
                d.moveTo(plot.l, y).lineTo(plot.r, y)
            }
            d.stroke(.grid, width: 1.0)
            // The area under the series, closed down to the plot's
            // baseline and back.
            d.polyline(series)
                .lineTo(plot.r, plot.b)
                .lineTo(plot.l, plot.b)
                .close()
                .fill(.seriesFill, rule: .nonzero)
            d.polyline(series).stroke(.series, width: 2.0)
            // The axis, and its labels in kaya's own embedded face — `""`
            // is the reserved default, so this draws text on a lane whose
            // asset root never staged.
            d.moveTo(plot.l, plot.t).lineTo(plot.l, plot.b).stroke(.axis, width: 1.0)
            d.font(size: 11.0, asset: "", weight: 400)
            for (y, text) in ticks {
                d.text(plot.l - 4.0, y, text, .axis, align: .end, baseline: .middle)
            }
            // And one label in an APP'S OWN face, named as an ordinary
            // asset: the override half of §4.2, and the only way a scene
            // can see that both routes are one resolver.
            d.font(size: 13.0, asset: "fonts/sora-wght.ttf", weight: 700)
            d.text(plot.l + 8.0, plot.t + 3.0, "Q3", .series, align: .start, baseline: .top)
        }
    }
    tx.mount(root)
}

// Nothing to handle: pointer events on a canvas stay deferred, so this
// scene has no occurrence at all (§2.1). The app thread still has to stay
// alive to hold the scene up.
app.run()
