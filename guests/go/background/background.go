// The background scene (tools/scenes/background.steps): the worker waits
// for a CLICK, so a binding that used the app goroutine DEADLOCKS here.
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
			// Addressed by id: an index read passes for an empty arm.
			tx.Label(detail).A11yID("nested") // label#2

			tx.Button("start", func(tx *kaya.Tx) { // button#0
				go func() {
					<-release
					for _, step := range []string{"1", "2", "3"} {
						app.Post(func(tx *kaya.Tx) {
							posted += step
							tx.Write(status, posted)
						})
					}
				}()
				tx.Write(status, "working")
			})
			tx.Button("ping", func(tx *kaya.Tx) { // button#1
				tx.Write(alive, "alive")
			})
			tx.Button("release", func(tx *kaya.Tx) { // button#2
				close(release)
			})
			// A post from INSIDE a handler QUEUES for after; it never nests.
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
