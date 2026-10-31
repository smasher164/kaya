// The search scene (tools/scenes/search.steps): a search field filtering a
// list on every keystroke, the app owning the predicate (docs/search-plan.md
// S9) and each row hiding in place (docs/hidden-plan.md).
package search

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Item -key string
type Item struct {
	Name      string
	Unmatched bool
}

var names = []string{"apple", "banana", "cherry", "mango"}

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("search")
		items := ItemCollection(tx)
		count := tx.Signal(fmt.Sprintf("%d items", len(names)))

		tx.Mount(tx.Column(func() {
			tx.Search(func(tx *kaya.Tx, text string) {
				query := strings.ToLower(text)
				wanted := 0
				for _, name := range names {
					ItemPatch(items, tx, name).Unmatched(!strings.Contains(name, query))
					if strings.Contains(name, query) {
						wanted++
					}
				}
				if query == "" {
					tx.Write(count, fmt.Sprintf("%d items", len(names)))
				} else {
					tx.Write(count, fmt.Sprintf("%d of %d match", wanted, len(names)))
				}
			}).Placeholder("Search").A11yID("find").A11yLabel("Find items")
			tx.Label(count).A11yID("count")
			// The For IS the list: expect_order reads its label children.
			rows := ItemRows(tx, items)
			for row := range rows.All() {
				row.BindHidden(row.Label(row.Name()), row.Unmatched())
			}
			tx.SetA11yID(rows.Widget(), "list")
		}))

		for _, name := range names {
			items.Insert(tx, name, Item{Name: name})
		}
	})

	return app
}
