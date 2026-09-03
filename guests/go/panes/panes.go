// The panes scene (tools/scenes/panes.steps): nothing here is
// panes-specific except `Panes(3)`, asked for ONCE.
package panes

import (
	kaya "dev.kaya/bindings/go"
)

const (
	content = 7
	detail  = 8
)

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("panes").Panes(3)

		tx.Mount(tx.Column(func() {
			// Authored ids: an index read passes for an empty arm.
			caption := tx.Signal("root pane")
			tx.Label(caption).A11yID("root")       // label#0
			tx.Button("open content", openContent) // button#0
		}))
	})

	return app
}

func openContent(tx *kaya.Tx) {
	entry := tx.PushEntry(content).Title("content").Id()
	pane := tx.Column(func() {
		caption := tx.Signal("content pane")
		tx.Label(caption).A11yID("content")  // label#1
		tx.Button("open detail", openDetail) // button#1
	})
	tx.MountIn(entry, pane)
}

func openDetail(tx *kaya.Tx) {
	entry := tx.PushEntry(detail).Title("detail").Id()
	pane := tx.Column(func() {
		caption := tx.Signal("detail pane")
		tx.Label(caption).A11yID("detail") // label#last
	})
	tx.MountIn(entry, pane)
}
