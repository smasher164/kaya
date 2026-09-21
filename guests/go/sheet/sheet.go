// The sheet scene (tools/scenes/sheet.steps; docs/sheet-plan.md §6): a
// sheet opened from a button and closed through the platform's cancel
// path, the same sheet with the dismiss veto armed, a child sheet chained
// over it, and a programmatic dismiss that echoes nothing.
package sheet

import (
	kaya "dev.kaya/bindings/go"
)

const (
	task    = 11
	details = 12
)

func App() *kaya.App {
	app := kaya.NewApp()

	var status, draft kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("sheet")
		status = tx.Signal("closed")
		draft = tx.Signal("draft: none")

		openTask := func(tx *kaya.Tx, armed bool) {
			sheet := tx.PresentSheet(task).
				Title("new task").
				Detent(kaya.DetentMedium).
				InterceptDismiss(armed).
				OnDismissed(func(tx *kaya.Tx) { tx.Write(status, "dismissed") })
			if armed {
				// Nothing has gone; the app keeps the sheet up and says so.
				sheet = sheet.OnDismissRequested(func(tx *kaya.Tx) {
					tx.Write(status, "dismiss requested")
				})
			}
			body := tx.Column(func() {
				caption := tx.Signal("what needs doing?")
				tx.Label(caption)                         // label#1
				tx.Entry(func(tx *kaya.Tx, text string) { // entry#0
					tx.Write(draft, "draft: "+text)
				})
				tx.Label(draft)                          // label#2
				tx.Button("details", func(tx *kaya.Tx) { // button#2
					child := tx.PresentSheetOver(task, details).
						Title("details").
						OnDismissed(func(tx *kaya.Tx) { tx.Write(status, "details dismissed") }).
						Id()
					pane := tx.Column(func() {
						caption := tx.Signal("more about it")
						tx.Label(caption)
					})
					tx.MountIn(child, pane)
					tx.Write(status, "details open")
				})
				tx.Button("done", func(tx *kaya.Tx) { // button#3
					// Programmatic: no sheet_dismissed follows, so "done" stays.
					tx.DismissSheet(task)
					tx.Write(status, "done")
				})
			})
			tx.MountIn(sheet.Id(), body)
			tx.Write(status, "open")
			tx.Write(draft, "draft: none")
		}

		tx.Mount(tx.Column(func() {
			tx.Label(status)                                                       // label#0
			tx.Button("new task", func(tx *kaya.Tx) { openTask(tx, false) })       // button#0
			tx.Button("new task, armed", func(tx *kaya.Tx) { openTask(tx, true) }) // button#1
		}))
	})

	return app
}
