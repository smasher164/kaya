// THE TEXT EDITOR, kaya's forcing artifact (tools/scenes/editor.steps). It
// works around a refused live-zone When (docs/traps.md: A live-zone `When`
// stamps an EMPTY key path) and a refused close.
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

// sceneRoot is not temp everywhere: neither phone's picker can see an app's
// private storage. kaya.Env, never os.Getenv (tools/check-go-env.py).
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

// The script names this the same way ($TMP/kaya-editor-$PID).
func workingDir() string {
	return filepath.Join(sceneRoot(), "kaya-editor-"+strconv.Itoa(os.Getpid()))
}

// TALL ON PURPOSE: on a document that fits, reveal_range has nothing to
// move. A newline after the backtick would shift every offset in the script.
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

// readDoc reads a picked file whole.
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

// writeDoc answers with what the FILE says afterwards. FileModeWrite
// truncates, and the create is the core's (docs/save-plan.md D1).
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

const untitled = "untitled"

// THE PICKER'S NAME IS ALREADY A BASENAME, so no filepath.Base here: on
// Android that would call a display name a path.
func docName(dest *kaya.PickedFile) string {
	if dest == nil {
		return untitled
	}
	return dest.Name
}

const findKey = "bar"

// Spelled rather than formatted: "1 matches" is what a person reads.
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

	// The decoy sorts first: a picker with ONE file completes with it having
	// selected nothing (docs/traps.md).
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

	text := ""
	saved := ""
	var dest *kaya.PickedFile

	// The app's own copy: a signal is written and never read back.
	pattern := ""
	var hits []kaya.TextRange
	at := 0
	open := false

	var (
		buffer        kaya.Widget
		status, count kaya.Signal[string]
		// A WORKAROUND — docs/traps.md, "A live-zone `When` stamps an EMPTY
		// key path".
		findRows kaya.Collection
		// TEMPLATE NODES, not widgets: their handlers register below Build.
		query, prev, next, done kaya.Node
	)

	mark := func(tx *kaya.Tx) { tx.Window(0).Dirty(text != saved) }

	// A declared set dies on the next edit (docs/ranges-plan.md D2).
	// HIGHLIGHTS ONLY: this runs while somebody is typing.
	refind := func(tx *kaya.Tx) {
		hits = nil
		at = 0
		// LIVE zone: a stamped copy has no id select_range can aim at.
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
		// A half-typed pattern is ordinary here: a compile error is a state.
		re, err := regexp.Compile(pattern)
		if err != nil {
			tx.HighlightRanges(buffer, nil)
			tx.Write(count, "bad pattern")
			return
		}
		// GO STRING INDICES, unconverted: a UTF-16 backend converts its side.
		for _, m := range re.FindAllStringIndex(text, -1) {
			// AN EMPTY MATCH DECORATES NOTHING.
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

	// The ONLY place the destination moves, and always from a posted
	// transaction, so it needs no lock.
	retarget := func(tx *kaya.Tx, file *kaya.PickedFile, body string) {
		dest = file
		saved = body
		tx.Window(0).Title(docName(dest))
	}

	// saveTo writes off the app goroutine: PickedFile.Open BLOCKS.
	saveTo := func(file kaya.PickedFile, body string) {
		go func() {
			n, err := writeDoc(file, body)
			app.Post(func(tx *kaya.Tx) {
				if err != nil {
					tx.Write(status, "save failed: "+err.Error())
					return
				}
				// body AND NOT text: the user may have typed since.
				retarget(tx, &file, body)
				// The byte count is READ BACK OFF THE DISK.
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
				// A PROGRAMMATIC WRITE does not echo, so the fold is by hand;
				// it also spends the field's native undo history.
				tx.SetText(buffer, body)
				tx.Focus(buffer)
				tx.Write(status, fmt.Sprintf("opened, %d bytes", len(body)))
				mark(tx)
				refind(tx)
			})
		}()
	}

	app.Build(func(tx *kaya.Tx) {
		// Before anything mounts (the set-once wall); a REQUEST, not a rule.
		tx.BrandAccent(0x0F7B6C)
		// docName from the first frame, so one expression names this window
		// everywhere. Inset 0 leaves a phone's safe area alone.
		win := tx.Window(0).Title(docName(dest)).Size(640, 420).Inset(0).VetoClose(true)

		status = tx.Signal("new file")
		count = tx.Signal("")

		newDoc := func(tx *kaya.Tx) {
			text = ""
			retarget(tx, nil, "")
			tx.SetText(buffer, "")
			tx.Focus(buffer)
			tx.Write(status, "new file")
			mark(tx)
			refind(tx)
		}

		// NO FILTER: the scene's documents have no extensions to match.
		openDoc := func(tx *kaya.Tx) {
			tx.PickFile().OnResult(func(tx *kaya.Tx, files []kaya.PickedFile) {
				if len(files) == 0 {
					tx.Write(status, "open cancelled")
					return
				}
				openFrom(files[0])
			}).Show()
		}

		// The panel OPENS with the name the window is already showing.
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

		// No dialog: the handle the user chose the file with is writable.
		save := func(tx *kaya.Tx) {
			if dest == nil {
				saveAs(tx)
				return
			}
			saveTo(*dest, text)
		}

		// A COMPOSITION: kaya has no "confirm before you discard".
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

		// The ONE call that leaves the framework — docs/traps.md, "An app can
		// VETO a close but cannot AGREE to one".
		quit := func(_ *kaya.Tx) { os.Exit(0) }

		win.OnCloseRequested(func(tx *kaya.Tx) { ask(tx, quit) })

		file := win.Menu("File")
		file.Item("New").Shortcut("primary+n").OnActivate(func(tx *kaya.Tx) {
			ask(tx, newDoc)
		})
		file.Item("Open…").Shortcut("primary+o").OnActivate(func(tx *kaya.Tx) {
			ask(tx, openDoc)
		})
		// The host promotes the first k primaries in catalog preorder;
		// SymbolDone is the save idiom, the set has no save glyph.
		file.Item("Save").Symbol(kaya.SymbolDone).Primary(true).
			Shortcut("primary+s").OnActivate(save)
		file.Item("Save As…").Shortcut("primary+shift+s").OnActivate(saveAs)

		// NO SHORTCUTS ON A ROLE: it carries the platform's own chord.
		edit := win.Menu("Edit")
		edit.Item("Undo").Role(kaya.RoleUndo)
		edit.Item("Redo").Role(kaya.RoleRedo)
		edit.Separator()
		edit.Item("Cut").Role(kaya.RoleCut)
		edit.Item("Copy").Role(kaya.RoleCopy)
		edit.Item("Paste").Role(kaya.RolePaste)
		edit.Separator()
		// NOTHING CAN FOCUS A STAMPED COPY (docs/undo-plan.md:706), which is
		// why the bar carries a `done` button.
		edit.Item("Find…").Symbol(kaya.SymbolSearch).Primary(true).
			Shortcut("primary+f").OnActivate(func(tx *kaya.Tx) {
			if open {
				return
			}
			open = true
			tx.Insert(findRows, findKey, "")
			refind(tx)
		})

		// grow divides the MAIN axis and align owns the cross one: a
		// full-window buffer needs both.
		tx.Mount(tx.Column(func() {
			buffer = tx.Textarea(func(tx *kaya.Tx, s string) {
				// Every user edit arrives here, a native undo included.
				text = s
				mark(tx)
				refind(tx)
			}).Grow(1).A11yID("buffer").A11yLabel("Document") // textarea#0

			// There is no visibility property: "shown and hidden" means
			// stamped and torn down. SetInset rides the STAMPED row.
			findRows = tx.Collection()
			for row := range tx.Rows(findRows).All() {
				bar := row.Row(func() {
					query = row.Entry() // entry#0
					prev = row.Button("prev")          // button#0
					next = row.Button("next")          // button#1
					// Dismiss cannot be a keystroke: no bare Escape exists.
					done = row.Button("done") // button#2
				})
				row.SetInset(bar, 8)
			}

			// INSET ON THE CHROME, NOT THE WINDOW: Inset(0) above takes this
			// row's margin with it (docs/deferred.md, the inset entry).
			tx.Row(func() {
				tx.Label(status).Grow(1).A11yID("status") // label#0
				tx.Label(count).A11yID("matches")         // label#1
			}).Inset(8)
		}).Align(kaya.AlignStretch))

		tx.Focus(buffer)
	})

	// REGISTERED AGAINST THE TEMPLATE NODE, once, for every copy ever
	// stamped.
	app.OnChangeNode(query, func(tx *kaya.Tx, _ []any, s string) {
		pattern = s
		refind(tx)
		// The one place the selection moves without a person asking.
		show(tx, 0)
	})
	app.OnClickNode(prev, func(tx *kaya.Tx, _ []any) { show(tx, at-1) })
	app.OnClickNode(next, func(tx *kaya.Tx, _ []any) { show(tx, at+1) })

	// Dismiss TEARS THE BAR DOWN; nothing clears the query field, so the
	// next Find… stamps a NEW one.
	app.OnClickNode(done, func(tx *kaya.Tx, _ []any) {
		open = false
		pattern = ""
		tx.Remove(findRows, findKey)
		refind(tx)
		tx.Focus(buffer)
	})

	return app
}
