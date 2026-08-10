// The radio conformance scene, Go port. See
// guests/rust/radio.rs and tools/scenes/radio.steps.
package radio

import (
	kaya "dev.kaya/bindings/go"
)

var options = []string{"Small", "Medium", "Large"}

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

	var size kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("radio")
		size = tx.Signal("size: Small")

		tx.Mount(tx.Column(func() {
			tx.Radio(options, 0, func(tx *kaya.Tx, index int) {
				tx.Write(size, "size: "+options[index])
			})
			tx.Label(size) // label#0
		}))
	})

	return app
}
