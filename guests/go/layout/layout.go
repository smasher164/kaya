// The layout scene (tools/scenes/layout.steps). It asserts NO geometry:
// container targets are ordinal, and that differs per language.
package layout

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		probe := tx.Signal("Layout probe")
		tail := tx.Signal("tail")
		mixed := tx.Signal("mixed")
		nested := tx.Signal("nested")
		deep := tx.Signal("deep")

		tx.Mount(tx.Column(func() {
			tx.Label(probe) // label#0

			tx.Row(func() {
				tx.Button("A", nil)
				tx.Button("longer", nil)
				tx.Label(tail) // label#1
			})

			tx.Row(func() {
				tx.Checkbox("check", nil)
				tx.Label(mixed) // label#2
				tx.Slider(0.0, 1.0, 0.5, nil).Grow(1)
			})

			tx.Row(func() {
				tx.Slider(0.0, 1.0, 0.25, nil).Grow(1)
				tx.Slider(0.0, 1.0, 0.75, nil).Grow(3)
			})

			tx.Column(func() {
				tx.Label(nested) // label#3
				tx.Row(func() {
					tx.Label(deep) // label#4
					tx.Button("x", nil)
				})
			})
		}))
	})

	return app
}
