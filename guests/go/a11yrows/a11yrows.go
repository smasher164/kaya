// The stamped-accessibility scene, Go port: two entries stamped from ONE
// template, each carrying its OWN ROW's accessibility identity, read back
// out of the platform's real tree.
//
// SEPARATE FROM THE a11y SCENE ON PURPOSE: a For materializes a column
// and container registries are creation-order, which differs by language.
// This scene asserts no container at all.
//
// See guests/rust/a11yrows.rs and tools/scenes/a11yrows.steps.
package a11yrows

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Mount(tx.Column(func() {
			notes := tx.Collection()
			for row := range notes.Rows(tx) {
				field := row.Entry()
				// BOTH PROPS ELEMENT-SOURCED. The ID is forced: expect_ax
				// searches the REAL tree by the authored identifier, so copies
				// sharing one const id are an ambiguity that verb refuses.
				row.BindA11yID(field, row.Value())
				row.BindA11yLabel(field, row.Value())
			}
			tx.InsertFresh(notes, "First note")  // entry#0
			tx.InsertFresh(notes, "Second note") // entry#last

			// A SECOND COLLECTION rather than two more widgets in the first:
			// a scalar row has exactly one field to spend on an id. Both
			// props are CONST — facts about the prototype, not the row.
			heads := tx.Collection()
			for head := range heads.Rows(tx) {
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
