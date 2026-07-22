// The scroll conformance scene, Go port — the viewport grows so the
// enclosing track constrains it (an unconstrained viewport hugs its
// content and nothing overflows); the bottom button, reachable only
// by scrolling, proves the scrolled-to content is live. See
// guests/rust/scroll.rs and tools/scenes/scroll.steps.
package main

import (
	"fmt"
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
		tx.WindowTitle("scroll")
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

	os.Exit(app.Run())
}
