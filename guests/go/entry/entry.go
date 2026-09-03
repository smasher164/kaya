// The entry scene (tools/scenes/entry.steps). THE OTHER EVENT SURFACE: the
// handlers register on the APP after the build, not on the constructors.
package entry

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	var (
		status     kaya.Signal[string]
		field, add kaya.Widget
		todos      kaya.Collection
	)

	app.Build(func(tx *kaya.Tx) {
		status = tx.Signal("no todos")
		todos = tx.Collection()

		tx.Mount(tx.Column(func() {
			field = tx.Entry(nil)
			add = tx.Button("add", nil)
			tx.Label(status)
			for row := range tx.Rows(todos).All() {
				row.Label(row.Value())
			}
		}))
	})

	draft := ""
	app.OnChange(field, func(tx *kaya.Tx, text string) {
		draft = text
	})
	app.OnClick(add, func(tx *kaya.Tx) {
		if draft == "" {
			total := tx.Len(todos)
			tx.Write(status, fmt.Sprintf("nothing to add, %d total", total))
			return
		}
		// NO KEY: the binding mints the name and hands it back
		// (docs/fresh-key-plan.md).
		tx.InsertFresh(todos, draft)
		total := tx.Len(todos)
		tx.Write(status, fmt.Sprintf("added %s, %d total", draft, total))
		tx.Clear(field)
		tx.Focus(field)
	})

	return app
}
