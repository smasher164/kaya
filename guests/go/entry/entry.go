// The entry scene from Go: the uncontrolled contract end to end. The
// field owns its text and reports each edit through OnChange; the app
// folds those into a plain variable.
//
// WHAT THIS SCENE DOCUMENTS IS THE OTHER EVENT SURFACE: the two
// handlers are registered on the APP after the build, against the
// widgets the build handed back, rather than riding their constructors
// the way every other Go guest spells it.
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
			for row := range todos.Rows(tx) {
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
		// NO KEY: a line of text has no identity of its own, so the
		// binding mints the name and hands it back
		// (docs/fresh-key-plan.md).
		tx.InsertFresh(todos, draft)
		total := tx.Len(todos)
		tx.Write(status, fmt.Sprintf("added %s, %d total", draft, total))
		tx.Clear(field)
		tx.Focus(field)
	})

	return app
}
