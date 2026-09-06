// The adaptive conformance scene (tools/scenes/adaptive.steps): row@dash
// flips by a HANDLER, row@narrow by the compact breakpoint.
package adaptive

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	var dash kaya.Widget
	vertical := false
	app.Build(func(tx *kaya.Tx) {
		// Must start ABOVE the breakpoint, so the resize crosses it.
		tx.Window(0).Title("adaptive").Size(900, 600)

		alpha := tx.Signal("alpha")
		longer := tx.Signal("a longer label")
		steady := tx.Signal("steady")

		tx.Mount(tx.Column(func() {
			dash = tx.Row(func() { // row#0: the flip subject.
				tx.Label(alpha)  // label#0
				tx.Label(longer) // label#1
			}).A11yID("dash")
			// column#1: the control group, whose axis never moves.
			tx.Column(func() {
				tx.Label(steady) // label#2
			}).A11yID("steady")
			tx.Button("flip", func(tx *kaya.Tx) { // button#0
				vertical = !vertical
				if vertical {
					tx.SetAxis(dash, kaya.AxisVertical)
				} else {
					tx.SetAxis(dash, kaya.AxisHorizontal)
				}
			})
			// row#1: the BREAKPOINT subject; the handler never touches it.
			tx.Row(func() {
				one := tx.Signal("one")
				two := tx.Signal("a wider two")
				tx.Label(one) // label#3
				tx.Label(two) // label#4
			}).A11yID("narrow").StackWhen(kaya.SizeClassCompact)
			// grid@sheet: three columns regular, one compact (D6.2).
			tx.Grid(3, func() {
				for _, text := range []string{"c1", "c2", "c3", "c4", "c5", "c6"} {
					tx.Label(tx.Signal(text)) // label#5..#10
				}
			}).A11yID("sheet").ColumnsWhen(kaya.SizeClassCompact, 1)
		}))
	})

	return app
}
