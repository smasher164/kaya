// The sizepolicy scene, Swift port — guests/rust/sizepolicy.rs,
// tools/scenes/sizepolicy.steps.

import Foundation

let app = KayaApp()

/// The declared box of the two CONSTANT-mode canvases: the one number `scale`
/// and `fixed` disagree about.
let box = KayaViewbox(300.0, 120.0)

/// A rectangle at `l..r` and `t..b` as FRACTIONS of the box.
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

/// The figure the three drawing canvases share. The centre probe point is
/// opaque, which `expect_ink` rests on, and EVERY VERTICAL EDGE IS 0 OR 1:
/// `expect_drawing` rounds ink bounds to hundredths, so an inset horizontal
/// edge would round away (the Rust guest derives it).
func figure(_ d: KayaDraw, _ box: KayaViewbox) {
    panel(d, box, 0.05, 0.0, 0.95, 1.0, .ground)
    panel(d, box, 0.25, 0.0, 0.75, 1.0, .seriesFill)
}

/// The bar whose RIGHT EDGE is the frame number; the scene asserts exact
/// frames.
func bar(_ d: KayaDraw, _ box: KayaViewbox, _ frame: UInt32) {
    let right = 0.35 + 0.10 * Double(frame)
    panel(d, box, 0.25, 0.0, right, 1.0, .axis)
}

/// Seconds back to the frame the harness drove, off the time the guest was
/// HANDED and never a clock of its own.
func frameOf(_ time: Double) -> UInt32 {
    UInt32(max((time * 60.0).rounded(), 0.0))
}

app.build { tx in
    tx.window(title: "sizepolicy", width: 480, height: 420)
    let root = tx.column {
        // SCALE (the default)
        let fit = tx.canvas(box, grow: 1.0)
        tx.setA11yId(fit, "fit")
        tx.setA11yLabel(fit, "Scaled panel")
        tx.draw(fit) { d in figure(d, box) }

        // FIXED
        let mark = tx.canvas(box, grow: 1.0).fixed()
        tx.setA11yId(mark, "mark")
        tx.setA11yLabel(mark, "Fixed mark")
        tx.draw(mark) { d in figure(d, box) }

        // REDRAW
        let live = tx.canvas(box, grow: 1.0)
        tx.setA11yId(live, "live")
        tx.setA11yLabel(live, "Redrawn panel")
        live.onDraw { d, size in figure(d, size) }

        // TICK: under the harness the clock is the core's own step.
        let clock = tx.canvas(box, grow: 1.0)
        tx.setA11yId(clock, "clock")
        tx.setA11yLabel(clock, "Animated bar")
        clock.onTick { d, size, time in bar(d, size, frameOf(time)) }
    }
    tx.mount(root)
}

app.run()
