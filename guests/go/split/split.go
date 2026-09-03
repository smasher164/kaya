// The split scene, driven by TWO scripts (tools/scenes/split.steps and
// listdetail.steps): the presentation is asked for ONCE and never again.
package split

import (
	kaya "dev.kaya/bindings/go"
)

const detail = 7

func App() *kaya.App {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("split").Panes(2)
		status = tx.Signal("list pane")

		tx.Mount(tx.Column(func() {
			// Authored ids: an index read passes for an empty arm.
			tx.Label(status).A11yID("list") // label#0
			tx.Button("open detail", func(tx *kaya.Tx) { // button#0
				entry := tx.PushEntry(detail).
					Title("detail").
					OnPopped(func(tx *kaya.Tx) {
						tx.Write(status, "popped detail")
					}).
					Id()
				pane := tx.Column(func() {
					caption := tx.Signal("detail pane")
					tx.Label(caption).A11yID("detail")
				})
				tx.MountIn(entry, pane)
			})
		}))
	})

	return app
}
