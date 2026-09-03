// The nav conformance scene (tools/scenes/nav.steps): a programmatic
// PopEntry does NOT echo entry_popped.
package nav

import (
	kaya "dev.kaya/bindings/go"
)

const (
	detail   = 7
	settings = 8
)

func App() *kaya.App {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("nav")
		status = tx.Signal("at root")

		tx.Mount(tx.Column(func() {
			tx.Label(status) // label#0
			tx.Button("open detail", func(tx *kaya.Tx) { // button#0
				entry := tx.PushEntry(detail).
					Title("detail").
					OnPopped(func(tx *kaya.Tx) {
						tx.Write(status, "popped detail")
					}).
					Id()
				pane := tx.Column(func() {
					caption := tx.Signal("detail pane")
					tx.Label(caption)
				})
				tx.MountIn(entry, pane)
				tx.Write(status, "pushed detail")
			})
			tx.Button("open settings", func(tx *kaya.Tx) { // button#1
				// Nothing has popped, and no entry_popped will follow.
				entry := tx.PushEntry(settings).
					Title("settings").
					InterceptBack(true).
					OnBackRequested(func(tx *kaya.Tx) {
						tx.Write(status, "back requested")
						tx.PopEntry()
					}).
					Id()
				pane := tx.Column(func() {
					caption := tx.Signal("settings pane")
					tx.Label(caption)
				})
				tx.MountIn(entry, pane)
				tx.Write(status, "pushed settings")
			})
		}))
	})

	return app
}
