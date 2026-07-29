// The background conformance scene, Go port — work off the app
// goroutine, posted back (docs/background-work-plan.md).
//
// WHAT IT PROVES, and the reason for its odd shape: a wrong
// implementation must DEADLOCK rather than disagree. The worker parks
// until a CLICK releases it, and only a live app goroutine can process
// a click — so a binding that let background work occupy that goroutine
// cannot reach the end of the script at all. It could not even deliver
// its own release.
//
// The parking is a plain channel receive on a channel this guest owns,
// and the worker is a plain goroutine. kaya supplies no waiting
// primitive and should not: the point is that a guest uses its own
// language's concurrency and hands back only the result.
//
// The accumulators are the guest's own state rather than signal
// read-backs — signals are write-only by doctrine. They need no mutex:
// everything that touches them runs on the app goroutine, inside a
// posted transaction.
package main

import (
	"os"
	"runtime"

	kaya "dev.kaya/bindings/go"
)

func init() {
	runtime.LockOSThread()
}

func main() {
	app := kaya.NewApp()

	release := make(chan struct{})
	var posted, nested string

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("background")
		status := tx.Signal("idle")
		alive := tx.Signal("-")
		detail := tx.Signal("-")

		tx.Mount(tx.Column(func() {
			tx.Label(status).A11yID("status") // label#0
			tx.Label(alive).A11yID("alive")   // label#1
			// Authored so the CLOSING read can address it: the AX read
			// needs an identifier, and an index read passes for an arm
			// that ran and drew nothing.
			tx.Label(detail).A11yID("nested") // label#2

			tx.Button("start", func(tx *kaya.Tx) { // button#0
				go func() {
					// Parks here until the scene clicks release. Were
					// the binding running this on the app goroutine,
					// that click could never be processed and the whole
					// scene would deadlock — the point.
					<-release
					// Three posts, in order. The accumulator makes this
					// a test of ORDER and not merely of which one ran
					// last.
					for _, step := range []string{"1", "2", "3"} {
						app.Post(func(tx *kaya.Tx) {
							posted += step
							tx.Write(status, posted)
						})
					}
				}()
				tx.Write(status, "working")
			})
			// Proof the app goroutine is still serving input while the
			// worker is parked and has posted nothing.
			tx.Button("ping", func(tx *kaya.Tx) { // button#1
				tx.Write(alive, "alive")
			})
			tx.Button("release", func(tx *kaya.Tx) { // button#2
				close(release)
			})
			// A post from INSIDE a handler QUEUES for after; it never
			// nests. The handler appends a, posts a closure appending b,
			// appends c — so it commits "ac" and the posted closure then
			// commits "acb". Nesting can only ever produce "abc".
			tx.Button("nest", func(tx *kaya.Tx) { // button#3
				nested += "a"
				app.Post(func(tx *kaya.Tx) {
					nested += "b"
					tx.Write(detail, nested)
				})
				nested += "c"
				tx.Write(detail, nested)
			})
		}))
	})

	os.Exit(app.Run())
}
