// The confirm conformance scene, Go port — the modal-alert grammar
// via the chain spelling (the request/result grammar's first client):
// one button re-shows a two-action alert; the three rounds take the
// three answer paths (action 0, action 1, kaya.AlertChoiceCancel),
// and the status label records each result. The result handler
// rides the REQUEST (OnResult in the chain, the widget-handler
// precedent) and retires with its one answer; ids are
// binding-allocated. See guests/rust/confirm.rs and
// tools/scenes/confirm.steps.
package confirm

import (
	kaya "dev.kaya/bindings/go"
)

// App builds the scene and hands it back ready to be served.
//
// THE TAIL IS THE ONLY THING THAT DIFFERS BY PLATFORM, and it differs
// because the hosting does: a desktop or iOS guest owns the process
// main thread and lends it to kaya (guests/go/cmd/main_desktop.go),
// while on Android the OS owns main and kaya starts the guest on a
// thread of its own (guests/go/cmd/main_android.go). Both tails are
// one package over one scene table, so everything above them — the
// transaction, the handlers, the strings — is compiled into every
// platform's artifact from these bytes.
func App() *kaya.App {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("confirm")
		status = tx.Signal("no decision")

		tx.Mount(tx.Column(func() {
			tx.Label(status) // label#0
			tx.Button("delete", func(tx *kaya.Tx) {
				// The result handler rides the request and
				// retires with its one answer; ids are
				// binding-allocated — no counter plumbing.
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
				// A different dialog, a different handler: the
				// association is the registration itself.
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
