// The gallery scene from Go: a row with a checkbox and its status
// label, and a row with a slider and its volume label. Both controls
// own their state and report each change; the app answers by writing
// the paired signal — the entry's uncontrolled contract, with a bool
// and a float64.
//
// Build the library first (cargo build), then, from the repo root:
//
//	KAYA_SELFTEST=gallery go run crates/kaya/examples/gallery.go
package main

import (
	"fmt"
	"os"
	"runtime"

	kaya "dev.kaya/bindings/go"
)

func init() {
	// The core must own the process main thread.
	runtime.LockOSThread()
}

func main() {
	app := kaya.NewApp()

	// The construction sugar: constructors carry their handlers,
	// containers take their children, and the build body reads as the
	// tree.
	app.Build(func(tx *kaya.Tx) {
		status := tx.Signal("urgent: false")
		volume := tx.Signal("volume: 50%")

		tx.Mount(tx.Column(func() {
			tx.Row(func() {
				tx.Checkbox("urgent", func(tx *kaya.Tx, checked bool) {
					tx.Write(status, fmt.Sprintf("urgent: %t", checked))
				})
				tx.Label(status)
			})
			tx.Row(func() {
				tx.Slider(0.0, 1.0, 0.5, func(tx *kaya.Tx, value float64) {
					// Integer percent, so every language's formatting
					// agrees.
					tx.Write(volume, fmt.Sprintf("volume: %d%%", int(value*100+0.5)))
				})
				tx.Label(volume)
			})
		}))
	})

	os.Exit(app.Run())
}
