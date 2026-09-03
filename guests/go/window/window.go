// The window conformance scene (tools/scenes/window.steps): the title and
// the advisory 640x400 must both materialize.
package window

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("window probe").Size(640, 400)
		probe := tx.Signal("window probe")

		tx.Mount(tx.Column(func() {
			tx.Label(probe) // label#0
		}))
	})

	return app
}
