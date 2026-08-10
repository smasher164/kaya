// The menus conformance scene, Go port: the command vocabulary (a
// File/View/Sort menu bar, context menus on a live label and on stamped
// rows), the uncontrolled-menu echo doctrine, and a late
// rename/append/promotion rework. Canonical semantics in
// guests/rust/menus.rs; the byte-frozen contract in tools/scenes/menus.steps.
package menus

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

// App builds the scene and hands it back ready to be served.
//
// THE TAIL IS THE ONLY THING THAT DIFFERS BY PLATFORM, and it differs
// because the hosting does: a desktop or iOS guest owns the process
// main thread and lends it to kaya (guests/go/cmd/main_desktop.go),
// while on Android the OS owns main and kaya starts the guest on a
// thread of its own (guests/go/cmd/main_android.go). Both tails are
// one package over one scene table, so everything above them — the
// transaction, the handlers, the strings — is compiled into every
// platform's artifact from these bytes.
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

		// File and its Export leaf share one enablement signal: one write
		// moves both.
		win := tx.Window(0).Title("menus")
		file := win.Menu("File").BindEnabled(canExport)
		file.Item("Save").Shortcut("primary+s").OnActivate(func(tx *kaya.Tx) {
			tx.Write(status, "saved")
		})
		file.Item("Export").BindEnabled(canExport)
		share := file.Item("Share").Primary(true).OnActivate(onShare)

		win.Menu("View").Toggle("Details").BindChecked(details).
			OnToggle(func(tx *kaya.Tx, on bool) {
				if on {
					tx.Write(status, "details on")
				} else {
					tx.Write(status, "details off")
				}
			})

		// Option order IS the index vocabulary: Name = 0, Date = 1.
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
		// Catalog built live: items are shared across stamped copies; the
		// template only attaches, and each activation carries its key path.
		catalog := tx.ContextCatalog()
		catalog.Item("Remove").OnActivateNode(func(tx *kaya.Tx, keys []any) {
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
				// The folds never echo the user's pick, so details/sort still
				// hold false/0; these two prop writes are real checked/value
				// records (never coalesced) that reset the user-state mirror.
				tx.Write(details, false)
				tx.Write(sort, 0.0)
				tx.Write(status, "ready")
			})
			tx.Button("extend menus", func(tx *kaya.Tx) { // button#2
				// Append-only: rename the retained File, move the promotion
				// hint from Share to Publish, grow the bar by Tools.
				tx.Menu(share).Primary(false)
				tx.Menu(file).Label("Document").
					Item("Publish").Primary(true).OnActivate(onShare)
				tx.Window(0).Menu("Tools").Item("Inspect")
			})

			targetText := tx.Signal("rename target")
			target := tx.Label(targetText) // label#1
			tx.ContextMenu(target).Item("Rename").OnActivate(func(tx *kaya.Tx) {
				tx.Write(status, "renamed")
			})

			// Remove's activation names BOTH keys (group, then item).
			for g := range groups.Rows(tx) {
				g.Column(func() {
					items = g.Collection()
					for row := range items.Rows(tx) {
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
