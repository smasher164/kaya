// The adaptive conformance scene, Go port — see guests/rust/adaptive.rs
// for the full rationale. row@dash flips by a HANDLER (D2's user-driven
// toggle); row@narrow carries the breakpoint (D3, size classes ruled
// 2026-08-31): StackWhen(kaya.SizeClassCompact) stacks it vertically
// while the window's size class is compact (below 600 points on every
// desktop) and reverts on leaving the class. tools/scenes/adaptive.steps is the
// byte-frozen contract.
package adaptive

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	var dash kaya.Widget
	vertical := false
	app.Build(func(tx *kaya.Tx) {
		// Explicit size: the desktop start must sit ABOVE the
		// breakpoint's threshold so the scene's resize half crosses it
		// both ways deterministically.
		tx.Window(0).Title("adaptive").Size(900, 600)

		alpha := tx.Signal("alpha")
		longer := tx.Signal("a longer label")
		steady := tx.Signal("steady")

		tx.Mount(tx.Column(func() {
			dash = tx.Row(func() { // row#0: the flip subject.
				tx.Label(alpha)  // label#0
				tx.Label(longer) // label#1
			}).A11yID("dash")
			// column#1: the control group — its axis answers the
			// creation kind's own and never moves.
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
			// row#1: the BREAKPOINT subject (D3) — the handler never
			// touches it.
			tx.Row(func() {
				one := tx.Signal("one")
				two := tx.Signal("a wider two")
				tx.Label(one) // label#3
				tx.Label(two) // label#4
			}).A11yID("narrow").StackWhen(kaya.SizeClassCompact)
		}))
	})

	return app
}
