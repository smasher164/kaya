// The table scene from Go: column headers and click-to-sort on the
// For vocabulary (docs/tables-plan.md). A header click is a REQUEST —
// this guest reorders its collection BY KEY (the reorder scene's
// idiom) and re-declares the header with the new indicator; the
// platform sorts nothing. The byte-frozen contract is
// tools/scenes/table.steps.
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

	// The guest's sort policy — the platform never has one: clicking
	// the sorted column flips it, clicking another starts ascending.
	sortedCol := int64(-1)
	sortedDesc := false

	app.Build(func(tx *kaya.Tx) {
		items := ItemCollection(tx)
		// The root is a row so the For's container is the scene's only
		// column-kind widget (the reorder scene's rule). The table IS
		// the For, headers declared on the Widget ItemEach returns.
		tx.Mount(tx.Row(func() {
			table := ItemEach(tx, items, func(row itemRow) {
				row.Row(func() {
					row.Label(row.Name())
					row.Label(row.Size())
				})
			})
			// A table is a viewport: like the scroll scene, the
			// SCENE says it fills — an ungrown table sizes to
			// nothing (measured by screenshot).
			tx.SetGrow(table, 1)
			tx.Columns(table, []string{"Name", "Size"}, kaya.SortNone())
			app.OnSort(table, func(tx *kaya.Tx, column uint32) {
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
				// Keys, never indices: moving each key to the end in
				// the target order leaves the collection sorted.
				for _, e := range entries {
					items.MoveToEnd(tx, e.Key)
				}
				indicator := kaya.SortAsc(column)
				if desc {
					indicator = kaya.SortDesc(column)
				}
				tx.Columns(table, []string{"Name", "Size"}, indicator)
			})
		}))
		for _, seed := range []struct{ key, name, size string }{
			{"b", "banana", "30"}, {"a", "apple", "10"}, {"c", "cherry", "20"},
		} {
			items.Insert(tx, seed.key, Item{Name: seed.name, Size: seed.size})
		}
	})

	return app
}
