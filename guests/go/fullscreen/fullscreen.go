// The fullscreen scene (tools/scenes/fullscreen.steps,
// docs/fullscreen-plan.md §5). The app keeps its own copy of the state: a
// toggle writes !on, and the user's door moves the copy through
// OnFullscreenChanged.
package fullscreen

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	on := false
	pinged := 0
	app.Build(func(tx *kaya.Tx) {
		asked := tx.Signal("windowed")
		user := tx.Signal("no change from the user")
		pings := tx.Signal("pings 0")

		tx.Window(0).Title("fullscreen").OnFullscreenChanged(func(tx *kaya.Tx, now bool) {
			on = now
			if now {
				tx.Write(user, "the user turned fullscreen on")
			} else {
				tx.Write(user, "the user turned fullscreen off")
			}
		})

		tx.Mount(tx.Column(func() {
			tx.Label(asked) // label#0
			tx.Label(user)  // label#1
			tx.Label(pings) // label#2
			tx.Button("toggle fullscreen", func(tx *kaya.Tx) { // button#0
				on = !on
				tx.Window(0).Fullscreen(on)
				if on {
					tx.Write(asked, "asked for fullscreen")
				} else {
					tx.Write(asked, "asked for a window")
				}
			})
			tx.Button("ping", func(tx *kaya.Tx) { // button#1
				pinged++
				tx.Write(pings, fmt.Sprintf("pings %d", pinged))
			})
		}))
	})

	return app
}
