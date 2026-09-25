// The app-owned undo scene (tools/scenes/ownundo.steps;
// docs/rich-text-plan.md R6, §14): two rich textareas, one on the
// platform's own undo tier and one whose app keeps its own history of
// Documents. Edit>Undo reaches the app through the role item's own
// activation while the owned textarea is focused, and the platform's tier
// while the other one is.
package ownundo

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	// THE APP'S OWN HISTORY: the document before each user edit, and the
	// documents an undo took away. The binding's mirror is the document
	// AFTER the edit it just delivered.
	var undo, redo []kaya.Document
	current := kaya.NewDocument("")

	var status kaya.Signal[string]
	var native, owned kaya.Widget

	publish := func(tx *kaya.Tx) {
		tx.Write(status, fmt.Sprintf("undo %d redo %d", len(undo), len(redo)))
		tx.CanUndo(owned, len(undo) > 0)
		tx.CanRedo(owned, len(redo) > 0)
	}

	app.Build(func(tx *kaya.Tx) {
		win := tx.Window(0).Title("ownundo")

		edit := win.Menu("Edit")
		edit.Item("Undo").Role(kaya.RoleUndo).OnActivate(func(tx *kaya.Tx) {
			if len(undo) == 0 {
				return
			}
			before := undo[len(undo)-1]
			undo = undo[:len(undo)-1]
			redo = append(redo, current)
			current = before
			tx.SetDocument(owned, before)
			publish(tx)
		})
		edit.Item("Redo").Role(kaya.RoleRedo).OnActivate(func(tx *kaya.Tx) {
			if len(redo) == 0 {
				return
			}
			after := redo[len(redo)-1]
			redo = redo[:len(redo)-1]
			undo = append(undo, current)
			current = after
			tx.SetDocument(owned, after)
			publish(tx)
		})

		status = tx.Signal("undo 0 redo 0")

		tx.Mount(tx.Column(func() {
			tx.Label(status).A11yID("status") // label#0
			native = tx.Textarea(nil).Rich().
				A11yID("native").A11yLabel("Native") // textarea#0
			owned = tx.Textarea(nil).Rich().OwnUndo().
				A11yID("owned").A11yLabel("Owned") // textarea#1
			owned.OnEdit(func(tx *kaya.Tx, _ kaya.Edit) {
				undo = append(undo, current)
				current = app.Document(owned)
				redo = redo[:0]
				publish(tx)
			})

			tx.Row(func() {
				tx.Button("focus native", func(tx *kaya.Tx) { // button#0
					tx.Focus(native)
				})
				tx.Button("focus owned", func(tx *kaya.Tx) { // button#1
					tx.Focus(owned)
				})
			})
		}))
	})

	return app
}
