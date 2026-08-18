// The select conformance scene, Go port. See
// guests/rust/select.rs and tools/scenes/select.steps.
package selectscene // `select` is a keyword; C# spells it this way too

import (
	kaya "dev.kaya/bindings/go"
)

var options = []string{"Red", "Green", "Blue"}

func App() *kaya.App {
	app := kaya.NewApp()

	var picked kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("select")
		picked = tx.Signal("picked: Red")

		tx.Mount(tx.Column(func() {
			tx.Select(options, 0, func(tx *kaya.Tx, index int) {
				tx.Write(picked, "picked: "+options[index])
			})
			tx.Label(picked) // label#0
		}))
	})

	return app
}
