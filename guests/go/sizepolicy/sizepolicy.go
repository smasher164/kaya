// The canvas SIZE-POLICY scene, Go port (docs/canvas-plan.md §3.2.1):
// what a canvas does when layout gives it a track that is not its
// viewbox. See guests/rust/sizepolicy.rs and tools/scenes/sizepolicy.steps.
//
// ALL FOUR CANVASES GROW, which is the only reason the scene can see
// anything: an ungrown canvas is its natural size — content is the
// floor — so its track IS its viewbox and every policy agrees.
//
// EVERY FIGURE IS DRAWN IN FRACTIONS OF THE BOX IT IS HANDED, which is
// why one frozen expectation serves four different tracks.
package sizepolicy

import (
	"math"

	kaya "dev.kaya/bindings/go"
)

// The declared box of the two CONSTANT-mode canvases. A `scale` canvas
// keeps drawing in it at any size and a `fixed` one refuses to leave it,
// so it is the one number the two of them disagree about.
var box = kaya.Viewbox{W: 300, H: 120}

// An axis-aligned rectangle at l..r and t..b as FRACTIONS of the box,
// filled with one paint role.
func panel(d *kaya.Draw, box kaya.Viewbox, l, t, r, b float64, paint kaya.Paint) {
	w, h := box.W, box.H
	d.MoveTo(l*w, t*h).
		LineTo(r*w, t*h).
		LineTo(r*w, b*h).
		LineTo(l*w, b*h).
		Close().
		Fill(paint, kaya.FillRuleNonzero)
}

// The figure the three drawing canvases share: a ground panel inset a
// twentieth of the WIDTH with a translucent series panel over its middle
// half. The centre probe point is opaque, which is what expect_ink rests
// on.
func figure(d *kaya.Draw, box kaya.Viewbox) {
	panel(d, box, 0.05, 0, 0.95, 1, kaya.PaintGround)
	panel(d, box, 0.25, 0, 0.75, 1, kaya.PaintSeriesFill)
}

// The animating canvas's bar, whose RIGHT EDGE is the frame number: 35
// hundredths plus ten per frame. The scene asserts exact frames, so a
// clock that free-ran would put the edge somewhere else entirely.
func bar(d *kaya.Draw, box kaya.Viewbox, frame int) {
	right := 0.35 + 0.10*float64(frame)
	panel(d, box, 0.25, 0, right, 1, kaya.PaintAxis)
}

// Seconds back to the frame the harness drove. The clock is the core's
// HARNESS_FRAME_HZ; the guest reads the time it was HANDED and never one
// of its own (docs/canvas-plan.md §15.4).
func frameOf(time float64) int {
	f := math.Round(time * 60)
	if f < 0 {
		f = 0
	}
	return int(f)
}

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("sizepolicy").Size(480, 420)

		tx.Mount(tx.Column(func() {
			// SCALE, the default: nothing is declared, and the core
			// re-rasterizes this same display list at whatever track the
			// column hands over, fitted uniformly and centred.
			fit := tx.Canvas(box).Grow(1).A11yID("fit").A11yLabel("Scaled panel")
			tx.Draw(fit, func(d *kaya.Draw) { figure(d, box) })

			// FIXED: the one true property. This one draws at box
			// whatever the column does with it, and the backend blits it
			// 1:1 with the leftover as margin.
			mark := tx.Canvas(box).Grow(1).Fixed().A11yID("mark").A11yLabel("Fixed mark")
			tx.Draw(mark, func(d *kaya.Draw) { figure(d, box) })

			// REDRAW: the drawing IS a function of size, and saying so is
			// providing the function. The viewbox declared here is only
			// the size before the first answer.
			tx.Canvas(box).Grow(1).A11yID("live").A11yLabel("Redrawn panel").
				OnDraw(func(d *kaya.Draw, size kaya.Viewbox) { figure(d, size) })

			// TICK: the same, once a frame, at the time the platform
			// supplied. Under the harness that clock is the core's own
			// step and a verb advances it.
			tx.Canvas(box).Grow(1).A11yID("clock").A11yLabel("Animated bar").
				OnTick(func(d *kaya.Draw, size kaya.Viewbox, time float64) {
					bar(d, size, frameOf(time))
				})
		}))
	})

	return app
}
