// The stall conformance scene, Go port — an app goroutine that stops
// taking its occurrences is REPORTED (DESIGN.md, Threading model and
// protocol).
//
// THIS IS THE ONE GUEST THAT MISUSES KAYA ON PURPOSE, in every
// language. Every other guest keeps blocking work off the app
// goroutine — each of the eight filedialog guests carries a paragraph
// explaining why its read goes to a worker — and that discipline was
// entirely unenforced. Nothing would have told anyone that a guest
// ignoring it had wedged the app. The class is not hypothetical: a
// Haskell release once used a blocking put, so a second click would
// have blocked the app thread forever, and no gate saw it.
//
// So `block` does exactly the forbidden thing — it sleeps on the app
// goroutine — and the scene asserts that kaya NOTICES. A scene that
// merely timed out would prove the app was broken; this proves the
// framework reported it, which is the whole feature.
//
// WHY THE SECOND CLICK MATTERS: the consumer cursor advances BEFORE a
// record reaches the guest, so a handler blocking on an empty queue
// looks exactly like an idle app — and nothing is waiting on it, so it
// may as well be. `ping` is what makes work PENDING while the app
// goroutine is gone. That is what the watchdog can see, and it is what
// a person reports: they click, and click again, and nothing happens.
//
// The recovery is asserted too: the blocked handler returns, the queued
// click is taken, and the label shows it — so the watchdog reported a
// stall rather than a death, and nothing was dropped.
//
// AND THEN ONE THAT NEVER COMES BACK. A handler blocking for 2.5
// seconds is a SLOW handler, and every assertion above would pass for
// one; a real deadlock does not politely end. `wedge` never returns, so
// the scene ends there — and the leg still reports its verdict, because
// the harness runs on its own thread and asks the MAIN thread to exit.
// Neither path needs the app thread that is gone.
//
// See guests/rust/stall.rs and tools/scenes/stall.steps.
package main

import (
	"os"
	"time"

	kaya "dev.kaya/bindings/go"
)

// Comfortably past the watchdog's one-second threshold, and short
// enough that the leg is not paying for it: the scene asserts the stall
// and then the recovery, so this is the whole cost.
const block = 2500 * time.Millisecond

// AND ONE THAT NEVER COMES BACK, which is the shape a real deadlock
// has. A day rather than a literal park, because "forever" is spelled
// differently in all eight languages and some of those spellings wake
// their runtime's own deadlock detector; within a leg that lasts
// seconds, a day and forever are the same thing. The process exits out
// from under it.
const wedge = 24 * time.Hour

func main() {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("stall")
		status := tx.Signal("ready")

		tx.Mount(tx.Column(func() {
			tx.Label(status).A11yID("status") // label#0

			// DELIBERATELY WRONG, and the only place in this repo that
			// is. Anything real belongs on a goroutine of its own with
			// the result posted back through app.Post — which is what
			// every other guest does, and what the watchdog's own
			// message tells you to do.
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

	os.Exit(app.Run())
}
