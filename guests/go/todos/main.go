// The todos scene from Go: records and field projection, on the
// construction sugar — varargs containers and constructors carrying
// their handlers, the Fyne shape (widget.NewButton("Add", tapped)).
// The struct is the schema, the template binds each field through
// typed tokens, and toggling a row records one field's delta through
// Patch: the title never travels.
//
// Build the library first (cargo build), then, from the repo root:
//
//	KAYA_SELFTEST=todos go run crates/kaya/examples/todos.go
package main

import (
	"fmt"
	"os"
	"runtime"

	kaya "dev.kaya/bindings/go"
)

func init() {
	// The core must own the process main thread.
	runtime.LockOSThread()
}

// Todo is the record type and, by reflection, the schema.
type Todo struct {
	Title string
	Done  bool
}

func main() {
	app := kaya.NewApp()

	// The fold: widget-owned state arrives as occurrences; the app's
	// copy is this variable, not a widget read.
	draft := ""
	nextKey := 0

	// The construction sugar: containers take their children,
	// constructors carry their handlers, and the build body reads as
	// the tree (milestone2 keeps the explicit floor on purpose).
	app.Build(func(tx *kaya.Tx) {
		itemsLeft := tx.Signal("0 items left")
		todos := kaya.CollectionOf[string, Todo](tx)

		itemsLeftText := func(tx *kaya.Tx) string {
			n := 0
			for _, e := range todos.Items(tx) {
				if !e.Value.Done {
					n++
				}
			}
			if n == 1 {
				return "1 item left"
			}
			return fmt.Sprintf("%d items left", n)
		}

		tx.Mount(tx.Column(
			tx.Entry(func(tx *kaya.Tx, text string) {
				draft = text
			}),
			tx.Button("Add", func(tx *kaya.Tx) {
				nextKey++
				todos.Insert(tx, fmt.Sprintf("t%d", nextKey), Todo{Title: draft})
				tx.Write(itemsLeft, itemsLeftText(tx))
			}),
			tx.Label(itemsLeft),
			tx.ForEach(todos.Collection, func(t *kaya.Tpl) {
				t.Row(
					todos.Checkbox(t, func(t *Todo) *bool { return &t.Done },
						func(tx *kaya.Tx, key string, checked bool) {
							// One field's delta: the title never travels.
							todos.Patch(tx, key).Set(func(t *Todo) *bool { return &t.Done }, checked)
							tx.Write(itemsLeft, itemsLeftText(tx))
						}),
					todos.Label(t, func(t *Todo) *string { return &t.Title }),
				)
			}),
		))
	})

	os.Exit(app.Run())
}
