// The undo scene from Go: two tiers, one Edit menu, and one ledger that
// orders them (DESIGN.md, Menus; docs/undo-plan.md D1-D6, §3).
//
// WHAT AN APP WRITES FOR UNDO IS ONE CALL PER STEP. tx.Undoable(...)
// names a transaction, and that name is the step: the core keeps the
// inverse of what the batch did to signals and collections, and hands it
// back through the window's OnUndone. There is no undo stack in this
// file, no command objects, and no re-run of any handler — an undo is a
// programmatic write of the state that was there before, which is why it
// emits nothing and why the occurrence carries the whole delta.
//
// THE FIELD'S OWN TYPING UNDO IS THE PLATFORM'S, and this app writes
// nothing for it at all. Both tiers arrive through the same Edit>Undo
// item, and which one answers is kaya's routing question, not the app's
// (D6).
//
// THE SCENARIO THAT MOTIVATED THE MILESTONE is the add button, which is
// the entry scene's add: it appends a todo AND empties the field. Two
// transactions, deliberately — the undoable group is the insert and the
// status it wrote, and the clear that finishes the form is not part of
// the step. Under two unordered stacks one Cmd+Z takes back the CLEAR:
// "milk" returns to the field, the todo stays, and the user is looking
// at a state that never existed (docs/undo-plan.md §2). Here it takes
// back the ADD.
//
// It is also the design saying the same thing twice: Clear inside a
// group is REFUSED at apply, because it destroys widget-owned text the
// core never held (D4). Undo restores state, and state is signals plus
// collections.
//
// Canonical semantics in guests/rust/undo.rs; the byte-frozen contract
// in tools/scenes/undo.steps.
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

// what the history label says a step was. A typing episode has no
// authored name and kaya invents none ("Undo Typing" is an Apple
// convention, not a scene string — docs/undo-plan.md D8), so the empty
// label is the app's to spell.
func what(label string) string {
	if label == "" {
		return "typing"
	}
	return label
}

func main() {
	app := kaya.NewApp()

	// The fold: widget-owned state arrives as occurrences; the app's
	// copy is this variable, not a widget read.
	draft := ""
	nextKey := 0

	var (
		status, history kaya.Signal[string]
		field           kaya.Widget
		todos           kaya.Collection
	)

	app.Build(func(tx *kaya.Tx) {
		// THE HISTORY OBSERVERS RIDE THE WINDOW CONSTRUCT, beside the
		// title, because the ledger they watch is per window. Persistent:
		// a history is walked as often as the user likes. The binding has
		// already reconciled its collection mirror from this payload
		// before the handler runs, which is why tx.Len answers about the
		// restored state.
		//
		// THE DELTA IS THE ONLY NOTIFICATION for the restored text:
		// restoring an episode is a programmatic write, and a
		// programmatic write never echoes, so an app that folds
		// text_changed into its own model — which is every app, the field
		// being uncontrolled — would go stale on exactly this step if the
		// payload did not carry it (D5).
		win := tx.Window(0).Title("undo").
			OnUndone(func(tx *kaya.Tx, label string, delta kaya.UndoDelta) {
				if n := len(delta.Texts); n > 0 {
					draft = delta.Texts[n-1].Text
				}
				total := tx.Len(todos)
				tx.Write(history, fmt.Sprintf("undid %s, %d total", what(label), total))
			}).
			OnRedone(func(tx *kaya.Tx, label string, delta kaya.UndoDelta) {
				if n := len(delta.Texts); n > 0 {
					draft = delta.Texts[n-1].Text
				}
				total := tx.Len(todos)
				tx.Write(history, fmt.Sprintf("redid %s, %d total", what(label), total))
			})

		// THE GESTURE LAYER, one tier deeper: an app declares the two
		// items and writes nothing else. They act on the focused widget,
		// lower to the platform's own command where it has one, and work
		// out their own enablement from what is focused and what the
		// ledger holds.
		edit := win.Menu("Edit")
		edit.Item("Undo").Role(kaya.RoleUndo)
		edit.Item("Redo").Role(kaya.RoleRedo)

		status = tx.Signal("no todos")
		history = tx.Signal("history empty")
		todos = tx.Collection()

		root := tx.Column(func() {
			tx.Label(status).A11yID("status")   // label#0
			tx.Label(history).A11yID("history") // label#1
			field = tx.Entry(func(tx *kaya.Tx, text string) {
				draft = text
			}).A11yID("draft") // entry#0

			tx.Button("add", func(tx *kaya.Tx) { // button#0
				if draft == "" {
					total := tx.Len(todos)
					tx.Write(status, fmt.Sprintf("nothing to add, %d total", total))
					return
				}
				nextKey++
				// ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The name
				// is what the step is called; everything in this batch
				// is what it did.
				tx.Undoable(fmt.Sprintf("add %s", draft))
				tx.Insert(todos, fmt.Sprintf("t%d", nextKey), draft)
				total := tx.Len(todos)
				tx.Write(status, fmt.Sprintf("added %s, %d total", draft, total))
				// A PURE EFFECT rides along and is simply not restored:
				// undo restores state, not where you were looking (A2).
				tx.Focus(field)
				// FINISHING THE FORM IS NOT PART OF THE STEP. Its own
				// transaction — posted, because a handler already holds
				// one and Go's answer to "another transaction, right
				// after this one" is Post — so undoing the add does not
				// put the draft back beside a todo that is gone, and
				// Clear inside a group would be refused anyway. The
				// field empties on screen and reports text_changed("")
				// through its normal edit path, so the fold above
				// empties the draft.
				app.Post(func(tx *kaya.Tx) { tx.Clear(field) })
			})
			// A group at its smallest: one signal write, which is the
			// undoable set's whole vocabulary on the reactive side.
			tx.Button("star", func(tx *kaya.Tx) { // button#1
				tx.Undoable("star")
				tx.Write(status, "starred")
			})
			// THE SCENE'S WAY BACK TO THE FIELD. `star` does not move
			// the cursor on its own — an app that reaches for focus
			// after every action is deciding where the user is looking —
			// so the scene says so itself, and the routing question
			// ("what is focused?") stays visible in the script rather
			// than hidden in a handler.
			tx.Button("focus", func(tx *kaya.Tx) { // button#2
				tx.Focus(field)
			})
			for row := range todos.Rows(tx) {
				row.Row(func() {
					row.Label(row.Value())
				})
			}
		})
		// THE SCENE TYPES WITH REAL KEYSTROKES, so something has to be
		// holding focus when it does — and focus is the routing
		// question's other half.
		tx.Focus(field)
		tx.Mount(root)
	})

	os.Exit(app.Run())
}
