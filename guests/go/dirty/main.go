// The dirty-state conformance scene, Go port — unsaved work as window
// chrome (docs/dirty-plan.md). One boolean beside Title and VetoClose
// on the window chain: the app declares STATE and the backend spells
// its platform's own affordance (the dot in the close button on macOS,
// a leading `*` in the rendered caption on Windows, a bullet in the
// GTK header bar, nothing on the phones, which have none).
//
// TWO DECLARATIONS, ON PURPOSE. An edit writes the document AND says
// Dirty(true); saving writes it back and says Dirty(false). kaya does
// not watch your signals and guess — "the document has unsaved
// changes" is a statement only the app can make, and the window prop
// is where it makes it.
//
// AND THE MARK ARMS NOTHING. The close attempt fires the veto class
// this window already opted into, the app opens its own dialog, and
// cancelling keeps the window with the mark still up. That flow is
// composed here out of parts that predate this prop — which is the
// whole reason Dirty is presentation and nothing else.
//
// See guests/rust/dirty.rs and tools/scenes/dirty.steps.
package main

import (
	"os"
	"runtime"

	kaya "dev.kaya/bindings/go"
)

func init() {
	runtime.LockOSThread()
}

func main() {
	app := kaya.NewApp()

	var doc, status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		// Dirty and VetoClose are orthogonal — either can be set
		// without the other, on every platform. This window takes both
		// because it is an editor: it owns its close so it can ask.
		// Dirty is NOT declared here: the default false is the scene's
		// first assertion.
		win := tx.Window(0).Title("dirty").VetoClose(true)

		doc = tx.Signal("notes")
		status = tx.Signal("saved")

		// The close handler binds to THE WINDOW at its declaration
		// (handlers scope to the thing that creates them): it can only
		// ever mean this surface's close was asked for.
		win.OnCloseRequested(func(tx *kaya.Tx) {
			// Nothing has closed: the veto class says so. An editor
			// with unsaved work asks; a clean one agrees at once.
			tx.ShowAlert().
				Title("unsaved changes").
				Message("the document has unsaved changes").
				Action("Discard").
				Cancel("Keep Editing").
				OnResult(func(tx *kaya.Tx, choice uint32) {
					if choice == kaya.AlertChoiceCancel {
						// Answering a dialog is not saving: the mark
						// stays up either way.
						tx.Write(status, "kept editing")
						return
					}
					// Agreeing destroys the surface, which for the
					// PRIMARY window is the process itself — so the
					// scene answers cancel and this arm stays the
					// honest spelling of "yes, close it" rather than a
					// step.
					tx.DestroyWindow(0)
				}).
				Show()
		})

		tx.Mount(tx.Column(func() {
			tx.Label(doc)    // label#0
			tx.Label(status) // label#1
			tx.Button("edit", func(tx *kaya.Tx) { // button#0
				// The document AND the declaration, in ONE
				// transaction. Neither implies the other: kaya does not
				// watch your signals, and Dirty is not a side effect of
				// writing one.
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

	os.Exit(app.Run())
}
