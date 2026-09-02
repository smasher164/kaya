// The canvas SIZE-POLICY scene, Swift port — see guests/rust/sizepolicy.rs
// for the canonical note. What a canvas does when layout gives it a track
// that is not its viewbox (docs/canvas-plan.md §3.2.1); the byte-frozen
// contract is tools/scenes/sizepolicy.steps.
//
// ALL FOUR CANVASES GROW, which is the only reason the scene can see
// anything: an ungrown canvas is its natural size, so its track IS its
// viewbox and every policy agrees.
//
// EVERY FIGURE IS DRAWN IN FRACTIONS OF THE BOX IT IS HANDED, so the
// normalized ink bounds are one frozen string though the four tracks
// differ on every platform.

import Foundation

let app = KayaApp()

/// The declared box of the two CONSTANT-mode canvases. A `scale` canvas
/// keeps drawing in it at any size and a `fixed` one refuses to leave it,
/// so it is the one number the two of them disagree about.
let box = KayaViewbox(300.0, 120.0)

/// An axis-aligned rectangle at `l..r` and `t..b` as FRACTIONS of the box,
/// filled with one paint role.
func panel(
    _ d: KayaDraw, _ box: KayaViewbox,
    _ l: Double, _ t: Double, _ r: Double, _ b: Double, _ paint: KayaPaint
) {
    let (w, h) = (box.w, box.h)
    d.moveTo(l * w, t * h)
        .lineTo(r * w, t * h)
        .lineTo(r * w, b * h)
        .lineTo(l * w, b * h)
        .close()
        .fill(paint, rule: .nonzero)
}

/// The figure the three drawing canvases share: a ground panel inset a
/// twentieth of the WIDTH with a translucent series panel over its middle
/// half. The centre probe point is opaque, which is what `expect_ink`
/// rests on.
///
/// EVERY VERTICAL EDGE IS 0 OR 1, and that is arithmetic rather than
/// taste — see the Rust guest's derivation note: `expect_drawing` rounds
/// the ink bounds to hundredths of the box, and four grown canvases in a
/// 420pt window are short enough that an inset horizontal edge would
/// round away.
func figure(_ d: KayaDraw, _ box: KayaViewbox) {
    panel(d, box, 0.05, 0.0, 0.95, 1.0, .ground)
    panel(d, box, 0.25, 0.0, 0.75, 1.0, .seriesFill)
}

/// The animating canvas's bar, whose RIGHT EDGE is the frame number: 35
/// hundredths plus ten per frame. The scene asserts exact frames, so a
/// clock that free-ran would put the edge somewhere else entirely.
func bar(_ d: KayaDraw, _ box: KayaViewbox, _ frame: UInt32) {
    let right = 0.35 + 0.10 * Double(frame)
    panel(d, box, 0.25, 0.0, right, 1.0, .axis)
}

/// Seconds back to the frame the harness drove. The clock is the core's
/// `KAYA_HARNESS_FRAME_HZ`; the guest reads the time it was HANDED and never
/// one of its own.
func frameOf(_ time: Double) -> UInt32 {
    UInt32(max((time * 60.0).rounded(), 0.0))
}

app.build { tx in
    tx.window(title: "sizepolicy", width: 480, height: 420)
    let root = tx.column {
        // SCALE, the default: nothing is declared, and the core
        // re-rasterizes this same display list at whatever track the
        // column hands over, fitted uniformly and centred.
        let fit = tx.canvas(box, grow: 1.0)
        tx.setA11yId(fit, "fit")
        tx.setA11yLabel(fit, "Scaled panel")
        tx.draw(fit) { d in figure(d, box) }

        // FIXED: the one true property. This one draws at `box` whatever
        // the column does with it, and the backend blits it 1:1 with the
        // leftover as margin.
        let mark = tx.canvas(box, grow: 1.0).fixed()
        tx.setA11yId(mark, "mark")
        tx.setA11yLabel(mark, "Fixed mark")
        tx.draw(mark) { d in figure(d, box) }

        // REDRAW: the drawing IS a function of size, and saying so is
        // providing the function. The viewbox declared here is only the
        // size before the first answer.
        let live = tx.canvas(box, grow: 1.0)
        tx.setA11yId(live, "live")
        tx.setA11yLabel(live, "Redrawn panel")
        live.onDraw { d, size in figure(d, size) }

        // TICK: the same, once a frame, at the time the platform supplied.
        // Under the harness that clock is the core's own step and a verb
        // advances it.
        let clock = tx.canvas(box, grow: 1.0)
        tx.setA11yId(clock, "clock")
        tx.setA11yLabel(clock, "Animated bar")
        clock.onTick { d, size, time in bar(d, size, frameOf(time)) }
    }
    tx.mount(root)
}

// Every occurrence this scene has is a canvas ask, and the binding answers
// those inside its own dispatch loop — this call is what keeps the app
// thread alive to hold the scene up.
app.run()
