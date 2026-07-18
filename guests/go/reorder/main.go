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
package main

import (
	"os"
	"runtime"

	kaya "dev.kaya/bindings/go"
)

func init() {
	// The core must own the process main thread.
	runtime.LockOSThread()
}

// Item is the record type and, by reflection, the schema. kaya-gen
// reads this declaration and emits item_kaya.go with the collection
// factory.
//
//go:generate go run dev.kaya/cmd/kaya-gen -type Item -key string
type Item struct {
	Title string
}

func main() {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		items := ItemCollection(tx)
		tx.Mount(tx.Row(
			tx.Button("rotate", func(tx *kaya.Tx) {
				// First entry to the end. The model owns the order, so
				// the handler asks it which key is first — it never
				// counts widgets.
				entries := items.Items(tx)
				items.MoveToEnd(tx, entries[0].Key)
			}),
			tx.Button("lift", func(tx *kaya.Tx) {
				// Last entry to the front: MoveToFront is sugar for
				// MoveBefore the current first key — the same wire
				// op, keys never indices.
				entries := items.Items(tx)
				items.MoveToFront(tx, entries[len(entries)-1].Key)
			}),
			ItemEach(tx, items, func(row itemRow) {
				row.Label(row.Title())
			}),
		))
		for _, key := range []string{"a", "b", "c"} {
			items.Insert(tx, key, Item{Title: key})
		}
	})

	os.Exit(app.Run())
}
