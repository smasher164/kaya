// The stall conformance scene, Go port — an app goroutine that stops
// taking its occurrences is REPORTED (DESIGN.md, Threading model and
// protocol).
//
// THIS IS THE ONE GUEST THAT MISUSES KAYA ON PURPOSE, in every
// language: `block` sleeps ON THE APP GOROUTINE and the scene asserts
// that kaya NOTICES. The class is not hypothetical — a Haskell release
// once used a blocking put and would have wedged the app thread forever
// (docs/deferred.md:461).
//
// WHY THE SECOND CLICK MATTERS: the consumer cursor advances BEFORE a
// record reaches the guest, so a handler blocking on an empty queue
// looks exactly like an idle app. `ping` is what makes work PENDING
// while the app goroutine is gone. The recovery is asserted too, and
// then `wedge` never returns at all — the leg still reports, because
// the harness runs on its own thread and asks the MAIN thread to exit.
//
// See guests/rust/stall.rs and tools/scenes/stall.steps.
package stall

import (
	"time"

	kaya "dev.kaya/bindings/go"
)

// Comfortably past the watchdog's one-second threshold and short enough
// that the leg is not paying for it.
const block = 2500 * time.Millisecond

// A day, never a literal park (docs/traps.md, "The stall scene wedges
// for a DAY").
const wedge = 24 * time.Hour

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("stall")
		status := tx.Signal("ready")

		tx.Mount(tx.Column(func() {
			tx.Label(status).A11yID("status") // label#0

			// DELIBERATELY WRONG, and the only place in this repo that
			// is.
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
