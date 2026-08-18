// The panels conformance scene, Go port — the auxiliary-window
// grammar via the chain spelling. See guests/rust/panels.rs and
// tools/scenes/panels.steps.
package panels

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("panels")
		status = tx.Signal("two panels")

		tx.Mount(tx.Column(func() {
			tx.Label(status) // label#0
		}))

		inspector := tx.CreateWindow(1).
			Title("inspector").
			Size(480, 320).
			VetoClose(true).
			OnCloseRequested(func(tx *kaya.Tx) {
				tx.Write(status, "close requested")
				tx.DestroyWindow(1)
			})
		aux := tx.Column(func() {
			caption := tx.Signal("inspector pane")
			tx.Label(caption) // label#1
		})
		tx.MountIn(inspector.Id(), aux)
	})

	return app
}
