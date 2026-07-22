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
		pos := tx.Signal(0.5)

		tx.Mount(tx.Column(func() {
			tx.Row(func() {
				tx.Checkbox("urgent", func(tx *kaya.Tx, checked bool) {
					tx.Write(status, fmt.Sprintf("urgent: %t", checked))
				})
				tx.Label(status)
			})
			tx.Row(func() {
				tx.SliderBound(0.0, 1.0, pos, func(tx *kaya.Tx, value float64) {
					// Integer percent, so every language's formatting
					// agrees.
					tx.Write(volume, fmt.Sprintf("volume: %d%%", int(value*100+0.5)))
				})
				tx.Label(volume)
				tx.Button("quarter", func(tx *kaya.Tx) {
					// The programmatic write: fans out to the control
					// and must NOT come back as a volume occurrence.
					tx.Write(pos, 0.25)
				})
			})
			tx.Row(func() {
				// The content-buffer row: a valid 2x2 PNG decodes and
				// reports its size, and deliberately invalid bytes
				// read 0x0 — decode failure is the placeholder class,
				// never a crash, on every backend.
				tx.Image(testPNG)
				tx.Image([]byte("not an image"))
			})
		}))
	})

	os.Exit(app.Run())
}

// A 2x2 RGB PNG (red/green over blue/white), 75 bytes: the first
// binary asset, embedded as source per the include_str! doctrine —
// scenes carry their inputs, no runtime file I/O.
var testPNG = []byte{
	137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
	0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154,
	115, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 192,
	0, 194, 12, 255, 129, 0, 0, 31, 238, 5, 251, 11, 217, 104, 139, 0,
	0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
}
