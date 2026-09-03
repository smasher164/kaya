// The stamped-a11y scene (tools/scenes/a11yrows.steps). It asserts NO
// container: a For materializes one, and their registries are ordinal.
package a11yrows

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Mount(tx.Column(func() {
			notes := tx.Collection()
			for row := range tx.Rows(notes).All() {
				field := row.Entry()
				// expect_ax REFUSES copies that share one const id.
				row.BindA11yID(field, row.Value())
				row.BindA11yLabel(field, row.Value())
			}
			tx.InsertFresh(notes, "First note")  // entry#0
			tx.InsertFresh(notes, "Second note") // entry#last

			// A SECOND collection: a scalar row has one field for an id.
			heads := tx.Collection()
			for head := range tx.Rows(heads).All() {
				var title kaya.Node
				bar := head.Row(func() {
					title = head.Label(head.Value())
					head.SetRole(title, kaya.RoleHeading)
					head.BindA11yID(title, head.Value())
				})
				head.SetInset(bar, 8)
			}
			tx.InsertFresh(heads, "Heading one") // label#0, row#0
			tx.InsertFresh(heads, "Heading two") // label#last
		}))
	})

	return app
}
