// The todos scene from Go: records and field projection, on the
// construction sugar — varargs containers and constructors carrying
// their handlers, the Fyne shape (widget.NewButton("Add", tapped)).
// The struct is the schema, the template binds each field through
// typed tokens, and toggling a row records one field's delta through
// Patch: the title never travels. The items-left label is a derived
// signal the binding recomputes from the collection after every
// mutation, so no handler mentions it.
//
// AND IT COMES BACK FROM AN UNDO WITH NOBODY RESTORING IT. The add is a
// named step (tx.Undoable), and the derive's write is in that same
// batch — the insert recomputes and writes an ordinary signal into the
// transaction that caused it — so the core banks the label in both
// directions of the step and hands it back together with the
// collection. Which is why this file registers no OnUndone: there is
// nothing left for a handler to fix up, and a binding that recomputed
// the derive while absorbing the payload would be writing a value the
// ledger never banked (App.absorbUndo says so from the other side).
//
// Build the library first (cargo build), then, from the repo root:
//
//	KAYA_SELFTEST=todos go run crates/kaya/examples/todos.go
package todos

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

// Todo is the record type and, by reflection, the schema. kaya-gen
// reads this declaration and emits todo_kaya.go: the collection
// factory and the named-setter patch.
//
// THE KEY TYPE IS I64 BECAUSE THE BINDING MINTS IT. A todo is a title
// and a checkbox — it has no identity of its own — so the name comes
// from kaya.InsertFresh, and the minted key rides the generated surface
// from the collection handle through to the toggle handler's parameter
// (docs/fresh-key-plan.md).
//
//go:generate go run dev.kaya/cmd/kaya-gen -type Todo -key int64
type Todo struct {
	Title string
	Done  bool
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

	// The fold: widget-owned state arrives as occurrences; the app's
	// copy is this variable, not a widget read.
	draft := ""

	// The construction sugar: containers take their children,
	// constructors carry their handlers, and the build body reads as
	// the tree (the C guests keep the explicit floor).
	app.Build(func(tx *kaya.Tx) {
		// THE GESTURE LAYER, and these two items are the whole of it: an
		// app declares them and writes nothing else. They act on what is
		// focused, lower to the platform's own command where it has one,
		// and work out their own enablement from what the ledger holds
		// (docs/undo-plan.md D1-D6). No OnUndone, no OnRedone — the
		// label this scene is about is core state, so the core restores
		// it and there is nothing for a handler to say.
		edit := tx.Window(0).Title("todos").Menu("Edit")
		edit.Item("Undo").Role(kaya.RoleUndo)
		edit.Item("Redo").Role(kaya.RoleRedo)

		todos := TodoCollection(tx)
		itemsLeft := todos.Derive(tx, func(items []kaya.RecordEntry[int64, Todo]) string {
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
			field := tx.Entry(func(tx *kaya.Tx, text string) {
				draft = text
			})
			tx.Button("Add", func(tx *kaya.Tx) {
				if draft == "" {
					return
				}
				// ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. What
				// brings the ITEMS-LEFT LABEL back with the todo is
				// that the derive's write is in this batch: the insert
				// below recomputes and writes an ordinary signal, and a
				// named transaction banks every signal it dirtied in
				// both of its directions. So this step's inverse carries
				// "0 items left" and its forward carries "1 item left",
				// and the label is restored by the same machinery as
				// the collection.
				tx.Undoable(fmt.Sprintf("add %s", draft))
				// NO KEY, AND NO COUNTER TO GET WRONG: a todo has no
				// identity of its own, so the binding mints one and hands
				// it back. Discarded here — this app looks a todo up by
				// nothing — and the toggle handler receives the same key
				// from the stamped row it came from.
				kaya.InsertFresh(tx, todos, Todo{Title: draft})
				// FINISHING THE FORM IS NOT PART OF THE STEP. Its own
				// transaction — posted, because a handler already holds
				// one and Go's answer to "another transaction, right
				// after this one" is Post — so undoing the add does not
				// put the draft back beside a todo that is gone, and
				// Clear inside a group would be refused at apply anyway
				// (D4), because it destroys widget-owned text the core
				// never held. The field empties on screen and reports
				// text_changed("") through its normal edit path (the
				// fold empties the draft), and the cursor lands back in
				// it.
				app.Post(func(tx *kaya.Tx) {
					tx.Clear(field)
					tx.Focus(field)
				})
			})
			tx.Label(itemsLeft)
			// The tracing tier: the for statement IS the For — the
			// body runs once over the generated row surface
			// (exact-index tokens, no probes), and range-over-func
			// makes the close structural, even on break.
			for row := range TodoRows(tx, todos) {
				row.Row(func() {
					row.Checkbox(row.Done(),
						func(tx *kaya.Tx, key int64, checked bool) {
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

	return app
}
