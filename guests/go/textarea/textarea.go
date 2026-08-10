// The textarea conformance scene, Go port. See
// guests/rust/textarea.rs and tools/scenes/textarea.steps.
package textarea

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

func count(text string) string {
	if text == "" {
		return "0 lines"
	}
	return fmt.Sprintf("%d lines", len(strings.Split(strings.TrimSuffix(text, "\n"), "\n")))
}

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

	var lines kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("textarea")
		lines = tx.Signal("0 lines")

		tx.Mount(tx.Column(func() {
			editor := tx.Textarea(func(tx *kaya.Tx, text string) {
				tx.Write(lines, count(text))
			})
			tx.Label(lines) // label#0
			tx.Button("clear", func(tx *kaya.Tx) {
				tx.Clear(editor)
				tx.Focus(editor)
			})
		}))
	})

	return app
}
