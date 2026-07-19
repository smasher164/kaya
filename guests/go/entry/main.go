// The entry scene from Go: the uncontrolled contract end to end. The
// field owns its text and reports each edit through OnChange; the app
// folds those into a plain variable (draft) — its own model, per
// doctrine. The add button inserts the draft and answers with the count
// read from the collection model.
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
		status       kaya.Signal[string]
		field, add   kaya.Widget
		todos        kaya.Collection
	)

	app.Build(func(tx *kaya.Tx) {
		status = tx.Signal("no todos")

		column := tx.Widget(kaya.KindColumn)
		field = tx.Widget(kaya.KindEntry)
		add = tx.Widget(kaya.KindButton)
		tx.SetText(add, "add")
		statusLabel := tx.Widget(kaya.KindLabel)
		tx.BindText(statusLabel, status)

		todos = tx.Collection()
		todoList := tx.ForEach(todos, func(t *kaya.Tpl) {
			label := t.Widget(kaya.KindLabel)
			t.BindTextElement(label, 0)
		})

		tx.AddChild(column, field)
		tx.AddChild(column, add)
		tx.AddChild(column, statusLabel)
		tx.AddChild(column, todoList)
		tx.Mount(column)
	})

	// The fold: widget-owned state arrives as occurrences; the app's
	// copy is this variable, not a widget read.
	draft := ""
	nextKey := 0
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
		nextKey++
		tx.Insert(todos, fmt.Sprintf("t%d", nextKey), draft)
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
