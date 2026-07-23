// The select conformance scene, Go port. See
// guests/rust/select.rs and tools/scenes/select.steps.
package main

import (
	"os"
	"runtime"

	kaya "dev.kaya/bindings/go"
)

func init() {
	runtime.LockOSThread()
}

var options = []string{"Red", "Green", "Blue"}

func main() {
	app := kaya.NewApp()

	var picked kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("select")
		picked = tx.Signal("picked: Red")

		tx.Mount(tx.Column(func() {
			tx.Select(options, 0, func(tx *kaya.Tx, index int) {
				tx.Write(picked, "picked: "+options[index])
			})
			tx.Label(picked) // label#0
		}))
	})

	os.Exit(app.Run())
}
