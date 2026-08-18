// The dirty-state conformance scene, Go port — unsaved work as window
// chrome (docs/dirty-plan.md). One boolean beside Title and VetoClose
// on the window chain: the app declares STATE and the backend spells
// its platform's own affordance. TWO DECLARATIONS, on purpose — an edit
// writes the document AND says Dirty(true), because kaya does not watch
// your signals and guess. See guests/rust/dirty.rs and
// tools/scenes/dirty.steps.
package dirty

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	var doc, status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		// Dirty is NOT declared here: the default false is the scene's
		// first assertion. Dirty and VetoClose are orthogonal on every
		// platform.
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
					// Agreeing destroys the PRIMARY window, which
					// ABORTS — docs/traps.md, "An app can VETO a close
					// but cannot AGREE to one". The scene answers
					// cancel, so nothing has ever taken this arm.
					tx.DestroyWindow(0)
				}).
				Show()
		})

		tx.Mount(tx.Column(func() {
			tx.Label(doc)    // label#0
			tx.Label(status) // label#1
			tx.Button("edit", func(tx *kaya.Tx) { // button#0
				// The document AND the declaration, in ONE transaction;
				// neither implies the other.
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
