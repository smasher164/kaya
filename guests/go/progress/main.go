// The progress conformance scene, Go port. See
// guests/rust/progress.rs and tools/scenes/progress.steps.
package main

import (
	"os"
	"runtime"

	kaya "dev.kaya/bindings/go"
)

func init() {
	runtime.LockOSThread()
}

func main() {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.WindowTitle("progress")
		tx.Mount(tx.Column(func() {
			tx.Progress(0.25)                // progress#0
			tx.Progress(0).Indeterminate()   // progress#1
		}))
	})

	os.Exit(app.Run())
}
