// The background conformance scene, Go port — work off the app
// goroutine, posted back (docs/background-work-plan.md).
//
// THE PARKING IS LOAD-BEARING: the worker waits for a CLICK, and only a
// live app goroutine can deliver one — so a binding that ran background
// work on that goroutine deadlocks here rather than merely disagreeing.
package background

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
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
			// Authored so the CLOSING read can address it: an index read
			// passes for an arm that ran and drew nothing.
			tx.Label(detail).A11yID("nested") // label#2

			tx.Button("start", func(tx *kaya.Tx) { // button#0
				go func() {
					<-release
					// Three posts, so the accumulator tests ORDER and
					// not merely which one ran last.
					for _, step := range []string{"1", "2", "3"} {
						app.Post(func(tx *kaya.Tx) {
							posted += step
							tx.Write(status, posted)
						})
					}
				}()
				tx.Write(status, "working")
			})
			// Proof the app goroutine still serves input while the
			// worker parks.
			tx.Button("ping", func(tx *kaya.Tx) { // button#1
				tx.Write(alive, "alive")
			})
			tx.Button("release", func(tx *kaya.Tx) { // button#2
				close(release)
			})
			// A post from INSIDE a handler QUEUES for after; it never
			// nests. So this commits "ac" and the posted closure then
			// commits "acb" — nesting could only ever produce "abc".
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

	return app
}
