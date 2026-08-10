// The select conformance scene, Go port. See
// guests/rust/select.rs and tools/scenes/select.steps.
package selectscene // `select` is a keyword; C# spells it this way too

import (
	kaya "dev.kaya/bindings/go"
)

var options = []string{"Red", "Green", "Blue"}

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

	return app
}
