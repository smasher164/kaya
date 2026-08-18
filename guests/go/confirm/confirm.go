// The confirm conformance scene, Go port — the modal-alert grammar
// via the chain spelling. Three rounds take the three answer paths
// (action 0, action 1, kaya.AlertChoiceCancel). See
// guests/rust/confirm.rs and tools/scenes/confirm.steps.
package confirm

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("confirm")
		status = tx.Signal("no decision")

		tx.Mount(tx.Column(func() {
			tx.Label(status) // label#0
			tx.Button("delete", func(tx *kaya.Tx) {
				tx.ShowAlert().
					Title("delete item?").
					Message("this cannot be undone").
					Action("Delete").
					Action("Archive").
					Cancel("Keep").
					OnResult(func(tx *kaya.Tx, choice uint32) {
						switch choice {
						case 0:
							tx.Write(status, "deleted")
						case 1:
							tx.Write(status, "archived")
						case kaya.AlertChoiceCancel:
							tx.Write(status, "kept")
						}
					}).
					Show()
			})
			tx.Button("eject", func(tx *kaya.Tx) {
				tx.ShowAlert().
					Title("eject disk?").
					Message("it is still mounted").
					Action("Eject").
					Cancel("Hold").
					OnResult(func(tx *kaya.Tx, choice uint32) {
						if choice == kaya.AlertChoiceCancel {
							tx.Write(status, "held")
						} else {
							tx.Write(status, "ejected")
						}
					}).
					Show()
			})
		}))
	})

	return app
}
