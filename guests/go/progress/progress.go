// The progress conformance scene, Go port. See
// guests/rust/progress.rs and tools/scenes/progress.steps.
package progress

import (
	kaya "dev.kaya/bindings/go"
)

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
