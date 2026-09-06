// The align conformance scene (tools/scenes/align.steps).
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
		anchor := tx.Signal("anchor")
		fit := tx.Signal("fit")
		plain := tx.Signal("plain probe")

		tx.Mount(tx.Column(func() {
			tx.Column(func() { // the center trio
				tx.Label(probe) // label#0
				tx.Button("mid", nil)
				tx.Row(func() { // the baseline trio
					tx.Label(base) // label#1
					tx.Button("tick", nil)
					tx.Image(tallPNG)
				}).Align(kaya.AlignBaseline).A11yID("baseline")
			}).Align(kaya.AlignCenter).A11yID("centered")
			tx.Row(func() { // row#1: the stretch pair's host
				tx.Label(anchor) // label#2
				tx.Column(func() {
					tx.Label(fit) // label#3
					tx.Button("wide", nil)
				}).Grow(1).Align(kaya.AlignStretch).A11yID("fitcol")
			})
			// row@plain: NO align, so the core's centre default is what the
			// scene reads
			tx.Row(func() {
				tx.Label(plain).A11yID("plainlabel") // label#4
				tx.Image(tallPNG)
			}).A11yID("plain")
			// column@knobs: NO align; fill opts one child out of its
			// default and one in
			tx.Column(func() {
				tx.Textarea(nil).Fill(false).A11yID("optout")
				tx.Button("fills", nil).Fill(true).A11yID("fills")
			}).A11yID("knobs")
		}).Align(kaya.AlignStretch).A11yID("root"))
	})

	return app
}
