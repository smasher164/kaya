// The table scene (tools/scenes/table.steps): a header click is a REQUEST,
// and the platform sorts nothing.
package table

import (
	"sort"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Item -key string
type Item struct {
	Name string
	Size string
}

func App() *kaya.App {
	app := kaya.NewApp()

	// The guest's sort policy; the platform never has one.
	sortedCol := int64(-1)
	sortedDesc := false

	app.Build(func(tx *kaya.Tx) {
		items := ItemCollection(tx)
		// The root is a row: the For's container is the only column.
		var table kaya.Widget
		tx.Mount(tx.Row(func() {
			rows := ItemRows(tx, items).
				Columns([]string{"Name", "Size"}, kaya.SortNone()).
				OnSort(func(tx *kaya.Tx, column uint32) {
					desc := sortedCol == int64(column) && !sortedDesc
					sortedCol, sortedDesc = int64(column), desc
					entries := items.Items(tx)
					sort.SliceStable(entries, func(i, j int) bool {
						a, b := entries[i].Value.Name, entries[j].Value.Name
						if column != 0 {
							a, b = entries[i].Value.Size, entries[j].Value.Size
						}
						if desc {
							return a > b
						}
						return a < b
					})
					// Each key to the end, in the target order.
					for _, e := range entries {
						items.MoveToEnd(tx, e.Key)
					}
					indicator := kaya.SortAsc(column)
					if desc {
						indicator = kaya.SortDesc(column)
					}
					tx.Columns(table, []string{"Name", "Size"}, indicator)
				})
			table = rows.Widget()
			for row := range rows.All() {
				row.Row(func() {
					row.Label(row.Name())
					row.Label(row.Size())
				})
			}
			// Grown on purpose: ungrown, a table hugs its rows.
			tx.SetGrow(table, 1)
		}))
		for _, seed := range []struct{ key, name, size string }{
			{"b", "banana", "30"}, {"a", "apple", "10"}, {"c", "cherry", "20"},
		} {
			items.Insert(tx, seed.key, Item{Name: seed.name, Size: seed.size})
		}
	})

	return app
}
