// The undo scene from Go: two tiers, one Edit menu, and one ledger that
// orders them (DESIGN.md, Menus; docs/undo-plan.md D1-D6, §3).
//
// WHAT AN APP WRITES FOR UNDO IS ONE CALL PER STEP. tx.Undoable(...)
// names a transaction and that name is the step; there is no undo stack
// in this file, no command objects, and no re-run of any handler.
//
// THE ADD IS TWO TRANSACTIONS, DELIBERATELY: the undoable group is the
// insert and the status it wrote, and the clear that finishes the form is
// not part of the step. Merged, one Cmd+Z would take back the CLEAR and
// leave a state that never existed (docs/undo-plan.md §2). Clear inside a
// group is refused at apply anyway, because it destroys widget-owned text
// the core never held (D4).
//
// Canonical semantics in guests/rust/undo.rs; the byte-frozen contract in
// tools/scenes/undo.steps.
package undo

import (
	"fmt"
	"maps"
	"slices"
	"strconv"
	"strings"

	kaya "dev.kaya/bindings/go"
)

// what the history label says a step was. A typing episode has no
// authored name and kaya invents none (docs/undo-plan.md D8), so the
// empty label is the app's to spell.
func what(label string) string {
	if label == "" {
		return "typing"
	}
	return label
}

// keyList is the app's collection mirror, rendered. THIS IS THE ONLY PART
// OF AN UNDO A COUNT CANNOT SEE: an entry restored under a fresh name, or
// at the end instead of where it was, leaves every total in this file
// correct — the delta's entries and orders runs are what say otherwise,
// and this is where the scene reads them (D5).
func keyList(tx *kaya.Tx, todos kaya.Collection) string {
	items := tx.Items(todos)
	if len(items) == 0 {
		return "no keys"
	}
	keys := make([]string, len(items))
	for i, e := range items {
		// The minter's keys are I64; any other type here would be a
		// binding bug.
		keys[i] = strconv.FormatInt(e.Key.(int64), 10)
	}
	return "keys " + strings.Join(keys, ",")
}

// rowKey is the row a stamped copy's occurrence names: for a top-level
// For, one key — the todo's own, minted by InsertFresh.
func rowKey(path []any) int64 {
	return path[0].(int64)
}

// noteList is the app's copy of what is typed in the ROWS. An undone note
// arrives naming (template node, key path), and an app with two rows can
// only put it back in the right one because the path says which.
func noteList(notes map[int64]string) string {
	if len(notes) == 0 {
		return "no notes"
	}
	// A Go map has no order at all, so the ascending walk is spelled
	// rather than assumed: this string is compared byte-for-byte against
	// seven other languages.
	rendered := make([]string, 0, len(notes))
	for _, key := range slices.Sorted(maps.Keys(notes)) {
		rendered = append(rendered, strconv.FormatInt(key, 10)+"="+notes[key])
	}
	return "notes " + strings.Join(rendered, ",")
}

// foldTexts folds one texts run into the app's two mirrors of
// widget-owned text. The empty path is the draft; a path names a row. AN
// EMPTY NOTE IS NO NOTE — the restore of a row's field to "" has to
// REMOVE the key, which is what makes the undo falsifiable.
func foldTexts(draft *string, notes map[int64]string, texts []kaya.UndoText) {
	for _, text := range texts {
		switch {
		case len(text.Path) == 0:
			*draft = text.Text
		case text.Text == "":
			delete(notes, rowKey(text.Path))
		default:
			notes[rowKey(text.Path)] = text.Text
		}
	}
}

func App() *kaya.App {
	app := kaya.NewApp()

	// The fold: two mirrors, because there are two kinds of text field on
	// screen, and the payload's path is what tells them apart.
	draft := ""
	rowNotes := map[int64]string{}

	var (
		status, history, keys, notes kaya.Signal[string]
		field                        kaya.Widget
		note                         kaya.Node
		todos                        kaya.Collection
	)

	app.Build(func(tx *kaya.Tx) {
		// THE HISTORY OBSERVERS RIDE THE WINDOW CONSTRUCT: the ledger is
		// per window, and they are persistent. THE DELTA IS THE ONLY
		// NOTIFICATION for restored text — restoring is a programmatic
		// write and a programmatic write never echoes — and THE RUN IS
		// FOLDED WHOLE, because each entry names the field it restores
		// (D5).
		win := tx.Window(0).Title("undo").
			OnUndone(func(tx *kaya.Tx, label string, delta kaya.UndoDelta) {
				foldTexts(&draft, rowNotes, delta.Texts)
				total := tx.Len(todos)
				tx.Write(history, fmt.Sprintf("undid %s, %d total", what(label), total))
				// ONE TRANSACTION WITH THE LABEL ABOVE, deliberately: the
				// script reads that label first, so by the time it reads
				// this one the app's own answer is what is on screen, not
				// the value the core restored on its way past.
				tx.Write(keys, keyList(tx, todos))
				tx.Write(notes, noteList(rowNotes))
			}).
			OnRedone(func(tx *kaya.Tx, label string, delta kaya.UndoDelta) {
				foldTexts(&draft, rowNotes, delta.Texts)
				total := tx.Len(todos)
				tx.Write(history, fmt.Sprintf("redid %s, %d total", what(label), total))
				tx.Write(keys, keyList(tx, todos))
				tx.Write(notes, noteList(rowNotes))
			})

		// THE GESTURE LAYER, one tier deeper: an app declares the two
		// items and writes nothing else.
		edit := win.Menu("Edit")
		edit.Item("Undo").Role(kaya.RoleUndo)
		edit.Item("Redo").Role(kaya.RoleRedo)

		status = tx.Signal("no todos")
		history = tx.Signal("history empty")
		keys = tx.Signal("no keys")
		notes = tx.Signal("no notes")
		todos = tx.Collection()

		root := tx.Column(func() {
			tx.Label(status).A11yID("status")   // label#0
			tx.Label(history).A11yID("history") // label#1
			tx.Label(keys).A11yID("keys")       // label#2
			tx.Label(notes).A11yID("notes")     // label#3
			field = tx.Entry(func(tx *kaya.Tx, text string) {
				draft = text
			}).A11yID("draft") // entry#0

			tx.Button("add", func(tx *kaya.Tx) { // button#0
				if draft == "" {
					total := tx.Len(todos)
					tx.Write(status, fmt.Sprintf("nothing to add, %d total", total))
					return
				}
				// ONE CALL, AND IT IS THE WHOLE UNDO SURFACE.
				tx.Undoable(fmt.Sprintf("add %s", draft))
				// NO KEY: the binding mints the name and hands it back,
				// and this app has no use for it.
				tx.InsertFresh(todos, draft)
				total := tx.Len(todos)
				tx.Write(status, fmt.Sprintf("added %s, %d total", draft, total))
				tx.Write(keys, keyList(tx, todos))
				// A PURE EFFECT rides along and is simply not restored:
				// undo restores state, not where you were looking (A2).
				tx.Focus(field)
				// FINISHING THE FORM IS NOT PART OF THE STEP — its own
				// transaction, so undoing the add does not put the draft
				// back beside a todo that is gone. The field reports
				// text_changed("") and the fold above empties draft.
				app.Post(func(tx *kaya.Tx) { tx.Clear(field) })
			})
			// A group at its smallest: one signal write.
			tx.Button("star", func(tx *kaya.Tx) { // button#1
				tx.Undoable("star")
				tx.Write(status, "starred")
			})
			// THE SCENE'S WAY BACK TO THE FIELD: star does not move the
			// cursor on its own, so the routing question stays visible in
			// the script rather than hidden in a handler.
			tx.Button("focus", func(tx *kaya.Tx) { // button#2
				tx.Focus(field)
			})
			// THE STEP WHOSE INVERSE IS AN IDENTITY, not a content: the
			// core captured the entry and the instance's order before the
			// removal. The target is the collection's FIRST entry, taken
			// from the model, never from a widget.
			tx.Button("remove", func(tx *kaya.Tx) { // button#3
				items := tx.Items(todos)
				if len(items) == 0 {
					total := tx.Len(todos)
					tx.Write(status, fmt.Sprintf("nothing to remove, %d total", total))
					return
				}
				first := items[0]
				title := first.Value.(string)
				tx.Undoable(fmt.Sprintf("remove %s", title))
				tx.Remove(todos, first.Key)
				total := tx.Len(todos)
				tx.Write(status, fmt.Sprintf("removed %s, %d total", title, total))
				tx.Write(keys, keyList(tx, todos))
			})
			for row := range todos.Rows(tx) {
				row.Row(func() {
					row.Label(row.Value())
					// THE ROW'S OWN FIELD: a copy's text edits are the
					// same occurrence a live field's are, one identity
					// deeper, and the ledger banks them the same way.
					// Nothing binds it — the unbound Entry is the
					// template-zone constructor for exactly this case,
					// and EntryBound is the one that seeds a copy from
					// its row.
					note = row.Entry()
				})
			}
		})
		// THE SCENE TYPES WITH REAL KEYSTROKES, so something has to be
		// holding focus when it does.
		tx.Focus(field)
		tx.Mount(root)
	})

	// The row field's edits, folded exactly as the payload's restore of
	// the same field will be — one rule, two arrival paths. A stamped
	// copy's handler is registered once against the TEMPLATE NODE and
	// hands the copy's keys; the live zone's func(*Tx, string) has
	// nowhere to put them.
	app.OnChangeNode(note, func(tx *kaya.Tx, path []any, text string) {
		key := rowKey(path)
		if text == "" {
			delete(rowNotes, key)
		} else {
			rowNotes[key] = text
		}
		tx.Write(notes, noteList(rowNotes))
	})

	return app
}
