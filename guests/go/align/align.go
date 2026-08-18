// The align conformance scene, Go port. See guests/rust/align.rs and
// tools/scenes/align.steps.
package align

import (
	kaya "dev.kaya/bindings/go"
)

// A 2x64 PNG: the tall no-baseline child.
var tallPNG = []byte{
	137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72,
	68, 82, 0, 0, 0, 2, 0, 0, 0, 64, 8, 2, 0, 0,
	0, 191, 68, 49, 20, 0, 0, 0, 18, 73, 68, 65, 84, 120,
	156, 99, 8, 8, 138, 2, 34, 134, 81, 106, 104, 82, 0, 67,
	50, 126, 1, 49, 1, 65, 124, 0, 0, 0, 0, 73, 69, 78,
	68, 174, 66, 96, 130,
}

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		probe := tx.Signal("align probe")
		base := tx.Signal("base")

		tx.Mount(tx.Column(func() {
			tx.Label(probe) // label#0
			tx.Button("mid", nil)
			tx.Row(func() {
				tx.Label(base) // label#1
				tx.Button("tick", nil)
				tx.Image(tallPNG)
			}).Align(kaya.AlignBaseline)
		}).Align(kaya.AlignCenter))
	})

	return app
}
