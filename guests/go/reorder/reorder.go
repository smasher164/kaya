// The reorder scene (tools/scenes/reorder.steps). THE ROOT IS A ROW so the
// For's container is the only column, and column#0 names it everywhere.
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
				entries := items.Items(tx)
				items.MoveToEnd(tx, entries[0].Key)
			})
			tx.Button("lift", func(tx *kaya.Tx) {
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
