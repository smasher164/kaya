// The gallery scene from Go: a checkbox and a slider, each owning its
// state and reporting each change while the app answers by writing
// the paired signal — the uncontrolled contract with a bool and a
// float64.
package gallery

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

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
					tx.Write(pos, 0.25)
				})
			})
			tx.Row(func() {
				// Deliberately invalid bytes read 0x0 — decode failure
				// is the placeholder class, never a crash.
				tx.Image(testPNG)
				tx.Image([]byte("not an image"))
			})
		}))
	})

	return app
}

// A 2x2 RGB PNG (red/green over blue/white), 75 bytes.
var testPNG = []byte{
	137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
	0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154,
	115, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 192,
	0, 194, 12, 255, 129, 0, 0, 31, 238, 5, 251, 11, 217, 104, 139, 0,
	0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
}
