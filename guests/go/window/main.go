// The window conformance scene, Go port — see guests/rust/window.rs
// and tools/scenes/window.steps. The primary surface's props as
// assertions: the title must materialize in the real title bar, the
// advisory 640x400 request must be honored on a desktop.
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
		tx.WindowTitle("window probe")
		tx.WindowSize(640, 400)
		probe := tx.Signal("window probe")

		tx.Mount(tx.Column(func() {
			tx.Label(probe) // label#0
		}))
	})

	os.Exit(app.Run())
}
