// THE TEXT EDITOR — kaya's forcing artifact (docs/editor-plan.md).
//
// It is written in Go, and that is the point of it: an editor in Rust
// would be kaya testing itself, and every awkward corner of a BINDING
// would stay invisible. Everything below is the sugar tier — the same
// tier the examples use — so what this file has to spell out is what an
// app actually has to spell out.
//
// WHAT THE APP OWNS, AND WHAT IT DOES NOT.
//
//   - The TEXT is the app's (the uncontrolled contract). kaya never
//     reads it back; the textarea reports every edit through its change
//     handler and this file folds it into `text`. Opening a file is one
//     programmatic write, which does NOT echo, so the fold is done by
//     hand right there — the one place the two paths differ.
//   - The DOCUMENT'S NAME IS THE WINDOW'S TITLE and lives nowhere else.
//     `tx.Window(0).Title(...)` is rewritten every time the destination
//     moves, which is what a title bar is FOR; the status line at the
//     bottom carries only what has just happened, and repeats no name.
//   - The DIRTY MARK is one declaration, `text != saved`, made on the
//     window. kaya does not watch signals and guess: "this document has
//     unsaved changes" is a sentence only the app can say. It rides the
//     `dirty` prop and NEVER the title string: a marker composed into
//     the app's own title is the design docs/dirty-plan.md D1 rejected
//     by name (Qt's `[*]`), because kaya's titles are byte-compared
//     across five platforms while the chrome diverges. So this file
//     writes the file's name and nothing else, and the dot, the
//     asterisk and the bullet are each backend's own business.
//   - CLOSE CONFIRMATION is composed, not built in: veto_close says the
//     window's close is the app's to answer, close_requested is the
//     question, and the alert machinery is the answer. The dirty
//     milestone deliberately did not fuse those three, and this is the
//     app that shows why it did not have to.
//   - FIND is entirely the app's: Go's regexp over the app's own string,
//     and the byte offsets it returns ARE kaya's ranges, with no
//     conversion anywhere in this file. kaya ships no search engine, no
//     find bar and no dialect (docs/ranges-plan.md §3) — it ships the
//     three things no app can write for itself: colouring runs of a
//     native text view, moving its selection, scrolling it into view.
//   - CUT, COPY, PASTE, UNDO and REDO are declared and nothing else. Six
//     lines below name them as ROLES; they lower to each platform's own
//     command, act on whatever holds focus, and work out their own
//     enablement. That is the forcing artifact's real finding: the Edit
//     menu costs six lines and no handlers.
//
// WHERE THE FRAMEWORK MADE THIS FILE BEND — recorded here rather than
// buried, because the plan asks for exactly that:
//
//  1. A HIDDEN CONTROL CANNOT BE FOCUSED, so Edit>Find… summons the
//     find bar and cannot put the cursor in it. kaya has no visibility
//     property (spec.rs's `prop` enum is text/checked/value/min/max/
//     source/grow/spacing/align/indeterminate/columns + the three a11y
//     props + accepts) and the guest wire has no remove_child and no
//     destroy_widget, so a LIVE subtree can neither be hidden nor taken
//     out of the tree. Conditional display is STAMPING and nothing else,
//     and a stamped copy's identity is (template node, key path), while
//     `widget_command` — the record carrying `focus` — is addressed at a
//     live WIDGET ID. So there is nothing to aim it at.
//     tools/scenes/undo.steps ratified that sentence for a collection
//     row's field ("nothing can FOCUS a stamped copy"); this is the same
//     constraint met by an APP, where it costs a keystroke every editor
//     has. The bar carries a `done` button for the same reason: Escape
//     is not a shortcut an app may claim.
//  1b. AND THE BAR IS A COLLECTION OF ONE ROW RATHER THAN A `When`,
//     which is a workaround for a DEFECT and not a style. A When over a
//     bool signal is the natural spelling and it silently misroutes
//     every occurrence its body produces: a live-zone When stamps with
//     an EMPTY key path, and the wire says an empty path means "id is a
//     widget id" (spec.rs's button_clicked doc; wire.rs
//     decode_click_tag), so the copy's TEMPLATE NODE id is read as a
//     WIDGET id in a space that also starts at 1. Measured 2026-08-10
//     with this app: typing in a When-stamped find field arrived at the
//     TEXTAREA's change handler — node 2, widget 2 — and the document
//     went dirty with text nobody typed into it; the three buttons
//     landed on widgets with no click handler and vanished. A For's
//     copies carry their key, so the same occurrence decodes as the
//     instance it is. Nothing caught this in four milestones because
//     the only When any guest declares (guests/go/milestone2) holds a
//     static label.
//  2. NEW AND OPEN CONFIRM, AND SO DOES CLOSE, out of three separate
//     compositions of the same four calls. Nothing in kaya says "ask
//     before you discard": each entry point shows its own alert and
//     hangs its own continuation off the answer. That is the right
//     layering — but the app carries the pattern three times, and a
//     fourth entry point would carry it again.
//  3. AND THE APP CANNOT SAY YES. `veto_close` makes the close the
//     app's to answer and there is no verb for the affirmative:
//     `destroy_window(0)` is refused by assertion, so the arm that
//     agrees to close ABORTS. `quit` below is where that is spelled out
//     and worked around with os.Exit — the one call in this file that
//     leaves the framework.
//
// Byte-frozen contract: tools/scenes/editor.steps.
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

// sceneRoot is the directory the picker and the app can BOTH see, which
// is not the temp directory everywhere: an Android provider cannot see
// an app's private storage and iOS's picker cannot see its container,
// so each phone names the place its own file browser looks. The
// desktops just use temp — os.TempDir is Go's OWN answer to "where is
// temp", which is what lets app and interpreter agree on a path with
// neither consulting the other.
//
// A runtime switch rather than per-platform files, because runtime.GOOS
// is a compile-time constant in Go: the dead arms fold away, and — the
// point — every arm is compiled and vetted on the mac lane instead of
// only on the platform that selects it.
//
// kaya.Env AND NOT os.Getenv, which is the one spelling nothing catches
// at compile time: a c-shared library loaded by System.loadLibrary never
// sees an envp, so Go's view of the environment is EMPTY on Android
// forever while C's getenv reads the live one (bindings/go/runtime.go,
// tools/check-go-env.sh).
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
// way ($TMP/kaya-editor-$PID) because app and interpreter are one
// process.
func workingDir() string {
	return filepath.Join(sceneRoot(), "kaya-editor-"+strconv.Itoa(os.Getpid()))
}

// notesDoc is the document the scene opens: 59 short lines with exactly
// three numeric tokens, one near the top, one in the middle and one on
// the last line.
//
// TALL ON PURPOSE. `reveal_range` moves a viewport, and on a document
// that fits there is nothing to move — containment is already true and
// the assertion passes vacuously. The last token sits far below any
// window this app opens, so revealing it is a real scroll.
//
// A RAW STRING LITERAL, so the newlines are exactly the bytes Go's
// compiler read out of this file. The opening backtick is followed
// immediately by `top 7` — a newline there would be a byte of document,
// and every offset in the scene script would move.
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
// never what the app hoped: a write that returned nil and landed
// nowhere is exactly the failure "save" has, and only reopening can see
// it.
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
// the FILE says afterwards — reopened and counted, never the length the
// app just handed over.
//
// FileModeWrite truncates, on a file the user picked and on a save
// destination alike; the destination only adds the create, because a
// desktop save panel answers with a name for a file nobody has made
// (docs/save-plan.md D1).
func writeDoc(file kaya.PickedFile, body string) (int, error) {
	f, _, err := file.Open(kaya.FileModeWrite)
	if err != nil {
		return 0, err
	}
	if _, err := f.Write([]byte(body)); err != nil {
		f.Close()
		return 0, err
	}
	// CLOSED BEFORE THE REOPEN, so what comes back is the file's and not
	// a buffer's.
	if err := f.Close(); err != nil {
		return 0, err
	}
	back, err := readDoc(file)
	if err != nil {
		return 0, err
	}
	return len(back), nil
}

// untitled is what an editor calls a buffer that has no destination yet
// — Sublime's word, and TextEdit's, and gedit's. A window needs a name
// before the document has one, and inventing a different one here would
// only be a name nobody recognizes.
const untitled = "untitled"

// docName is the window's name: the destination's own name, or the
// no-destination convention above.
//
// THE PICKER'S NAME IS ALREADY A BASENAME on every platform — macOS's
// lastPathComponent, GTK's basename, the Windows dialog's file name, an
// Android content URI's display name — and tools/scenes/editor.steps
// pins that byte-for-byte on five lanes: the window reads `draft` and
// `notes`, never a path. So there is no filepath.Base call here.
// Adding one would claim a display name is a path, which on Android it
// is not, and would be a conversion this app could never observe going
// wrong.
//
// IT TAKES THE DESTINATION rather than reading the closure's, so it can
// serve the window's construction — where there is provably none — and
// the save panel's suggested name from the one spelling.
func docName(dest *kaya.PickedFile) string {
	if dest == nil {
		return untitled
	}
	return dest.Name
}

// findKey names the find bar's one row. A collection is how this app
// spells "at most one of these" (see the note beside findRows), so the
// key is a constant and the only question ever asked of it is whether
// it is in there.
const findKey = "bar"

// tally is what the find bar says about a set it has not walked yet.
// Spelled rather than formatted, because "1 matches" is what a person
// reads when an app formats it.
func tally(n int) string {
	switch n {
	case 0:
		return "no matches"
	case 1:
		return "1 match"
	}
	return fmt.Sprintf("%d matches", n)
}

// App builds the editor and hands it back ready to be served (the Go
// guests' one entry package picks it out of guests/go/cmd/scenes.go).
//
// THE TAIL IS THE ONLY THING THAT DIFFERS BY PLATFORM, and it differs
// because the hosting does: a desktop or iOS guest owns the process
// main thread and lends it to kaya (guests/go/cmd/main_desktop.go),
// while on Android the OS owns main and kaya starts the guest on a
// thread of its own (guests/go/cmd/main_android.go).
func App() *kaya.App {
	app := kaya.NewApp()

	// The documents a person can open on a first run, written before
	// anything is shown. `decoy` is load-bearing in the scene rather
	// than decoration: with ONE file in a directory a picker completes
	// with it when nothing was selected, so the choose step would pass
	// on a backend that never selected anything. It sorts first, so
	// that backend gets the WRONG file and the byte assertions say so.
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

	// ---- the document ------------------------------------------------
	//
	// One buffer, one optional destination, and one comparison that
	// decides the dirty mark. `text` is the app's authority on what the
	// document says; `saved` is what the destination holds.
	text := ""
	saved := ""
	var dest *kaya.PickedFile

	// ---- find --------------------------------------------------------
	//
	// `open` mirrors the bool signal the find bar's When binds. The
	// SIGNAL is what the core stamps on; this is what the app's own arms
	// branch on, because a signal is written and never read back.
	pattern := ""
	var hits []kaya.TextRange
	at := 0
	open := false

	var (
		buffer        kaya.Widget
		status, count kaya.Signal[string]
		// THE FIND BAR IS A COLLECTION WITH EITHER NO ROWS OR ONE, and
		// that is a WORKAROUND with a measured reason. `When` is the
		// natural spelling — a bool signal, stamped on true — and it
		// cannot carry an interactive control: a live-zone When stamps
		// its copy with an EMPTY key path, the wire says an empty path
		// means "id is a widget id" (spec.rs's button_clicked doc, and
		// wire.rs decode_click_tag), and the copy's TEMPLATE NODE id is
		// then read as a WIDGET id in a different id space. Measured
		// 2026-08-10: typing in a When-stamped find field arrived at
		// this app's TEXTAREA handler — node 2 and widget 2 — and the
		// document went dirty with text nobody typed into it. A For's
		// copies carry their key, so the same occurrence decodes as the
		// instance it is.
		findRows kaya.Collection
		// The bar's widgets are TEMPLATE NODES, not widgets: it exists
		// only while it is on screen and every copy of it is stamped
		// fresh. Their handlers hang off the node (App.OnChangeNode /
		// App.OnClickNode) rather than off a widget, and are registered
		// once, below Build.
		query, prev, next, done kaya.Node
	)

	// mark is the whole of E2's dirty contract: one comparison, one
	// declaration. Called from every path that can move either side of
	// it, because neither implies the other and kaya watches nothing.
	mark := func(tx *kaya.Tx) { tx.Window(0).Dirty(text != saved) }

	// refind re-runs the search and RE-DECLARES the highlight set.
	//
	// A DECLARED SET IS BOUND TO THE TEXT IT WAS DECLARED AGAINST: any
	// edit drops it in the core and the app re-declares from its next
	// fold (docs/ranges-plan.md D2). Nothing in kaya adjusts a range
	// across an edit, and this app wants none: the offsets come back out
	// of a fresh search over the string it already holds.
	//
	// HIGHLIGHTS ONLY, never the selection. This runs on the buffer's
	// own change path — i.e. while somebody is typing — and moving the
	// selection there would move their caret out from under them.
	refind := func(tx *kaya.Tx) {
		hits = nil
		at = 0
		// THE TALLY IS THE BAR'S, and says nothing while the bar is
		// away. It is the one part of find that stays in the live zone —
		// a label the status line carries — because a stamped copy has
		// no id an app can aim `select_range` or `reveal_range` at, and
		// because the scene needs one reading of find state whose index
		// does not move when the bar is torn down and stamped again.
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
		// THE DIALECT IS GO'S, and that is the ratified line: ordinary
		// regular expressions, no backreferences and no lookaround,
		// because the engine is the APP's and Go's regexp is exactly
		// that language. A half-typed pattern is the ordinary case here
		// — find-as-you-type sees `[`, `[0`, `[0-` before it sees
		// `[0-9]+` — so a compile error is a state, not an incident.
		re, err := regexp.Compile(pattern)
		if err != nil {
			tx.HighlightRanges(buffer, nil)
			tx.Write(count, "bad pattern")
			return
		}
		// THE OFFSETS ARE GO STRING INDICES AND NOTHING CONVERTS THEM.
		// FindAllStringIndex answers in bytes into the app's own string,
		// which is exactly what kaya.TextRange holds and exactly what
		// the wire carries; a backend that counts UTF-16 converts on its
		// own side, where it has the text to do it against.
		for _, m := range re.FindAllStringIndex(text, -1) {
			// AN EMPTY MATCH DECORATES NOTHING. `a*` matches at every
			// position; a zero-width range is a caret rather than a
			// span, so the find bar drops them instead of highlighting
			// the whole document invisibly. An app decision, not a
			// framework one.
			if m[0] == m[1] {
				continue
			}
			hits = append(hits, kaya.TextRange{Start: m[0], End: m[1]})
		}
		tx.HighlightRanges(buffer, hits)
		tx.Write(count, tally(len(hits)))
	}

	// show walks to a match: the selection goes there and the viewport
	// follows. Wraps in both directions, which is what the buttons are
	// for and what every editor does.
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

	// retarget takes a destination and the bytes that are now in it —
	// and it is the ONLY place the destination moves, which is why the
	// title is written here rather than at the three call sites. "The
	// window is called after the file" is then a property of the
	// assignment instead of a rule three handlers have to remember, and
	// a fourth entry point cannot forget it.
	//
	// A nil destination is New's answer and gets the same treatment: the
	// buffer belongs to no file, so the window says so.
	//
	// Only ever called from inside a posted transaction, i.e. on the app
	// goroutine, so touching the app's own state here needs no lock.
	retarget := func(tx *kaya.Tx, file *kaya.PickedFile, body string) {
		dest = file
		saved = body
		tx.Window(0).Title(docName(dest))
	}

	// saveTo writes off the app goroutine, which is what PickedFile.Open
	// tells every caller to do: it BLOCKS, and a cloud provider may
	// upload the whole file first. An app that did this inline would
	// freeze its own window on every Cmd+S.
	saveTo := func(file kaya.PickedFile, body string) {
		go func() {
			n, err := writeDoc(file, body)
			app.Post(func(tx *kaya.Tx) {
				if err != nil {
					tx.Write(status, "save failed: "+err.Error())
					return
				}
				// `body` AND NOT `text`: the user may have typed while
				// the write was in flight, and what is on disk is what
				// was handed to the write. Comparing against the live
				// text would clear the mark on changes that never
				// reached the file.
				retarget(tx, &file, body)
				// NO FILE NAME HERE. The title bar has just been given
				// it, and a status line that repeated it would be the
				// arrangement the maintainer asked to be rid of. What
				// is left is the one thing the title cannot say: the
				// byte count, READ BACK OFF THE DISK.
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
				// A PROGRAMMATIC WRITE, which does not echo — so the
				// fold above is done by hand. It also spends the field's
				// native undo history and drops whatever ranges were
				// declared, both of which are what "this is a different
				// document now" should mean.
				tx.SetText(buffer, body)
				tx.Focus(buffer)
				tx.Write(status, fmt.Sprintf("opened, %d bytes", len(body)))
				mark(tx)
				refind(tx)
			})
		}()
	}

	app.Build(func(tx *kaya.Tx) {
		// VETO_CLOSE says this window's close is the app's to answer;
		// nothing else about it is armed. An editor owns its close so it
		// can ask.
		//
		// AND THE TITLE IS THE DOCUMENT'S NAME, from the first frame —
		// `docName(dest)` and not the literal, even though `dest` is
		// provably nil here. One expression names this window in all
		// four places it can be named, so a future "reopen the last
		// document at launch" would be titled right for free.
		win := tx.Window(0).Title(docName(dest)).Size(640, 420).VetoClose(true)

		status = tx.Signal("new file")
		// EMPTY, because the bar is not up. The editor opens on a buffer
		// and a status line and nothing else, so the tally has nothing
		// to say — "no matches" on a screen with no search field is an
		// answer to a question nobody asked.
		count = tx.Signal("")

		// ---- the actions the menus name ------------------------------

		newDoc := func(tx *kaya.Tx) {
			text = ""
			// THE DESTINATION IS DROPPED, and dropping it renames the
			// window back — the third of the three ways a destination
			// can move, and the only one with no dialog to announce it.
			retarget(tx, nil, "")
			tx.SetText(buffer, "")
			tx.Focus(buffer)
			tx.Write(status, "new file")
			mark(tx)
			refind(tx)
		}

		// openDoc shows the picker. NO FILTER, deliberately: the scene's
		// documents have no extensions (a save panel hides a known
		// extension when the user's Finder preference says so, which
		// would make one assertion read the stem on one machine and the
		// whole name on another), and a filter would hide them.
		openDoc := func(tx *kaya.Tx) {
			tx.PickFile().OnResult(func(tx *kaya.Tx, files []kaya.PickedFile) {
				if len(files) == 0 {
					// THE EMPTY LIST IS CANCEL. Nothing was chosen, so
					// nothing is opened and the document is untouched.
					tx.Write(status, "open cancelled")
					return
				}
				openFrom(files[0])
			}).Show()
		}

		// saveAs names a destination first. The panel OPENS with the
		// name the window is already showing — "untitled" for a buffer
		// that has none — which a person types over, the whole point of
		// a save dialog. One spelling for both, so the title bar and
		// the panel can never disagree about what this document is
		// called.
		saveAs := func(tx *kaya.Tx) {
			suggested := docName(dest)
			body := text
			tx.SaveFile(suggested).OnResult(func(tx *kaya.Tx, file *kaya.PickedFile) {
				if file == nil {
					// CANCEL IS NIL. Nothing was named, so nothing is
					// written and no destination is remembered.
					tx.Write(status, "save cancelled")
					return
				}
				saveTo(*file, body)
			}).Show()
		}

		// save needs no dialog once there is a destination: the user
		// already chose this file and the handle they chose it with is
		// writable.
		save := func(tx *kaya.Tx) {
			if dest == nil {
				saveAs(tx)
				return
			}
			saveTo(*dest, text)
		}

		// ask is the unsaved-work guard, and it is a COMPOSITION rather
		// than a feature: kaya has no "confirm before you discard". A
		// clean document runs the action straight away; a dirty one gets
		// the alert, and the answer decides. The continuation is a
		// closure per call site, which is what keeps three entry points
		// from needing one app-global handler that has to work out which
		// of them asked.
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

		// quit is the answer to "yes, close it" — and it is the ONE place
		// this app has to reach outside kaya, which makes it the sharpest
		// thing the forcing artifact found.
		//
		// `veto_close` says the window's close is the app's to ANSWER and
		// `close_requested` asks the question, but there is no verb for
		// the affirmative. `destroy_window(0)` is the obvious candidate
		// and the core refuses it by assertion — "the primary window is
		// not destroyable — the process owns it"
		// (crates/kaya/src/scene.rs) — so an app that takes that arm
		// ABORTS instead of closing. Measured here, not reasoned about:
		// a perturbed run reached it and died with that panic and
		// `fatal runtime error: failed to initiate panic, error 5`.
		// guests/rust/dirty.rs and its eight ports carry exactly that
		// call in exactly this arm; no scene has ever taken it, so
		// nothing has ever run it.
		//
		// And the platform's own quit chord is reserved AWAY from apps —
		// the shortcut floor refuses `primary+q` — so kaya deliberately
		// leaves Cmd+Q to the host, where this guard cannot see it. The
		// close button is the only door an unsaved-work warning can
		// watch, which makes being unable to answer it the whole problem
		// rather than a corner of one.
		//
		// So the app exits its own process. Abrupt by construction —
		// nothing gets to tear down — and desktop-shaped: the phones have
		// no close affordance, so this arm is unreachable there, which is
		// as well, since an app does not exit itself on either of them.
		quit := func(_ *kaya.Tx) { os.Exit(0) }

		// The close handler binds to THE WINDOW at its declaration
		// (handlers scope to the thing that creates them): it can only
		// ever mean this surface's close was asked for. Nothing has
		// closed yet — that is what the veto class buys — so the app is
		// free to ask, and to do nothing if the answer is no.
		win.OnCloseRequested(func(tx *kaya.Tx) { ask(tx, quit) })

		// ---- the menu bar --------------------------------------------
		//
		// File is the app's own vocabulary: four items, four handlers,
		// and the shortcuts every platform's users already have in their
		// fingers.
		file := win.Menu("File")
		file.Item("New").Shortcut("primary+n").OnActivate(func(tx *kaya.Tx) {
			ask(tx, newDoc)
		})
		file.Item("Open…").Shortcut("primary+o").OnActivate(func(tx *kaya.Tx) {
			ask(tx, openDoc)
		})
		file.Item("Save").Shortcut("primary+s").OnActivate(save)
		file.Item("Save As…").Shortcut("primary+shift+s").OnActivate(saveAs)

		// AND EDIT IS SIX DECLARATIONS AND ONE HANDLER. Five of these
		// are ROLES: they lower to the platform's own command, act on
		// whatever is focused, and work out their own enablement from
		// what is focused and what the ledgers hold. The editor authors
		// no undo stack, no clipboard code and no selection API — which
		// is the forcing artifact's most useful result, since it is the
		// part every framework gets wrong.
		//
		// NO SHORTCUTS ON THE ROLES, and that is not an omission: a role
		// carries the platform's own chord (Cmd+Z, Ctrl+Z, Cmd+X…), and
		// an app that spelled one would be overriding the host's
		// convention with a guess.
		edit := win.Menu("Edit")
		edit.Item("Undo").Role(kaya.RoleUndo)
		edit.Item("Redo").Role(kaya.RoleRedo)
		edit.Separator()
		edit.Item("Cut").Role(kaya.RoleCut)
		edit.Item("Copy").Role(kaya.RoleCopy)
		edit.Item("Paste").Role(kaya.RolePaste)
		edit.Separator()
		// Find… is the app's, because the find BAR is (docs/ranges-plan
		// §3): it SUMMONS the bar, which is not mounted until somebody
		// asks for it. What it cannot do is put the cursor in the query
		// field — see the note at the top of this file: the bar is a
		// When body, its widgets are stamped copies, and `focus` is a
		// command aimed at a live widget id.
		edit.Item("Find…").Shortcut("primary+f").OnActivate(func(tx *kaya.Tx) {
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
		// line at the bottom. No tabs and no panes (ratified
		// 2026-08-10), and NO FIND BAR until Edit>Find… asks for one.
		//
		// STRETCH IS THE OTHER HALF OF "IT FILLS THE WINDOW". `grow`
		// divides the MAIN axis and `align` owns the cross one, on every
		// backend; a column's default alignment gives the textarea its
		// natural 240pt width, so a full-window buffer needs both — the
		// weight for the height, the alignment for the width.
		tx.Mount(tx.Column(func() {
			// THE BUFFER TAKES THE LEFTOVER, which is the whole of "it
			// fills the window": the bar and the status line are at
			// natural size and one grower eats the rest.
			buffer = tx.Textarea(func(tx *kaya.Tx, s string) {
				// THE FOLD. Every user edit arrives here — keystrokes,
				// the platform's own paste, a native undo — and this is
				// the app's only copy of the document.
				text = s
				mark(tx)
				refind(tx)
			}).Grow(1).A11yID("buffer").A11yLabel("Document") // textarea#0

			// THE FIND BAR, DECLARED AND NOT MOUNTED. Conditional
			// display in kaya is STAMPING: the four controls below do
			// not exist while the collection is empty — not drawn
			// transparent, not sized to nothing — and Edit>Find… builds
			// them by putting a row in it. There is no visibility
			// property and no way to take a live widget out of a tree,
			// so this is the whole vocabulary, and "shown and hidden"
			// (docs/editor-plan.md E1) means built and torn down.
			//
			// A BLUEPRINT TAKES NO PROPS in the Go template tier — no
			// grow, no align, no a11y ids — so the field keeps its
			// natural width and the buttons sit beside it. That is a
			// binding-surface gap rather than a protocol one (the wire's
			// set_property is happy to name a node), recorded here and
			// not worked around.
			findRows = tx.Collection()
			for row := range findRows.Rows(tx) {
				row.Row(func() {
					query = row.Widget(kaya.KindEntry) // entry#0
					prev = row.Button("prev")          // button#0
					next = row.Button("next")          // button#1
					// DISMISS IS AN AFFORDANCE, because it cannot be a
					// keystroke: kaya's shortcut floor reserves no bare
					// Escape and an app cannot claim one, so the bar
					// carries the door it is closed by.
					done = row.Button("done") // button#2
				})
			}

			// ONE STATUS LINE, which is what Sublime has too — and it
			// carries NO FILE NAME. That is the division: the TITLE
			// BAR says which document this is, because identity is
			// persistent and every platform already draws a place for
			// it; the status line says what just HAPPENED and what the
			// search found, because both are transient and have no
			// chrome of their own to live in. Nothing is spelled twice.
			//
			// WHAT IS LEFT IS NOT DECORATION. The left label's byte
			// counts are the app's proof that a write reached the disk
			// and came back — the one fact a title bar cannot carry —
			// and the right label's tally is the find bar's only
			// reading whose index does not move when the bar is torn
			// down and stamped again. Two labels in one row rather than
			// two rows: a second line of chrome is exactly what the
			// brief did not ask for.
			tx.Row(func() {
				tx.Label(status).Grow(1).A11yID("status") // label#0
				tx.Label(count).A11yID("matches")         // label#1
			})
		}).Align(kaya.AlignStretch))

		// AN EDITOR OPENS WITH THE CURSOR IN THE DOCUMENT. It is also
		// the routing question the Edit menu turns on: undo, cut and
		// paste all act on what is focused, so something has to be.
		tx.Focus(buffer)
	})

	// ---- the find bar's handlers ---------------------------------------
	//
	// REGISTERED AGAINST THE TEMPLATE NODE, once, for every copy that
	// will ever be stamped — a live-zone `func(*Tx)` has nowhere to put
	// the copy's identity, so the node-shaped registration is the only
	// one a blueprint can take. The key path is EMPTY here: a When in
	// the live zone stamps exactly one copy and there is no element to
	// name, where a collection row's would carry its keys.
	app.OnChangeNode(query, func(tx *kaya.Tx, _ []any, s string) {
		pattern = s
		refind(tx)
		// FIND AS YOU TYPE parks on the first match, which is the one
		// place the selection may move without a person asking: they are
		// looking at the find field, not at the caret.
		show(tx, 0)
	})
	app.OnClickNode(prev, func(tx *kaya.Tx, _ []any) { show(tx, at-1) })
	app.OnClickNode(next, func(tx *kaya.Tx, _ []any) { show(tx, at+1) })

	// DISMISS TEARS THE BAR DOWN — it is not hidden, it stops existing,
	// which is what `When(false)` means. The search goes with it: the
	// pattern is forgotten, the declared highlight set is dropped, the
	// tally goes quiet, and the cursor goes back where an editor keeps
	// it. Nothing here clears the query FIELD, so a field that reads
	// empty after the next Find… is a NEW field — the scene's proof
	// that the teardown happened.
	app.OnClickNode(done, func(tx *kaya.Tx, _ []any) {
		open = false
		pattern = ""
		tx.Remove(findRows, findKey)
		refind(tx)
		tx.Focus(buffer)
	})

	return app
}
