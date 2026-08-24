// The reorder scene from Go: order as collection data. Two buttons
// that never touch a widget — each repositions an entry BY KEY, and
// expect_order reads the toolkit's actual child order back. THE ROOT
// IS A ROW so the For's container is the scene's only column-kind
// widget: languages disagree on whether containers are created before
// or after their children, and column#0 must name the same widget
// everywhere.
package reorder

import (
	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Item -key string
type Item struct {
	Title string
}

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		items := ItemCollection(tx)
		tx.Mount(tx.Row(func() {
			tx.Button("rotate", func(tx *kaya.Tx) {
				// First entry to the end. The model owns the order, so
				// the handler asks it which key is first — it never
				// counts widgets.
				entries := items.Items(tx)
				items.MoveToEnd(tx, entries[0].Key)
			})
			tx.Button("lift", func(tx *kaya.Tx) {
				// Last entry to the front: MoveToFront is sugar for
				// MoveBefore the current first key — keys, never indices.
				entries := items.Items(tx)
				items.MoveToFront(tx, entries[len(entries)-1].Key)
			})
			for row := range ItemRows(tx, items).All() {
				row.Label(row.Title())
			}
		}))
		for _, key := range []string{"a", "b", "c"} {
			items.Insert(tx, key, Item{Title: key})
		}
	})

	return app
}
