// The todos scene from Go: records and field projection, on the
// construction sugar. The struct is the schema, the template binds each
// field through typed tokens, and toggling a row records ONE field's
// delta through Patch — the title never travels.
//
// AND THE ITEMS-LEFT LABEL COMES BACK FROM AN UNDO WITH NOBODY RESTORING
// IT: the add is a named step (tx.Undoable) and the derive's write is in
// that same batch, so the core banks the label in both directions of the
// step. Which is why this file registers no OnUndone — a binding that
// recomputed the derive while absorbing the payload would be writing a
// value the ledger never banked.
package todos

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

// Todo is the record type and, by reflection, the schema. kaya-gen reads
// this declaration and emits todo_kaya.go.
//
// THE KEY TYPE IS I64 BECAUSE THE BINDING MINTS IT: a todo has no
// identity of its own, so the name comes from kaya.InsertFresh
// (docs/fresh-key-plan.md).
//
//go:generate go run dev.kaya/cmd/kaya-gen -type Todo -key int64
type Todo struct {
	Title string
	Done  bool
}

func App() *kaya.App {
	app := kaya.NewApp()

	draft := ""

	app.Build(func(tx *kaya.Tx) {
		// THE GESTURE LAYER, and these two items are the whole of it:
		// they act on what is focused, lower to the platform's own
		// command, and work out their own enablement (docs/undo-plan.md
		// D1-D6).
		edit := tx.Window(0).Title("todos").Menu("Edit")
		edit.Item("Undo").Role(kaya.RoleUndo)
		edit.Item("Redo").Role(kaya.RoleRedo)

		todos := TodoCollection(tx)
		itemsLeft := todos.Derive(tx, func(items []kaya.RecordEntry[int64, Todo]) string {
			n := 0
			for _, e := range items {
				if !e.Value.Done {
					n++
				}
			}
			if n == 1 {
				return "1 item left"
			}
			return fmt.Sprintf("%d items left", n)
		})

		tx.Mount(tx.Column(func() {
			field := tx.Entry(func(tx *kaya.Tx, text string) {
				draft = text
			})
			tx.Button("Add", func(tx *kaya.Tx) {
				if draft == "" {
					return
				}
				// ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The
				// items-left label comes back with the todo because the
				// derive's write is in this batch.
				tx.Undoable(fmt.Sprintf("add %s", draft))
				// NO KEY: a todo has no identity of its own, so the
				// binding mints one and hands it back. Discarded here;
				// the toggle handler receives the same key from the
				// stamped row it came from.
				kaya.InsertFresh(tx, todos, Todo{Title: draft})
				// FINISHING THE FORM IS NOT PART OF THE STEP — its own
				// transaction, so undoing the add does not put the draft
				// back beside a todo that is gone. Clear inside a group
				// would be refused at apply anyway (D4).
				app.Post(func(tx *kaya.Tx) {
					tx.Clear(field)
					tx.Focus(field)
				})
			})
			tx.Label(itemsLeft)
			for row := range TodoRows(tx, todos) {
				row.Row(func() {
					row.Checkbox(row.Done(),
						func(tx *kaya.Tx, key int64, checked bool) {
							// One field's delta through the generated
							// named setter; the derived signal updates
							// itself.
							TodoPatch(todos, tx, key).Done(checked)
						})
					row.Label(row.Title())
				})
			}
		}))
	})

	return app
}
