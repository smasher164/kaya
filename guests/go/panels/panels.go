// The panels conformance scene, Go port — the auxiliary-window
// grammar via the chain spelling. See guests/rust/panels.rs and
// tools/scenes/panels.steps.
package panels

import (
	kaya "dev.kaya/bindings/go"
)

// App builds the scene and hands it back ready to be served.
//
// THE TAIL IS THE ONLY THING THAT DIFFERS BY PLATFORM, and it differs
// because the hosting does: a desktop or iOS guest owns the process
// main thread and lends it to kaya (guests/go/cmd/main_desktop.go),
// while on Android the OS owns main and kaya starts the guest on a
// thread of its own (guests/go/cmd/main_android.go). Both tails are
// one package over one scene table, so everything above them — the
// transaction, the handlers, the strings — is compiled into every
// platform's artifact from these bytes.
func App() *kaya.App {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("panels")
		status = tx.Signal("two panels")

		tx.Mount(tx.Column(func() {
			tx.Label(status) // label#0
		}))

		// The veto handler binds to the inspector at its
		// declaration (handlers scope to the thing that creates
		// them): it can only ever mean this window's close.
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
