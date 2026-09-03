// The dirty-state scene (tools/scenes/dirty.steps). TWO DECLARATIONS, on
// purpose: kaya does not watch your signals and guess.
package dirty

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	var doc, status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		// Dirty is NOT declared here: the script reads the clean window.
		win := tx.Window(0).Title("dirty").VetoClose(true)

		doc = tx.Signal("notes")
		status = tx.Signal("saved")

		win.OnCloseRequested(func(tx *kaya.Tx) {
			tx.ShowAlert().
				Title("unsaved changes").
				Message("the document has unsaved changes").
				Action("Discard").
				Cancel("Keep Editing").
				OnResult(func(tx *kaya.Tx, choice uint32) {
					if choice == kaya.AlertChoiceCancel {
						tx.Write(status, "kept editing")
						return
					}
					// ABORTS if it runs — docs/traps.md, "An app can VETO a
					// close but cannot AGREE to one".
					tx.DestroyWindow(0)
				}).
				Show()
		})

		tx.Mount(tx.Column(func() {
			tx.Label(doc)    // label#0
			tx.Label(status) // label#1
			tx.Button("edit", func(tx *kaya.Tx) { // button#0
				tx.Write(doc, "notes and a line")
				tx.Write(status, "unsaved")
				tx.Window(0).Dirty(true)
			})
			tx.Button("save", func(tx *kaya.Tx) { // button#1
				tx.Write(status, "saved")
				tx.Window(0).Dirty(false)
			})
		}))
	})

	return app
}
