// The menus conformance scene (tools/scenes/menus.steps). Canonical
// semantics in guests/rust/menus.rs.
package menus

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	var (
		groups kaya.Collection
		items  kaya.Collection
	)

	app.Build(func(tx *kaya.Tx) {
		status := tx.Signal("ready")
		canExport := tx.Signal(false)
		details := tx.Signal(false)
		sort := tx.Signal(0.0)

		onShare := func(tx *kaya.Tx) { tx.Write(status, "shared") }

		win := tx.Window(0).Title("menus")
		file := win.Menu("File").BindEnabled(canExport)
		// The vocabulary has no save glyph, so `done` is the spelling.
		file.Item("Save").Symbol(kaya.SymbolDone).Shortcut("primary+s").
			OnActivate(func(tx *kaya.Tx) {
				tx.Write(status, "saved")
			})
		file.Item("Export").BindEnabled(canExport).Symbol(kaya.SymbolForward)
		share := file.Item("Share").Primary(true).OnActivate(onShare)

		win.Menu("View").Toggle("Details").BindChecked(details).
			Symbol(kaya.SymbolInfo).
			OnToggle(func(tx *kaya.Tx, on bool) {
				if on {
					tx.Write(status, "details on")
				} else {
					tx.Write(status, "details off")
				}
			})

		// Option order IS the index.
		sortGroup := win.RadioGroup("Sort")
		sortGroup.Option("Name")
		sortGroup.Option("Date")
		sortGroup.BindValue(sort).OnSelect(func(tx *kaya.Tx, index int) {
			if index == 1 {
				tx.Write(status, "sorted date")
			} else {
				tx.Write(status, "sorted name")
			}
		})

		groups = tx.Collection()
		catalog := tx.ContextCatalog()
		catalog.Item("Remove").Symbol(kaya.SymbolDelete).
			OnActivateNode(func(tx *kaya.Tx, keys []any) {
				group, item := keys[0].(string), keys[1].(string)
				tx.Remove(items.At(group), item)
				tx.Write(status, fmt.Sprintf("removed %s/%s", group, item))
			})

		tx.Mount(tx.Column(func() {
			tx.Label(status) // label#0
			tx.Button("enable export", func(tx *kaya.Tx) { // button#0
				tx.Write(canExport, true)
			})
			tx.Button("reset menu state", func(tx *kaya.Tx) { // button#1
				// The folds never echo, so these reset the user-state mirror.
				tx.Write(details, false)
				tx.Write(sort, 0.0)
				tx.Write(status, "ready")
			})
			tx.Button("extend menus", func(tx *kaya.Tx) { // button#2
				tx.Menu(share).Primary(false)
				tx.Menu(file).Label("Document").
					Item("Publish").Primary(true).Symbol(kaya.SymbolCopy).
					OnActivate(onShare)
				tx.Window(0).Menu("Tools").Item("Inspect").Symbol(kaya.SymbolSearch)
			})

			targetText := tx.Signal("rename target")
			target := tx.Label(targetText) // label#1
			tx.ContextMenu(target).Item("Rename").Symbol(kaya.SymbolEdit).
				OnActivate(func(tx *kaya.Tx) {
					tx.Write(status, "renamed")
				})

			for g := range tx.Rows(groups).All() {
				g.Column(func() {
					items = g.Collection()
					for row := range g.Rows(items).All() {
						// label#2 once g2/a stamps
						row.ContextMenu(row.Label(row.Value()), catalog)
					}
				})
			}
		}))
	})

	// Seed after mount: the stamp path attaches the shared catalog and keys.
	app.Build(func(tx *kaya.Tx) {
		tx.Insert(groups, "g2", "Home")
		tx.Insert(items.At("g2"), "a", "water plants")
	})

	return app
}
