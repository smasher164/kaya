// The canvas size-policy scene (tools/scenes/sizepolicy.steps). ALL FOUR
// CANVASES GROW, or an ungrown track IS its viewbox and nothing differs.
package sizepolicy

import (
	"math"

	kaya "dev.kaya/bindings/go"
)

// The declared box of the two CONSTANT-mode canvases.
var box = kaya.Viewbox{W: 300, H: 120}

// A rectangle at l..r and t..b as FRACTIONS of the box.
func panel(d *kaya.Draw, box kaya.Viewbox, l, t, r, b float64, paint kaya.Paint) {
	w, h := box.W, box.H
	d.MoveTo(l*w, t*h).
		LineTo(r*w, t*h).
		LineTo(r*w, b*h).
		LineTo(l*w, b*h).
		Close().
		Fill(paint, kaya.FillRuleNonzero)
}

// The centre probe point is opaque, which is what expect_ink rests on.
func figure(d *kaya.Draw, box kaya.Viewbox) {
	panel(d, box, 0.05, 0, 0.95, 1, kaya.PaintGround)
	panel(d, box, 0.25, 0, 0.75, 1, kaya.PaintSeriesFill)
}

// The bar's RIGHT EDGE is the frame number: the scene asserts exact frames.
func bar(d *kaya.Draw, box kaya.Viewbox, frame int) {
	right := 0.35 + 0.10*float64(frame)
	panel(d, box, 0.25, 0, right, 1, kaya.PaintAxis)
}

// The guest reads the time it was HANDED, never a clock of its own.
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
			// SCALE, the default: declared by writing nothing.
			fit := tx.Canvas(box).Grow(1).A11yID("fit").A11yLabel("Scaled panel")
			tx.Draw(fit, func(d *kaya.Draw) { figure(d, box) })

			// FIXED: drawn at box, blitted 1:1, the leftover is margin.
			mark := tx.Canvas(box).Grow(1).Fixed().A11yID("mark").A11yLabel("Fixed mark")
			tx.Draw(mark, func(d *kaya.Draw) { figure(d, box) })

			// REDRAW: this viewbox is only the size before the first answer.
			tx.Canvas(box).Grow(1).A11yID("live").A11yLabel("Redrawn panel").
				OnDraw(func(d *kaya.Draw, size kaya.Viewbox) { figure(d, size) })

			// TICK: once a frame, at the time the platform supplied.
			tx.Canvas(box).Grow(1).A11yID("clock").A11yLabel("Animated bar").
				OnTick(func(d *kaya.Draw, size kaya.Viewbox, time float64) {
					bar(d, size, frameOf(time))
				})
		}))
	})

	return app
}
