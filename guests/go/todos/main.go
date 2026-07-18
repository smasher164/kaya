// The todos scene from Go: records and field projection, on the
// construction sugar — varargs containers and constructors carrying
// their handlers, the Fyne shape (widget.NewButton("Add", tapped)).
// The struct is the schema, the template binds each field through
// typed tokens, and toggling a row records one field's delta through
// Patch: the title never travels. The items-left label is a derived
// signal the binding recomputes from the collection after every
// mutation, so no handler mentions it.
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

// Todo is the record type and, by reflection, the schema. kaya-gen
// reads this declaration and emits todo_kaya.go: the collection
// factory and the named-setter patch.
//
//go:generate go run dev.kaya/cmd/kaya-gen -type Todo -key string
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
	// the tree (the C guests keep the explicit floor).
	app.Build(func(tx *kaya.Tx) {
		todos := TodoCollection(tx)
		itemsLeft := todos.Derive(tx, func(items []kaya.RecordEntry[string, Todo]) string {
			n := 0
			for _, e := range items {
				if !e.Value.Done {
					n++
				}
			}
			if n == 1 {
				return "1 item left"
			}
			return fmt.Sprintf("%d items left", n)
		})

		tx.Mount(tx.Column(func() {
			tx.Entry(func(tx *kaya.Tx, text string) {
				draft = text
			})
			tx.Button("Add", func(tx *kaya.Tx) {
				nextKey++
				todos.Insert(tx, fmt.Sprintf("t%d", nextKey), Todo{Title: draft})
			})
			tx.Label(itemsLeft)
			// The tracing tier: the for statement IS the For — the
			// body runs once over the generated row surface
			// (exact-index tokens, no probes), and range-over-func
			// makes the close structural, even on break.
			for row := range TodoRows(tx, todos) {
				row.Row(func() {
					row.Checkbox(row.Done(),
						func(tx *kaya.Tx, key string, checked bool) {
							// One field's delta through the generated
							// named setter: the title never travels;
							// the derived signal updates itself.
							TodoPatch(todos, tx, key).Done(checked)
						})
					row.Label(row.Title())
				})
			}
		}))
	})

	os.Exit(app.Run())
}
