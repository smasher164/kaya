// The split conformance scene, Go port — adaptive panes via the chain
// spelling. The guest asks for the presentation ONCE and does nothing
// adaptive again: everything after that is the platform re-deciding as
// the size class changes, and there is no prop for WHICH entries
// present.
//
// TWO scripts drive this ONE app: split resizes and names the
// presentation on each side, listdetail asserts the bare invariant at
// whatever width its host gives. See guests/rust/split.rs,
// tools/scenes/split.steps and tools/scenes/listdetail.steps.
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
			// Authored ids so the REAL-TREE read can address these: an
			// index read passes whether or not anything reached the
			// screen.
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
