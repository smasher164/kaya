// The nav conformance scene, Go port — the serial navigation grammar
// via the chain spelling. The covered root is RETAINED, and a
// programmatic PopEntry does not echo entry_popped, so the settings
// round's final status stays "back requested". See guests/rust/nav.rs
// and tools/scenes/nav.steps.
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
				// The popped handler rides the push, per entry.
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
				// Retention: the covered root keeps taking writes.
				tx.Write(status, "pushed detail")
			})
			tx.Button("open settings", func(tx *kaya.Tx) { // button#1
				// The veto class: nothing has popped; agree and
				// confirm. No entry_popped will fire, so this write
				// is the round's final status.
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
