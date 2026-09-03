// The undo conformance scene (tools/scenes/undo.steps). THE ADD IS TWO
// TRANSACTIONS: `clear` inside a group is refused at apply.
package undo

import (
	"fmt"
	"maps"
	"slices"
	"strconv"
	"strings"

	kaya "dev.kaya/bindings/go"
)

// kaya invents no name for a typing episode: the empty label is the app's.
func what(label string) string {
	if label == "" {
		return "typing"
	}
	return label
}

// THE ONLY PART OF AN UNDO A COUNT CANNOT SEE: a restore under a fresh
// name, or at the wrong position, leaves every total here correct.
func keyList(tx *kaya.Tx, todos kaya.Collection) string {
	items := tx.Items(todos)
	if len(items) == 0 {
		return "no keys"
	}
	keys := make([]string, len(items))
	for i, e := range items {
		keys[i] = strconv.FormatInt(e.Key.(int64), 10)
	}
	return "keys " + strings.Join(keys, ",")
}

// rowKey is the row a stamped copy's occurrence names.
func rowKey(path []any) int64 {
	return path[0].(int64)
}

// An undone note names (node, key path): the path says which row it is.
func noteList(notes map[int64]string) string {
	if len(notes) == 0 {
		return "no notes"
	}
	// Spelled, not assumed: this string is byte-compared against seven other
	// languages.
	rendered := make([]string, 0, len(notes))
	for _, key := range slices.Sorted(maps.Keys(notes)) {
		rendered = append(rendered, strconv.FormatInt(key, 10)+"="+notes[key])
	}
	return "notes " + strings.Join(rendered, ",")
}

// The empty path is the draft, a path names a row, and AN EMPTY NOTE IS NO
// NOTE: a field restored to "" must REMOVE the key.
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

	draft := ""
	rowNotes := map[int64]string{}

	var (
		status, history, keys, notes kaya.Signal[string]
		field                        kaya.Widget
		note                         kaya.Node
		todos                        kaya.Collection
	)

	app.Build(func(tx *kaya.Tx) {
		// The ledger is per window. THE DELTA IS THE ONLY NOTIFICATION for
		// restored text, and the run is folded WHOLE.
		win := tx.Window(0).Title("undo").
			OnUndone(func(tx *kaya.Tx, label string, delta kaya.UndoDelta) {
				foldTexts(&draft, rowNotes, delta.Texts)
				total := tx.Len(todos)
				tx.Write(history, fmt.Sprintf("undid %s, %d total", what(label), total))
				// One transaction with the label above: the script reads that
				// first.
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
				tx.Undoable(fmt.Sprintf("add %s", draft))
				// NO KEY: the binding mints the name and hands it back.
				tx.InsertFresh(todos, draft)
				total := tx.Len(todos)
				tx.Write(status, fmt.Sprintf("added %s, %d total", draft, total))
				tx.Write(keys, keyList(tx, todos))
				// A PURE EFFECT, and not restored (docs/undo-plan.md A2).
				tx.Focus(field)
				// Its OWN transaction; the field's text_changed("") empties
				// the draft through the fold above.
				app.Post(func(tx *kaya.Tx) { tx.Clear(field) })
			})
			tx.Button("star", func(tx *kaya.Tx) { // button#1
				tx.Undoable("star")
				tx.Write(status, "starred")
			})
			// The scene's way back to the field: star does not move focus.
			tx.Button("focus", func(tx *kaya.Tx) { // button#2
				tx.Focus(field)
			})
			// The core captured entry and order; this app holds neither.
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
			for row := range tx.Rows(todos).All() {
				row.Row(func() {
					row.Label(row.Value())
					// Unbound: EntryBound is the one that seeds from its row.
					note = row.Entry()
				})
			}
		})
		// The scene types with real keystrokes: something must hold focus.
		tx.Focus(field)
		tx.Mount(root)
	})

	// One rule, two arrival paths. A stamped copy's handler registers once
	// against the TEMPLATE NODE and hands the copy's keys.
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
