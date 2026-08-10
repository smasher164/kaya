// The reorder scene from Go: order as collection data, end to end.
// Three stamped rows and two buttons that never touch a widget — each
// handler repositions an entry by key (collection_move on the wire,
// move_child at the toolkit), and the selftest's expect_order reads
// the toolkit's actual child order back. The root is a row so the
// For's container is the scene's only column-kind widget: languages
// disagree on whether containers are created before or after their
// children, and column#0 must name the same widget everywhere.
//
// Build the library first (cargo build), then, from the repo root:
//
//	KAYA_SELFTEST=reorder go run dev.kaya/guests/go/reorder
package reorder

import (
	kaya "dev.kaya/bindings/go"
)

// Item is the record type and, by reflection, the schema. kaya-gen
// reads this declaration and emits item_kaya.go with the collection
// factory.
//
//go:generate go run dev.kaya/cmd/kaya-gen -type Item -key string
type Item struct {
	Title string
}

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
				// MoveBefore the current first key — the same wire
				// op, keys never indices.
				entries := items.Items(tx)
				items.MoveToFront(tx, entries[len(entries)-1].Key)
			})
			for row := range ItemRows(tx, items) {
				row.Label(row.Title())
			}
		}))
		for _, key := range []string{"a", "b", "c"} {
			items.Insert(tx, key, Item{Title: key})
		}
	})

	return app
}
