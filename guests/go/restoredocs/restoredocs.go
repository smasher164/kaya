// The restored shape (tools/scenes/restoredocs.steps,
// docs/restoration-plan.md SR9): each document's title and text live in
// its own session scope, and act two recreates the documents the last
// launch left, takes each scope back, and selects the active one.
package restoredocs

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	documents := []uint64{10, 11, 12}
	active := uint64(0)
	restored := false
	for _, w := range kaya.RestoredWindows() {
		if w.ID == 0 {
			documents, active, restored = w.Documents, w.ActiveDocument, true
		}
	}
	if !restored {
		for i, title := range []string{"a", "b", "c"} {
			kaya.DocumentSession(documents[i]).SetString("title", title)
		}
	}

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("restoredocs").Size(640, 420)
		for _, id := range documents {
			scope := kaya.DocumentSession(id)
			title := scope.GetString("title", "untitled")
			tx.AddDocument(id).Title(title).Restore(id)
			caption := tx.Signal(title + " body")
			var field kaya.Widget
			tx.MountIn(id, tx.Column(func() {
				tx.Label(caption).A11yID("caption-" + title)
				field = tx.Entry(func(_ *kaya.Tx, text string) {
					scope.SetString("body", text)
				}).A11yID("body-" + title)
				tx.Button("recall", func(tx *kaya.Tx) {
					tx.Write(caption, kaya.DocumentSession(id).GetString("title", "untitled")+" body")
				}).A11yID("recall-" + title)
			}))
			tx.SetText(field, scope.GetString("body", ""))
		}
		if active != 0 {
			tx.SelectDocument(active)
		}
	})

	return app
}
