// The scroll conformance scene (tools/scenes/scroll.steps). The viewport
// GROWS: unconstrained it hugs its content and nothing overflows.
package scroll

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

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
