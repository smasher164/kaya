// The panels conformance scene, Go port — the auxiliary-window
// grammar via the chain spelling. See guests/rust/panels.rs and
// tools/scenes/panels.steps.
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

	var status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.WindowTitle("panels")
		status = tx.Signal("two panels")

		tx.Mount(tx.Column(func() {
			tx.Label(status) // label#0
		}))

		inspector := tx.CreateWindow(1).
			Title("inspector").
			Size(480, 320).
			VetoClose(true)
		aux := tx.Column(func() {
			caption := tx.Signal("inspector pane")
			tx.Label(caption) // label#1
		})
		tx.MountIn(inspector.Id(), aux)
	})

	app.OnCloseRequested(func(tx *kaya.Tx, window uint64) {
		tx.Write(status, "close requested")
		tx.DestroyWindow(window)
	})

	os.Exit(app.Run())
}
