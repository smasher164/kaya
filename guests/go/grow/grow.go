// The grow conformance scene, Go port — every child of the column and
// of the row is a grower, so each split is exactly weight/Σweight.
// See guests/rust/grow.rs and tools/scenes/grow.steps.
package grow

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		probe := tx.Signal("grow probe")
		one := tx.Signal("one")

		tx.Mount(tx.Column(func() {
			tx.Label(probe).Grow(1)   // label#0
			tx.Textarea(nil).Grow(2)  // textarea#0
			tx.Row(func() {
				tx.Label(one).Grow(1) // label#1
				tx.Button("three", nil).Grow(3)
			}).Grow(1).Spacing(12)
		}))
	})

	return app
}
