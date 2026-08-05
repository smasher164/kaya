// The entry scene from Go: the uncontrolled contract end to end. The
// field owns its text and reports each edit through OnChange; the app
// folds those into a plain variable (draft) — its own model, per
// doctrine. The add button inserts the draft and answers with the count
// read from the collection model.
//
// WHAT THIS SCENE DOCUMENTS IS THE OTHER EVENT SURFACE. Go's sugar
// constructors carry their handler (`tx.Button("add", onClick)`), which
// is how every other Go guest spells it; here the two handlers are
// registered on the APP after the build, against the widgets the build
// handed back — the same registry the constructors call into, reached
// by its own name. Construction is the ordinary sugar either way
// (DESIGN.md, entry's scope ratified 2026-08-05): the carve-out is the
// event mechanism, not the tree.
//
// The backend selftest (KAYA_SELFTEST=entry) types "milk", clicks add,
// and expects the status label to read "added milk, 1 total", the
// field cleared and refocused (the one-shot commands riding the same
// transaction as the insert), and a second add to answer "nothing to
// add, 1 total" — proving the clear's text_changed("") re-entered
// through the normal fold and emptied the draft.
//
// Build the library first (cargo build), then, from the repo root:
//
//	KAYA_SELFTEST=entry go run dev.kaya/guests/go/entry
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

func main() {
	app := kaya.NewApp()

	var (
		status     kaya.Signal[string]
		field, add kaya.Widget
		todos      kaya.Collection
	)

	// The construction sugar: the container takes its children through
	// the body, so the build reads as the tree, and the constructors
	// carry their props. Both handler arguments are nil — the two
	// widgets whose events this app wants are named again below, which
	// is the whole of what this scene spells differently.
	app.Build(func(tx *kaya.Tx) {
		status = tx.Signal("no todos")
		todos = tx.Collection()

		tx.Mount(tx.Column(func() {
			field = tx.Entry(nil)
			add = tx.Button("add", nil)
			tx.Label(status)
			// The tracing tier: the for statement IS the For — the body
			// runs once, authoring the blueprint — and a scalar
			// collection's element is the row's one token.
			for row := range todos.Rows(tx) {
				row.Label(row.Value())
			}
		}))
	})

	// The fold: widget-owned state arrives as occurrences; the app's
	// copy is this variable, not a widget read.
	draft := ""
	app.OnChange(field, func(tx *kaya.Tx, text string) {
		draft = text
	})
	app.OnClick(add, func(tx *kaya.Tx) {
		// The empty-draft guard every real form has — and the scene's
		// proof that clear emptied the draft through the occurrence
		// fold, not a side assignment.
		if draft == "" {
			total := tx.Len(todos)
			tx.Write(status, fmt.Sprintf("nothing to add, %d total", total))
			return
		}
		// NO KEY, AND NO COUNTER TO GET WRONG: a line of text has no
		// identity of its own, so the binding mints the name and hands
		// it back (docs/fresh-key-plan.md). Go discards a result by
		// calling in statement position; an app that needed the name —
		// to select the new row, say — takes it from here rather than
		// inventing a second name for the same datum.
		tx.InsertFresh(todos, draft)
		total := tx.Len(todos)
		tx.Write(status, fmt.Sprintf("added %s, %d total", draft, total))
		// Finish the form: drop the field's content and put the cursor
		// back, atomically with the insert. The field answers with
		// text_changed("") through its normal edit path, and OnChange
		// empties the draft.
		tx.Clear(field)
		tx.Focus(field)
	})

	os.Exit(app.Run())
}
