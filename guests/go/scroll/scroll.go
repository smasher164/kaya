// The scroll conformance scene, Go port — the viewport grows so the
// enclosing track constrains it (an unconstrained viewport hugs its
// content and nothing overflows); the bottom button, reachable only
// by scrolling, proves the scrolled-to content is live. See
// guests/rust/scroll.rs and tools/scenes/scroll.steps.
package scroll

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

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

	var status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("scroll")
		status = tx.Signal("at top")

		tx.Mount(tx.Column(func() {
			tx.Label(status) // label#0
			tx.Scroll(func() { // scroll#0
				tx.Column(func() {
					for i := 1; i <= 29; i++ {
						caption := tx.Signal(fmt.Sprintf("row %d", i))
						tx.Label(caption)
					}
					tx.Button("bottom", func(tx *kaya.Tx) { // button#0
						tx.Write(status, "bottom clicked")
					})
				})
			}).Grow(1)
		}))
	})

	return app
}
