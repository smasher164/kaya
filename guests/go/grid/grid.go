// The grid conformance scene, Go port. See
// guests/rust/grid.rs and tools/scenes/grid.steps.
package grid

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("grid")
		tx.Mount(tx.Column(func() {
			tx.Grid(2, func() {
				tx.LabelText("Name:")             // label#0
				tx.LabelText("Ada Lovelace")      // label#1
				tx.LabelText("Role:")             // label#2
				tx.LabelText("Engine programmer") // label#3
			})
			tx.Row(func() {
				tx.Button("left", nil) // button#0
				tx.Spacer()
				tx.Button("right", nil) // button#1
			}).Grow(1)
		}))
	})

	return app
}
