// The radio conformance scene, Go port. See
// guests/rust/radio.rs and tools/scenes/radio.steps.
package radio

import (
	kaya "dev.kaya/bindings/go"
)

var options = []string{"Small", "Medium", "Large"}

func App() *kaya.App {
	app := kaya.NewApp()

	var size kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("radio")
		size = tx.Signal("size: Small")

		tx.Mount(tx.Column(func() {
			tx.Radio(options, 0, func(tx *kaya.Tx, index int) {
				tx.Write(size, "size: "+options[index])
			})
			tx.Label(size) // label#0
		}))
	})

	return app
}
