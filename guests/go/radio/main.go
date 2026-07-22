// The radio conformance scene, Go port. See
// guests/rust/radio.rs and tools/scenes/radio.steps.
package main

import (
	"os"
	"runtime"

	kaya "dev.kaya/bindings/go"
)

func init() {
	runtime.LockOSThread()
}

var options = []string{"Small", "Medium", "Large"}

func main() {
	app := kaya.NewApp()

	var size kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.WindowTitle("radio")
		size = tx.Signal("size: Small")

		tx.Mount(tx.Column(func() {
			tx.Radio(options, 0, func(tx *kaya.Tx, index int) {
				tx.Write(size, "size: "+options[index])
			})
			tx.Label(size) // label#0
		}))
	})

	os.Exit(app.Run())
}
