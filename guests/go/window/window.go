// The window conformance scene, Go port — see guests/rust/window.rs
// and tools/scenes/window.steps. The primary surface's props as
// assertions: the title must materialize in the real title bar, the
// advisory 640x400 request must be honored on a desktop.
package window

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

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("window probe").Size(640, 400)
		probe := tx.Signal("window probe")

		tx.Mount(tx.Column(func() {
			tx.Label(probe) // label#0
		}))
	})

	return app
}
