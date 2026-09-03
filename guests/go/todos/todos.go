// The todos scene (tools/scenes/todos.steps). IT REGISTERS NO OnUndone:
// the derive's write rides the add's batch, so the ledger banks it.
package todos

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Todo -key int64
type Todo struct {
	Title string
	Done  bool
}

func App() *kaya.App {
	app := kaya.NewApp()

	draft := ""

	app.Build(func(tx *kaya.Tx) {
		// The whole undo surface: the roles work out their own enablement.
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
				// The label comes back with the todo: one batch, both writes.
				tx.Undoable(fmt.Sprintf("add %s", draft))
				// NO KEY: the binding mints one and hands it back.
				kaya.InsertFresh(tx, todos, Todo{Title: draft})
				// Finishing the form gets its OWN transaction: Clear inside
				// a group is refused at apply (docs/undo-plan.md D4).
				app.Post(func(tx *kaya.Tx) {
					tx.Clear(field)
					tx.Focus(field)
				})
			})
			tx.Label(itemsLeft)
			for row := range TodoRows(tx, todos).All() {
				row.Row(func() {
					row.Checkbox(row.Done(),
						func(tx *kaya.Tx, key int64, checked bool) {
							TodoPatch(todos, tx, key).Done(checked)
						})
					row.Label(row.Title())
				})
			}
		}))
	})

	return app
}
