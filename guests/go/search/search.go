// The search scene (tools/scenes/search.steps): a search field filtering a
// list on every keystroke, the app owning the filter (docs/search-plan.md
// S9) — the visible set is a diff of removes and inserts by key.
package search

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Item -key string
type Item struct {
	Name string
}

var names = []string{"apple", "banana", "cherry", "mango"}

func App() *kaya.App {
	app := kaya.NewApp()
	visible := append([]string(nil), names...)

	app.Build(func(tx *kaya.Tx) {
		items := ItemCollection(tx)
		count := tx.Signal(fmt.Sprintf("%d items", len(names)))

		tx.Mount(tx.Column(func() {
			tx.Search(func(tx *kaya.Tx, text string) {
				query := strings.ToLower(text)
				wanted := []string{}
				for _, name := range names {
					if strings.Contains(name, query) {
						wanted = append(wanted, name)
					}
				}
				// A DIFF, never clear-and-refill: only the rows whose
				// membership changed move (docs/search-plan.md S9).
				for _, name := range visible {
					if !has(wanted, name) {
						tx.Remove(items.Collection, name)
					}
				}
				for _, name := range wanted {
					if !has(visible, name) {
						items.Insert(tx, name, Item{Name: name})
					}
				}
				// Insertion order is arrival order, so a row coming back
				// lands last; walking the wanted keys to the end in order
				// puts the list back in `names` order.
				for _, name := range wanted {
					items.MoveToEnd(tx, name)
				}
				if query == "" {
					tx.Write(count, fmt.Sprintf("%d items", len(names)))
				} else {
					tx.Write(count, fmt.Sprintf("%d of %d match", len(wanted), len(names)))
				}
				visible = wanted
			}).Placeholder("Search").A11yID("find").A11yLabel("Find items")
			tx.Label(count).A11yID("count")
			// The For IS the list: expect_order reads its label children.
			rows := ItemRows(tx, items)
			for row := range rows.All() {
				row.Label(row.Name())
			}
			tx.SetA11yID(rows.Widget(), "list")
		}))

		for _, name := range names {
			items.Insert(tx, name, Item{Name: name})
		}
	})

	return app
}

func has(list []string, want string) bool {
	for _, name := range list {
		if name == want {
			return true
		}
	}
	return false
}
