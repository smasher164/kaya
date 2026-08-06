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
// AND THE APP NAMES NO TODO. A todo is a title and nothing else — it has
// no identity of its own — so the key comes from InsertFresh, which
// mints one per collection instance and hands it back
// (docs/fresh-key-plan.md). What that buys here is the whole point of
// the minter: this file used to carry nextKey, a counter beside the
// collection whose safety rested on never rewinding, and an undo that
// rewound it would have handed the same name to two todos.
//
// Canonical semantics in guests/rust/undo.rs; the byte-frozen contract
// in tools/scenes/undo.steps.
package main

import (
	"fmt"
	"maps"
	"os"
	"runtime"
	"slices"
	"strconv"
	"strings"

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

// keyList is the app's collection mirror, rendered: every key it holds,
// in the order it holds them.
//
// THIS IS THE ONLY PART OF AN UNDO A COUNT CANNOT SEE. A restored entry
// that came back under a fresh name, or at the end instead of where it
// was, leaves every total in this file correct — the entries and orders
// runs of the delta are what say otherwise, and this is where the scene
// reads them (D5).
func keyList(tx *kaya.Tx, todos kaya.Collection) string {
	items := tx.Items(todos)
	if len(items) == 0 {
		return "no keys"
	}
	keys := make([]string, len(items))
	for i, e := range items {
		// The minter's keys are I64, and this app never spells one
		// itself, so the assertion is the honest read: a key of any
		// other type here would be a binding bug, not a case to handle.
		keys[i] = strconv.FormatInt(e.Key.(int64), 10)
	}
	return "keys " + strings.Join(keys, ",")
}

// rowKey is the row a stamped copy's occurrence names: the copy's key
// path, which for a top-level For is one key — the todo's own, minted by
// InsertFresh and asserted here exactly as keyList asserts the
// collection's own keys.
func rowKey(path []any) int64 {
	return path[0].(int64)
}

// noteList is the app's copy of what is typed in the ROWS, rendered:
// every note it holds, by key, ascending.
//
// THE ROWS' FIELDS ARE UNCONTROLLED LIKE THE DRAFT, so this map is the
// app's own and nothing reads it back off a widget. It is also where
// this scene proves the payload's new shape: an undone note arrives
// naming (template node, key path), and an app with two rows can only
// put it back in the right one because the path says which.
func noteList(notes map[int64]string) string {
	if len(notes) == 0 {
		return "no notes"
	}
	// A Go map has no order at all, so the ascending walk is spelled
	// rather than assumed — the script compares this string
	// byte-for-byte against seven other languages, three of which get
	// the order free from a sorted map.
	rendered := make([]string, 0, len(notes))
	for _, key := range slices.Sorted(maps.Keys(notes)) {
		rendered = append(rendered, strconv.FormatInt(key, 10)+"="+notes[key])
	}
	return "notes " + strings.Join(rendered, ",")
}

// foldTexts folds one texts run into the app's two mirrors of
// widget-owned text. The empty path is the draft; a path names a row.
//
// AN EMPTY NOTE IS NO NOTE, which is what makes the undo falsifiable:
// the restore of a row's field to "" has to REMOVE the key, so an app
// that ignored this run reads its stale note back out and the script
// says so.
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

func main() {
	app := kaya.NewApp()

	// The fold: widget-owned state arrives as occurrences; the app's
	// copy is these variables, not a widget read. Two of them, because
	// there are two kinds of text field on screen — the draft, and one
	// per row — and the payload's path is what tells them apart.
	draft := ""
	rowNotes := map[int64]string{}

	var (
		status, history, keys, notes kaya.Signal[string]
		field                        kaya.Widget
		note                         kaya.Node
		todos                        kaya.Collection
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
		//
		// THE RUN IS FOLDED WHOLE, not reduced to its last string,
		// because an entry NAMES the field it restores: the empty path
		// is the draft, and a path names the row whose note came back.
		win := tx.Window(0).Title("undo").
			OnUndone(func(tx *kaya.Tx, label string, delta kaya.UndoDelta) {
				foldTexts(&draft, rowNotes, delta.Texts)
				total := tx.Len(todos)
				tx.Write(history, fmt.Sprintf("undid %s, %d total", what(label), total))
				// ONE TRANSACTION WITH THE LABEL ABOVE, deliberately: the
				// script reads that label first, so by the time it reads
				// this one the app's own answer is what is on screen —
				// not the value the core restored on its way past. The
				// notes ride the same transaction for the same reason.
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
		// items and writes nothing else. They act on the focused widget,
		// lower to the platform's own command where it has one, and work
		// out their own enablement from what is focused and what the
		// ledger holds.
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
				// ONE CALL, AND IT IS THE WHOLE UNDO SURFACE. The name
				// is what the step is called; everything in this batch
				// is what it did.
				tx.Undoable(fmt.Sprintf("add %s", draft))
				// NO KEY, AND NO COUNTER TO GET WRONG: the binding mints
				// the name and hands it back. This app has no use for it
				// — a todo is looked up by nothing — and an app that does
				// (selecting the new row, say) takes it from here rather
				// than inventing a second name for the same datum. Go's
				// way of discarding a result is a call statement.
				tx.InsertFresh(todos, draft)
				total := tx.Len(todos)
				tx.Write(status, fmt.Sprintf("added %s, %d total", draft, total))
				tx.Write(keys, keyList(tx, todos))
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
			// THE STEP WHOSE INVERSE IS AN IDENTITY, not a content. The
			// core captured the entry and the instance's order before the
			// removal, so undoing this puts the entry back under the key
			// it already had, where it already was — neither of which
			// this app has to remember. The target is the collection's
			// FIRST entry, taken from the model, never from a widget.
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
					// THE ROW'S OWN FIELD, and the reason this scene
					// grew: a copy's text edits are the same occurrence
					// a live field's are, one identity deeper, and the
					// ledger banks them the same way now that the
					// payload can name them. The template tier has no
					// Entry sugar — there is no source to bind — so the
					// widget-kind floor is the spelling here, in every
					// language.
					note = row.Widget(kaya.KindEntry)
				})
			}
		})
		// THE SCENE TYPES WITH REAL KEYSTROKES, so something has to be
		// holding focus when it does — and focus is the routing
		// question's other half.
		tx.Focus(field)
		tx.Mount(root)
	})

	// The row field's edits, folded exactly as the payload's restore of
	// the same field will be — one rule, two arrival paths, so the
	// script's assertion cannot pass through a second spelling of "what
	// a note is". A stamped copy's handler is registered once against
	// the TEMPLATE NODE and hands the copy's keys, which is the same
	// (node, key path) identity the undo payload carries; the live
	// zone's func(*Tx, string) has nowhere to put them.
	app.OnChangeNode(note, func(tx *kaya.Tx, path []any, text string) {
		key := rowKey(path)
		if text == "" {
			delete(rowNotes, key)
		} else {
			rowNotes[key] = text
		}
		tx.Write(notes, noteList(rowNotes))
	})

	os.Exit(app.Run())
}
