// The progress conformance scene, Go port. See
// guests/rust/progress.rs and tools/scenes/progress.steps.
package progress

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
		tx.Window(0).Title("progress")
		tx.Mount(tx.Column(func() {
			tx.Progress(0.25)                // progress#0
			tx.Progress(0).Indeterminate()   // progress#1
		}))
	})

	return app
}
