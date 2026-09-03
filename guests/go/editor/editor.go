// THE TEXT EDITOR — kaya's forcing artifact (docs/editor-plan.md).
// Written in Go, on the sugar tier. Byte-frozen contract:
// tools/scenes/editor.steps.
//
// TWO FRAMEWORK CONSTRAINTS IT BENDS AROUND, both in docs/traps.md:
//
//   - The find bar is a For over a ONE-ROW collection and not a `When`:
//     "A live-zone `When` stamps an EMPTY key path".
//   - `quit` below leaves the framework with os.Exit, because an app
//     cannot agree to a close: "An app can VETO a close but cannot AGREE
//     to one".
package editor

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"

	kaya "dev.kaya/bindings/go"
)

// sceneRoot is the directory the picker and the app can BOTH see, and it
// is not temp everywhere: an Android provider cannot see an app's private
// storage and iOS's picker cannot see its container, so each phone names
// the place its own file browser reaches.
//
// kaya.Env AND NOT os.Getenv — tools/check-go-env.py's header carries the
// measurement and the rule.
func sceneRoot() string {
	switch runtime.GOOS {
	case "android":
		root := kaya.Env("EXTERNAL_STORAGE")
		if root == "" {
			root = "/sdcard"
		}
		return filepath.Join(root, "Documents")
	case "ios":
		return filepath.Join(kaya.Env("HOME"), "Documents")
	}
	return os.TempDir()
}

// workingDir is where this app's documents live for a scene run. The pid
// keeps parallel legs from colliding, and the script names it the same
// way ($TMP/kaya-editor-$PID).
func workingDir() string {
	return filepath.Join(sceneRoot(), "kaya-editor-"+strconv.Itoa(os.Getpid()))
}

// notesDoc is the document the scene opens: 59 short lines with exactly
// three numeric tokens. TALL ON PURPOSE — reveal_range moves a viewport,
// and on a document that fits there is nothing to move.
//
// A RAW STRING LITERAL, and the opening backtick is followed immediately
// by `top 7`: a newline there would be a byte of document, and every
// offset in the scene script would move.
const notesDoc = `top 7
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
mid 13
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
.
end 42`

// readDoc reads a picked file whole. THE BYTES ARE THE ASSERTION and
// never what the app hoped.
func readDoc(file kaya.PickedFile) (string, error) {
	f, _, err := file.Open(kaya.FileModeRead)
	if err != nil {
		return "", err
	}
	defer f.Close()
	b, err := io.ReadAll(f)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// writeDoc writes the document through the handle and answers with what
// the FILE says afterwards, reopened and counted. FileModeWrite truncates
// on a picked file and on a save destination alike; the destination adds
// the create (docs/save-plan.md D1).
func writeDoc(file kaya.PickedFile, body string) (int, error) {
	f, _, err := file.Open(kaya.FileModeWrite)
	if err != nil {
		return 0, err
	}
	if _, err := f.Write([]byte(body)); err != nil {
		f.Close()
		return 0, err
	}
	// CLOSED BEFORE THE REOPEN, so what comes back is the file's.
	if err := f.Close(); err != nil {
		return 0, err
	}
	back, err := readDoc(file)
	if err != nil {
		return 0, err
	}
	return len(back), nil
}

// untitled is what an editor calls a buffer that has no destination yet.
const untitled = "untitled"

// docName is the window's name: the destination's own name, or the
// convention above. THE PICKER'S NAME IS ALREADY A BASENAME on every
// platform and tools/scenes/editor.steps pins that byte-for-byte, so
// there is no filepath.Base here, which on Android would be claiming a
// display name is a path.
func docName(dest *kaya.PickedFile) string {
	if dest == nil {
		return untitled
	}
	return dest.Name
}

const findKey = "bar"

// tally is what the find bar says about a set. Spelled rather than
// formatted, because "1 matches" is what a person reads otherwise.
func tally(n int) string {
	switch n {
	case 0:
		return "no matches"
	case 1:
		return "1 match"
	}
	return fmt.Sprintf("%d matches", n)
}

func App() *kaya.App {
	app := kaya.NewApp()

	// THE DECOY IS LOAD-BEARING and sorts first: with ONE file in a
	// directory a picker completes with it when nothing was selected, so
	// the choose step would pass on a backend that never selected anything
	// (docs/traps.md).
	dir := workingDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		panic("kaya: the editor could not make its working directory: " + err.Error())
	}
	if err := os.WriteFile(filepath.Join(dir, "notes"), []byte(notesDoc), 0o644); err != nil {
		panic("kaya: the editor could not write its notes document: " + err.Error())
	}
	if err := os.WriteFile(filepath.Join(dir, "decoy"), []byte("decoy"), 0o644); err != nil {
		panic("kaya: the editor could not write the decoy: " + err.Error())
	}

	// text is the app's authority on what the document says, saved is what
	// the destination holds, and the comparison is the dirty mark.
	text := ""
	saved := ""
	var dest *kaya.PickedFile

	// open is the app's own copy of whether the bar is up, because a
	// signal is written and never read back.
	pattern := ""
	var hits []kaya.TextRange
	at := 0
	open := false

	var (
		buffer        kaya.Widget
		status, count kaya.Signal[string]
		// THE FIND BAR IS A COLLECTION WITH EITHER NO ROWS OR ONE, and
		// that is a WORKAROUND with a measured reason: docs/traps.md, "A
		// live-zone `When` stamps an EMPTY key path".
		findRows kaya.Collection
		// The bar's widgets are TEMPLATE NODES, not widgets: their
		// handlers hang off the node (App.OnChangeNode / App.OnClickNode)
		// and are registered once, below Build.
		query, prev, next, done kaya.Node
	)

	mark := func(tx *kaya.Tx) { tx.Window(0).Dirty(text != saved) }

	// refind re-runs the search and RE-DECLARES the highlight set: a
	// declared set is bound to the text it was declared against, so any
	// edit drops it in the core (docs/ranges-plan.md D2). HIGHLIGHTS ONLY,
	// never the selection — this runs while somebody is typing.
	refind := func(tx *kaya.Tx) {
		hits = nil
		at = 0
		// THE TALLY IS THE BAR'S. It is the one part of find that stays in
		// the LIVE zone, because a stamped copy has no id an app can aim
		// select_range or reveal_range at.
		if !open {
			tx.HighlightRanges(buffer, nil)
			tx.Write(count, "")
			return
		}
		if pattern == "" {
			tx.HighlightRanges(buffer, nil)
			tx.Write(count, "no matches")
			return
		}
		// THE DIALECT IS GO'S: ordinary regular expressions, because the
		// engine is the APP's. A half-typed pattern is the ordinary case
		// in find-as-you-type, so a compile error is a state and not an
		// incident.
		re, err := regexp.Compile(pattern)
		if err != nil {
			tx.HighlightRanges(buffer, nil)
			tx.Write(count, "bad pattern")
			return
		}
		// THE OFFSETS ARE GO STRING INDICES AND NOTHING CONVERTS THEM; a
		// backend that counts UTF-16 converts on its own side.
		for _, m := range re.FindAllStringIndex(text, -1) {
			// AN EMPTY MATCH DECORATES NOTHING: a zero-width range is a
			// caret rather than a span. An app decision, not a framework one.
			if m[0] == m[1] {
				continue
			}
			hits = append(hits, kaya.TextRange{Start: m[0], End: m[1]})
		}
		tx.HighlightRanges(buffer, hits)
		tx.Write(count, tally(len(hits)))
	}

	show := func(tx *kaya.Tx, i int) {
		if len(hits) == 0 {
			return
		}
		n := len(hits)
		at = ((i % n) + n) % n
		tx.SelectRange(buffer, hits[at])
		tx.RevealRange(buffer, hits[at])
		tx.Write(count, fmt.Sprintf("%d of %d", at+1, n))
	}

	// retarget is the ONLY place the destination moves, which is why the
	// title is written here rather than at the three call sites. Only ever
	// called from a posted transaction, i.e. on the app goroutine, so it
	// needs no lock.
	retarget := func(tx *kaya.Tx, file *kaya.PickedFile, body string) {
		dest = file
		saved = body
		tx.Window(0).Title(docName(dest))
	}

	// saveTo writes off the app goroutine, which is what PickedFile.Open
	// tells every caller to do: it BLOCKS.
	saveTo := func(file kaya.PickedFile, body string) {
		go func() {
			n, err := writeDoc(file, body)
			app.Post(func(tx *kaya.Tx) {
				if err != nil {
					tx.Write(status, "save failed: "+err.Error())
					return
				}
				// body AND NOT text: the user may have typed while the
				// write was in flight, and what is on disk is what was
				// handed to the write.
				retarget(tx, &file, body)
				// NO FILE NAME HERE — the title bar has just been given
				// it. What is left is the byte count, READ BACK OFF THE
				// DISK.
				tx.Write(status, fmt.Sprintf("saved, %d bytes", n))
				mark(tx)
			})
		}()
	}

	openFrom := func(file kaya.PickedFile) {
		go func() {
			body, err := readDoc(file)
			app.Post(func(tx *kaya.Tx) {
				if err != nil {
					tx.Write(status, "open failed: "+err.Error())
					return
				}
				text = body
				retarget(tx, &file, body)
				// A PROGRAMMATIC WRITE, which does not echo, so the fold
				// is done by hand. It also spends the field's native undo
				// history and drops whatever ranges were declared.
				tx.SetText(buffer, body)
				tx.Focus(buffer)
				tx.Write(status, fmt.Sprintf("opened, %d bytes", len(body)))
				mark(tx)
				refind(tx)
			})
		}()
	}

	app.Build(func(tx *kaya.Tx) {
		// THE BRAND, before anything mounts (the set-once wall): one hex,
		// and the core derives every fill, foreground and state ramp from
		// it (docs/styling-plan.md D1). It is a REQUEST (D2) — a system
		// accent the user chose wins and this line is then a no-op.
		tx.BrandAccent(0x0F7B6C)
		// VETO_CLOSE says this window's close is the app's to answer. THE
		// TITLE IS docName(dest) FROM THE FIRST FRAME and not the literal,
		// so one expression names this window in all four places it can be
		// named. AND INSET 0 IS THE FULL BLEED (docs/styling-plan.md D3):
		// LAYOUT, not appearance — the phones' safe area is untouched.
		win := tx.Window(0).Title(docName(dest)).Size(640, 420).Inset(0).VetoClose(true)

		status = tx.Signal("new file")
		count = tx.Signal("")

		// ---- the actions the menus name ------------------------------

		newDoc := func(tx *kaya.Tx) {
			text = ""
			// THE DESTINATION IS DROPPED, and dropping it renames the
			// window back.
			retarget(tx, nil, "")
			tx.SetText(buffer, "")
			tx.Focus(buffer)
			tx.Write(status, "new file")
			mark(tx)
			refind(tx)
		}

		// openDoc shows the picker. NO FILTER, deliberately: the scene's
		// documents have no extensions, and a filter would hide them.
		openDoc := func(tx *kaya.Tx) {
			tx.PickFile().OnResult(func(tx *kaya.Tx, files []kaya.PickedFile) {
				if len(files) == 0 {
					tx.Write(status, "open cancelled")
					return
				}
				openFrom(files[0])
			}).Show()
		}

		// saveAs names a destination first. The panel OPENS with the name
		// the window is already showing, so the title bar and the panel
		// can never disagree about what this document is called.
		saveAs := func(tx *kaya.Tx) {
			suggested := docName(dest)
			body := text
			tx.SaveFile(suggested).OnResult(func(tx *kaya.Tx, file *kaya.PickedFile) {
				if file == nil {
					tx.Write(status, "save cancelled")
					return
				}
				saveTo(*file, body)
			}).Show()
		}

		// save needs no dialog once there is a destination: the handle the
		// user chose the file with is writable.
		save := func(tx *kaya.Tx) {
			if dest == nil {
				saveAs(tx)
				return
			}
			saveTo(*dest, text)
		}

		// ask is the unsaved-work guard, and it is a COMPOSITION: kaya has
		// no "confirm before you discard". The continuation is a closure
		// per call site.
		ask := func(tx *kaya.Tx, then func(*kaya.Tx)) {
			if text == saved {
				then(tx)
				return
			}
			tx.ShowAlert().
				Title("unsaved changes").
				Message("the document has unsaved changes").
				Action("Discard").
				Cancel("Keep Editing").
				OnResult(func(tx *kaya.Tx, choice uint32) {
					if choice == kaya.AlertChoiceCancel {
						return
					}
					then(tx)
				}).
				Show()
		}

		// quit is the answer to "yes, close it", and the ONE call in this
		// file that leaves the framework: an app cannot AGREE to a close —
		// docs/traps.md, "An app can VETO a close but cannot AGREE to
		// one". The platform's own quit chord is reserved away from apps,
		// so the close button is the only door an unsaved-work warning can
		// watch. Unreachable on the phones, which have no close affordance.
		quit := func(_ *kaya.Tx) { os.Exit(0) }

		// The close handler binds to THE WINDOW at its declaration.
		// Nothing has closed yet — that is what the veto class buys.
		win.OnCloseRequested(func(tx *kaya.Tx) { ask(tx, quit) })

		// ---- the menu bar --------------------------------------------
		file := win.Menu("File")
		file.Item("New").Shortcut("primary+n").OnActivate(func(tx *kaya.Tx) {
			ask(tx, newDoc)
		})
		file.Item("Open…").Shortcut("primary+o").OnActivate(func(tx *kaya.Tx) {
			ask(tx, openDoc)
		})
		// SAVE IS THE FIRST PRIMARY (docs/chrome-plan.md C2): the app
		// names no toolbar, no placement and no capacity, and the host
		// promotes the first k primaries in catalog preorder. SymbolDone
		// is the save idiom — the closed symbol set has no save-specific
		// glyph (docs/styling-plan.md D6).
		file.Item("Save").Symbol(kaya.SymbolDone).Primary(true).
			Shortcut("primary+s").OnActivate(save)
		file.Item("Save As…").Shortcut("primary+shift+s").OnActivate(saveAs)

		// EDIT IS SIX DECLARATIONS AND ONE HANDLER; five are ROLES, which
		// lower to the platform's own command, act on whatever is focused,
		// and work out their own enablement. NO SHORTCUTS ON THE ROLES: a
		// role already carries the platform's own chord.
		edit := win.Menu("Edit")
		edit.Item("Undo").Role(kaya.RoleUndo)
		edit.Item("Redo").Role(kaya.RoleRedo)
		edit.Separator()
		edit.Item("Cut").Role(kaya.RoleCut)
		edit.Item("Copy").Role(kaya.RoleCopy)
		edit.Item("Paste").Role(kaya.RolePaste)
		edit.Separator()
		// Find… is the app's, because the find BAR is (docs/ranges-plan.md
		// §3). What it cannot do is put the cursor in the query field:
		// NOTHING CAN FOCUS A STAMPED COPY (docs/undo-plan.md:706), which
		// is why the bar carries a `done` button — Escape is not a chord
		// an app may claim.
		//
		// AND FIND IS THE SECOND PRIMARY: preorder walks File before Edit
		// and Save before Find…. THE ELLIPSIS RIDES ALONG, because the
		// promoted button IS this item.
		edit.Item("Find…").Symbol(kaya.SymbolSearch).Primary(true).
			Shortcut("primary+f").OnActivate(func(tx *kaya.Tx) {
			if open {
				return
			}
			open = true
			tx.Insert(findRows, findKey, "")
			refind(tx)
		})

		// ---- the surface ---------------------------------------------
		//
		// Sublime-shaped: one buffer filling the window and one status
		// line at the bottom. No tabs and no panes, and NO FIND BAR until
		// Edit>Find… asks for one. STRETCH IS THE OTHER HALF OF "IT FILLS
		// THE WINDOW": grow divides the MAIN axis and align owns the cross
		// one, so a full-window buffer needs both.
		tx.Mount(tx.Column(func() {
			buffer = tx.Textarea(func(tx *kaya.Tx, s string) {
				// THE FOLD. Every user edit arrives here — keystrokes, the
				// platform's own paste, a native undo — and this is the
				// app's only copy of the document.
				text = s
				mark(tx)
				refind(tx)
			}).Grow(1).A11yID("buffer").A11yLabel("Document") // textarea#0

			// THE FIND BAR, DECLARED AND NOT MOUNTED. Conditional display
			// in kaya is STAMPING: these four controls do not exist while
			// the collection is empty. There is no visibility property and
			// no way to take a live widget out of a tree, so "shown and
			// hidden" (docs/editor-plan.md E1) means built and torn down.
			//
			// SetInset on the STAMPED row is what lets the bar keep its
			// margin under a full-bleed window.
			findRows = tx.Collection()
			for row := range tx.Rows(findRows).All() {
				bar := row.Row(func() {
					query = row.Entry() // entry#0
					prev = row.Button("prev")          // button#0
					next = row.Button("next")          // button#1
					// DISMISS IS AN AFFORDANCE, because it cannot be a
					// keystroke: kaya's shortcut floor reserves no bare
					// Escape and an app cannot claim one.
					done = row.Button("done") // button#2
				})
				row.SetInset(bar, 8)
			}

			// ONE STATUS LINE, carrying NO FILE NAME. The TITLE BAR says
			// which document this is; the status line says what just
			// HAPPENED and what the search found.
			//
			// INSET 8 ON THE CHROME, NOT ON THE WINDOW: the window's
			// Inset(0) above is the buffer's full bleed and it took this
			// row's margin with it, so the status text sat flush on the
			// window edge (maintainer, 2026-08-12).
			tx.Row(func() {
				tx.Label(status).Grow(1).A11yID("status") // label#0
				tx.Label(count).A11yID("matches")         // label#1
			}).Inset(8)
		}).Align(kaya.AlignStretch))

		// AN EDITOR OPENS WITH THE CURSOR IN THE DOCUMENT, and it is the
		// routing question the Edit menu turns on.
		tx.Focus(buffer)
	})

	// ---- the find bar's handlers ---------------------------------------
	//
	// REGISTERED AGAINST THE TEMPLATE NODE, once, for every copy that will
	// ever be stamped: a live-zone func(*Tx) has nowhere to put the copy's
	// identity.
	app.OnChangeNode(query, func(tx *kaya.Tx, _ []any, s string) {
		pattern = s
		refind(tx)
		// FIND AS YOU TYPE parks on the first match, the one place the
		// selection may move without a person asking.
		show(tx, 0)
	})
	app.OnClickNode(prev, func(tx *kaya.Tx, _ []any) { show(tx, at-1) })
	app.OnClickNode(next, func(tx *kaya.Tx, _ []any) { show(tx, at+1) })

	// DISMISS TEARS THE BAR DOWN — it is not hidden, it stops existing.
	// Nothing here clears the query FIELD, so a field that reads empty
	// after the next Find… is a NEW field.
	app.OnClickNode(done, func(tx *kaya.Tx, _ []any) {
		open = false
		pattern = ""
		tx.Remove(findRows, findKey)
		refind(tx)
		tx.Focus(buffer)
	})

	return app
}
