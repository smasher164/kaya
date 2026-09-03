// THE ONE GUEST THAT MISUSES KAYA ON PURPOSE (tools/scenes/stall.steps):
// `block` sleeps on the app goroutine and `ping` makes work PENDING.
package stall

import (
	"time"

	kaya "dev.kaya/bindings/go"
)

// Past the watchdog's one-second threshold, and no longer.
const block = 2500 * time.Millisecond

// A day, never a literal park (docs/traps.md, "The stall scene wedges for
// a DAY").
const wedge = 24 * time.Hour

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("stall")
		status := tx.Signal("ready")

		tx.Mount(tx.Column(func() {
			tx.Label(status).A11yID("status") // label#0

			tx.Button("block", func(tx *kaya.Tx) { // button#0
				time.Sleep(block)
			})
			tx.Button("ping", func(tx *kaya.Tx) { // button#1
				tx.Write(status, "pinged")
			})
			tx.Button("wedge", func(tx *kaya.Tx) { // button#2
				time.Sleep(wedge)
			})
		}))
	})

	return app
}
