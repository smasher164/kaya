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

	os.Exit(app.Run())
}
