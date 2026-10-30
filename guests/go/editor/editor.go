// THE TEXT EDITOR, kaya's forcing artifact (tools/scenes/editor.steps), one
// tab per document (docs/doctabs-plan.md §5). It works around a refused
// live-zone When (docs/traps.md: A live-zone `When` stamps an EMPTY key path).
package editor

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"unicode/utf8"

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
// move. Its four numbers are the find's matches, and its last line takes
// the scene's typed " 99". A newline after the backtick would shift every
// offset in the script.
const notesDoc = `Walking the coast path

Day 3. Rain until noon, then a low
sun that turned the wet slate the
colour of pewter. We left the
harbour by the steps behind the
chapel and climbed until the
village was a handful of roofs.

The path keeps close to the edge
here: gorse on one side, the drop
on the other, and the sea working
at the rocks far below with a
sound like a slow engine.

Lunch in the lee of a field wall.
Bread, cheese, the last of the
apples. A kestrel held still over
the grass behind us for as long
as it took to eat, then slid away
downwind without a wingbeat.

The lighthouse by mid afternoon.
The keeper's daughter runs the
tours now. She counts 140 steps
to the lamp room and says she has
never once climbed them without
counting.

From the gallery you can see the
whole of the bay: the headland we
walked from, the long beach, and
the town at the far end, where
the lights were coming on.

Down again, and the last stretch
along the sand with the tide out
and the light going. Wet boots,
cold hands, a good tiredness.

Tomorrow the estuary, the ferry
if it is running, and the inn on
the far side that serves supper
until late.

Things to remember
- dry socks in the top of the pack
- the ferry stops at dusk
- fill the bottles at the chapel
- 12 plasters left

Miles walked so far:`

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

// The default face, a family each platform's code-only picker lists so Font…
// opens on it: Apple's `monospaced` face is SF Mono, which no picker lists
// (docs/font-picker-plan.md §6).
var codeFamilies = []string{"Menlo", "Cascadia Mono", "DejaVu Sans Mono", "Droid Sans Mono"}

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

// Where the caret is, as VS Code's status bar says it: "Ln 51, Col 1", with
// the selection's size in characters when there is one.
func position(text string, sel kaya.TextRange) string {
	end := min(max(sel.End, 0), len(text))
	start := min(max(sel.Start, 0), end)
	head := text[:end]
	at := fmt.Sprintf("Ln %d, Col %d", strings.Count(head, "\n")+1,
		utf8.RuneCountInString(head[strings.LastIndexByte(head, '\n')+1:])+1)
	if start < end {
		at += fmt.Sprintf(" (%d selected)", utf8.RuneCountInString(text[start:end]))
	}
	return at
}

// One open document: its buffer, find bar and status line, and the state
// they describe (docs/doctabs-plan.md §5).
type document struct {
	id          uint64
	n           int
	text, saved string
	dest        *kaya.PickedFile
	pattern     string
	hits        []kaya.TextRange
	at          int
	open        bool
	zoom        int
	numbers     bool
	sel         kaya.Selection
	buffer      kaya.Widget
	status      kaya.Signal[string]
	where       kaya.Signal[string]
	count       kaya.Signal[string]
	countTint   kaya.Signal[kaya.Tint]
	// A WORKAROUND — docs/traps.md, "A live-zone `When` stamps an EMPTY
	// key path".
	findRows kaya.Collection
}

func (d *document) dirty() bool { return d.text != d.saved }

// A tab Open… may take over rather than sit beside (VS Code's and TextEdit's
// rule): untitled, never saved, never typed in.
func (d *document) pristine() bool { return d.dest == nil && d.text == "" && d.saved == "" }

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

	var (
		docs   []*document
		active *document
		made   int
		// The View menu's state (docs/code-surface-plan.md §4), shown for the
		// active document.
		numbersOn kaya.Signal[bool]
		// The face every document wears, the app's preference, else the
		// first installed of codeFamilies (docs/font-picker-plan.md §6).
		font kaya.FontChoice
		// The Format menu's check marks: what holds over the active buffer's
		// selection (docs/phone-format-plan.md §3).
		inline = map[string]kaya.Signal[bool]{}
		styles = map[kaya.Block]kaya.Signal[bool]{}
	)

	// THE MARK IS THE DOCUMENT'S, and so is the veto: a clean tab just closes.
	mark := func(tx *kaya.Tx, d *document) {
		tx.Document(d.id).Dirty(d.dirty()).InterceptClose(d.dirty())
	}

	// A declared set dies on the next edit (docs/ranges-plan.md D2).
	// HIGHLIGHTS ONLY: this runs while somebody is typing.
	refind := func(tx *kaya.Tx, d *document) {
		d.hits = nil
		d.at = 0
		// LIVE zone: a stamped copy has no id select_range can aim at.
		tx.Write(d.countTint, kaya.TintNone)
		if !d.open {
			tx.HighlightRanges(d.buffer, nil)
			tx.Write(d.count, "")
			return
		}
		if d.pattern == "" {
			tx.HighlightRanges(d.buffer, nil)
			tx.Write(d.count, "no matches")
			return
		}
		// A half-typed pattern is ordinary here: a compile error is a state.
		re, err := regexp.Compile(d.pattern)
		if err != nil {
			tx.HighlightRanges(d.buffer, nil)
			tx.Write(d.count, "bad pattern")
			tx.Write(d.countTint, kaya.TintCritical)
			return
		}
		// GO STRING INDICES, unconverted: a UTF-16 backend converts its side.
		for _, m := range re.FindAllStringIndex(d.text, -1) {
			// AN EMPTY MATCH DECORATES NOTHING.
			if m[0] == m[1] {
				continue
			}
			d.hits = append(d.hits, kaya.TextRange{Start: m[0], End: m[1]})
		}
		tx.HighlightRanges(d.buffer, d.hits)
		tx.Write(d.count, tally(len(d.hits)))
		if len(d.hits) == 0 {
			tx.Write(d.countTint, kaya.TintCritical)
		}
	}

	show := func(tx *kaya.Tx, d *document, i int) {
		if len(d.hits) == 0 {
			return
		}
		n := len(d.hits)
		d.at = ((i % n) + n) % n
		tx.SelectRange(d.buffer, d.hits[d.at])
		tx.RevealRange(d.buffer, d.hits[d.at])
		tx.Write(d.count, fmt.Sprintf("%d of %d", d.at+1, n))
	}

	// The menus' check marks follow the active document (§5).
	marks := func(tx *kaya.Tx, d *document) {
		for name, on := range inline {
			tx.Write(on, d.sel.Has(name))
		}
		for kind, on := range styles {
			tx.Write(on, d.sel.Block() == kind)
		}
		tx.Write(numbersOn, d.numbers)
	}

	wear := func(tx *kaya.Tx, d *document) {
		if font.Family == "" {
			return
		}
		tx.SetFamily(d.buffer, font.Family)
		tx.SetFontWeight(d.buffer, font.Weight)
		tx.SetFontItalic(d.buffer, font.Italic)
		tx.SetFontWidth(d.buffer, font.Width)
	}

	activate := func(tx *kaya.Tx, d *document) {
		active = d
		marks(tx, d)
		tx.Focus(d.buffer)
	}

	// The ONLY place a destination moves, and always from a posted
	// transaction, so it needs no lock. The document's name is its tab's
	// title, and the window's while it is in front.
	retarget := func(tx *kaya.Tx, d *document, file *kaya.PickedFile, body string) {
		d.dest = file
		d.saved = body
		tx.Document(d.id).Title(docName(d.dest))
	}

	// The documents in the app's order; a closed one leaves, and the window
	// closes with the last of them (docs/doctabs-plan.md Q2).
	forget := func(tx *kaya.Tx, d *document) {
		at := -1
		for i, o := range docs {
			if o == d {
				at = i
			}
		}
		if at < 0 {
			return
		}
		docs = append(docs[:at], docs[at+1:]...)
		if active == d && len(docs) > 0 {
			next := docs[min(at, len(docs)-1)]
			tx.SelectDocument(next.id)
			activate(tx, next)
		}
	}
	closeDoc := func(tx *kaya.Tx, d *document) {
		tx.CloseDocument(d.id)
		forget(tx, d)
	}

	// A COMPOSITION: kaya has no "confirm before you discard".
	ask := func(tx *kaya.Tx, d *document, then func(*kaya.Tx)) {
		if !d.dirty() {
			then(tx)
			return
		}
		tx.ShowAlert().
			Title("unsaved changes").
			Message(docName(d.dest) + " has unsaved changes").
			Action("Discard").
			Cancel("Keep Editing").
			OnResult(func(tx *kaya.Tx, choice kaya.AlertChoice) {
				if choice == kaya.AlertChoiceCancel {
					return
				}
				then(tx)
			}).
			Show()
	}

	// The native window's close asks about each unsaved document in turn,
	// one alert at a time, and closes them all once every one is agreed to;
	// one Keep Editing keeps them all.
	var askEach func(tx *kaya.Tx, left, all []*document)
	askEach = func(tx *kaya.Tx, left, all []*document) {
		for len(left) > 0 && !left[0].dirty() {
			left = left[1:]
		}
		if len(left) == 0 {
			for _, d := range all {
				closeDoc(tx, d)
			}
			return
		}
		ask(tx, left[0], func(tx *kaya.Tx) { askEach(tx, left[1:], all) })
	}

	var newDocument func(tx *kaya.Tx) *document

	// saveTo writes off the app goroutine: PickedFile.Open BLOCKS.
	saveTo := func(d *document, file kaya.PickedFile, body string) {
		go func() {
			n, err := writeDoc(file, body)
			app.Post(func(tx *kaya.Tx) {
				if err != nil {
					tx.Write(d.status, "save failed: "+err.Error())
					return
				}
				// body AND NOT text: the user may have typed since.
				retarget(tx, d, &file, body)
				// The byte count is READ BACK OFF THE DISK.
				tx.Write(d.status, fmt.Sprintf("saved, %d bytes", n))
				mark(tx, d)
			})
		}()
	}

	// A file opens into the active tab while it is pristine, else into a
	// tab of its own.
	openFrom := func(file kaya.PickedFile) {
		go func() {
			body, err := readDoc(file)
			app.Post(func(tx *kaya.Tx) {
				d := active
				if err != nil {
					if d != nil {
						tx.Write(d.status, "open failed: "+err.Error())
					}
					return
				}
				if d == nil || !d.pristine() {
					d = newDocument(tx)
				}
				d.text = body
				retarget(tx, d, &file, body)
				// A PROGRAMMATIC WRITE does not echo, so the fold is by hand;
				// it also spends the field's native undo history.
				tx.SetText(d.buffer, body)
				tx.Write(d.where, position(d.text, d.sel.Range))
				tx.Focus(d.buffer)
				tx.Write(d.status, fmt.Sprintf("opened, %d bytes", len(body)))
				mark(tx, d)
				refind(tx, d)
			})
		}()
	}

	// The editors' zoom steps, a multiple of the platform's size.
	zooms := []float64{0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3}
	setZoom := func(tx *kaya.Tx, step int) {
		d := active
		d.zoom = min(max(step, 0), len(zooms)-1)
		tx.SetTextScale(d.buffer, zooms[d.zoom])
		tx.Write(d.status, fmt.Sprintf("zoom %d%%", int(zooms[d.zoom]*100+0.5)))
	}

	// One tab: its buffer, its find bar and its status line, each widget's
	// a11y id carrying the document's number so two tabs never share one.
	newDocument = func(tx *kaya.Tx) *document {
		made++
		d := &document{id: uint64(made), n: made, zoom: 4, numbers: true}
		docs = append(docs, d)
		d.status = tx.Signal("new file")
		d.where = tx.Signal(position("", kaya.TextRange{}))
		d.count = tx.Signal("")
		d.countTint = tx.Signal(kaya.TintNone)
		tx.AddDocument(d.id).Title(untitled).Select().
			OnSelected(func(tx *kaya.Tx) { activate(tx, d) }).
			OnCloseRequested(func(tx *kaya.Tx) { ask(tx, d, func(tx *kaya.Tx) { closeDoc(tx, d) }) }).
			OnClosed(func(tx *kaya.Tx) { forget(tx, d) })
		id := func(name string) string { return fmt.Sprintf("%s-%d", name, d.n) }
		var query, prev, next, done kaya.Node
		// grow divides the MAIN axis and align owns the cross one: a
		// full-window buffer needs both.
		tx.MountIn(d.id, tx.Column(func() {
			// RICH FROM LAUNCH: a plain document is a rich one with no runs,
			// and the runs are the widget's, never the file's (§8).
			d.buffer = tx.Textarea(func(tx *kaya.Tx, s string) {
				// Every user edit arrives here, a native undo included.
				d.text = s
				tx.Write(d.where, position(d.text, d.sel.Range))
				mark(tx, d)
				refind(tx, d)
			}).Grow(1).A11yID(id("buffer")).A11yLabel("Document").Rich().LineNumbers(true).Monospaced(true)

			// STAMPED AND TORN DOWN, not hidden, so each Find… starts empty
			// (editor.steps reads it). SetInset rides the STAMPED row.
			d.findRows = tx.Collection()
			for row := range tx.Rows(d.findRows).All() {
				bar := row.Row(func() {
					query = row.Entry()
					row.SetPlaceholder(query, "Find")
					row.SetGrow(query, 1)
					icon := func(id, title string, symbol kaya.Symbol) kaya.Node {
						n := row.Button(title)
						row.SetA11yID(n, id)
						row.SetSymbol(n, symbol)
						row.SetHelp(n, title)
						return n
					}
					prev = icon("prev", "Previous match", kaya.SymbolBack)
					next = icon("next", "Next match", kaya.SymbolForward)
					// Dismiss cannot be a keystroke: no bare Escape exists.
					done = icon("done", "Close find bar", kaya.SymbolClose)
				})
				row.SetInset(bar, 8)
				row.SetA11yID(bar, "findbar")
			}

			// INSET ON THE CHROME, NOT THE WINDOW: Inset(0) takes this row's
			// margin with it (docs/deferred.md, the inset entry). One line of
			// small text, as compact as a code editor's status bar, its sides
			// clear of the window's rounded corner (docs/editor-plan.md E7).
			tx.Row(func() {
				tx.Label(d.status).TextScale(0.85).Grow(1).A11yID(id("status"))
				tx.Label(d.count).TextScale(0.85).BindTint(d.countTint).A11yID(id("matches"))
				tx.Label(d.where).TextScale(0.85).A11yID(id("position"))
			}).Inset(6, 14).A11yID(id("statusbar"))
		}).Align(kaya.AlignStretch).Spacing(0))

		// REGISTERED AGAINST THE TEMPLATE NODE, once, for every copy ever
		// stamped.
		query.OnChange(func(tx *kaya.Tx, _ []any, s string) {
			d.pattern = s
			refind(tx, d)
			// The one place the selection moves without a person asking.
			show(tx, d, 0)
		})
		prev.OnClick(func(tx *kaya.Tx, _ []any) { show(tx, d, d.at-1) })
		next.OnClick(func(tx *kaya.Tx, _ []any) { show(tx, d, d.at+1) })
		// Dismiss TEARS THE BAR DOWN; nothing clears the query field, so the
		// next Find… stamps a NEW one.
		done.OnClick(func(tx *kaya.Tx, _ []any) {
			d.open = false
			d.pattern = ""
			tx.Remove(d.findRows, findKey)
			refind(tx, d)
			tx.Focus(d.buffer)
		})
		d.buffer.OnSelection(func(tx *kaya.Tx, sel kaya.Selection) {
			d.sel = sel
			tx.Write(d.where, position(d.text, sel.Range))
			if active == d {
				marks(tx, d)
			}
		})
		tx.SetLineNumbers(d.buffer, d.numbers)
		wear(tx, d)
		active = d
		tx.Focus(d.buffer)
		return d
	}

	app.OnFontFamilies(func(tx *kaya.Tx, families []string) {
		if font.Family != "" {
			return
		}
		for _, want := range codeFamilies {
			for _, have := range families {
				if have == want {
					font = kaya.FontChoice{Family: want, Weight: 400, Width: 5}
					for _, d := range docs {
						wear(tx, d)
					}
					return
				}
			}
		}
	})

	app.Build(func(tx *kaya.Tx) {
		font = kaya.FontChoice{
			Family: kaya.Prefs().GetString("font.family", ""),
			Weight: int(kaya.Prefs().GetI64("font.weight", 400)),
			Italic: kaya.Prefs().GetBool("font.italic", false),
			Width:  int(kaya.Prefs().GetI64("font.width", 5)),
		}
		if font.Family == "" {
			tx.ListFontFamilies()
		}
		// Before anything mounts (the set-once wall); a REQUEST, not a rule.
		tx.BrandAccent(0x0F7B6C)
		// Inset 0 leaves a phone's safe area alone. The window is titled by
		// the document in front.
		win := tx.Window(0).Size(640, 420).Inset(0).NewDocument(true).
			OnNewDocument(func(tx *kaya.Tx) { activate(tx, newDocument(tx)) }).
			OnDocumentsCloseRequested(func(tx *kaya.Tx, ids []uint64) {
				var asked []*document
				for _, id := range ids {
					for _, d := range docs {
						if d.id == id {
							asked = append(asked, d)
						}
					}
				}
				askEach(tx, asked, asked)
			})

		// NO FILTER: the scene's documents have no extensions to match.
		openDoc := func(tx *kaya.Tx) {
			tx.PickFile().OnResult(func(tx *kaya.Tx, files []kaya.PickedFile) {
				if len(files) == 0 {
					tx.Write(active.status, "open cancelled")
					return
				}
				for _, f := range files {
					openFrom(f)
				}
			}).Show()
		}

		// The panel OPENS with the name the window is already showing.
		saveAs := func(tx *kaya.Tx) {
			d := active
			body := d.text
			tx.SaveFile(docName(d.dest)).OnResult(func(tx *kaya.Tx, file *kaya.PickedFile) {
				if file == nil {
					tx.Write(d.status, "save cancelled")
					return
				}
				saveTo(d, *file, body)
			}).Show()
		}

		// No dialog: the handle the user chose the file with is writable.
		save := func(tx *kaya.Tx) {
			if active.dest == nil {
				saveAs(tx)
				return
			}
			saveTo(active, *active.dest, active.text)
		}

		file := win.Menu("File")
		file.Item("New").Shortcut("primary+n").OnActivate(func(tx *kaya.Tx) {
			activate(tx, newDocument(tx))
		})
		file.Item("Open…").Shortcut("primary+o").OnActivate(openDoc)
		// The host promotes the first k primaries in catalog preorder.
		file.Item("Save").Symbol(kaya.SymbolSave).Primary(true).
			Shortcut("primary+s").OnActivate(save)
		file.Item("Save As…").Shortcut("primary+shift+s").OnActivate(saveAs)
		file.Separator()
		file.Item("Close Tab").Shortcut("primary+w").OnActivate(func(tx *kaya.Tx) {
			d := active
			ask(tx, d, func(tx *kaya.Tx) { closeDoc(tx, d) })
		})

		// NO SHORTCUTS ON A ROLE: it carries the platform's own chord, and
		// acts on the focused widget, which is in the document in front.
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
			d := active
			if d.open {
				return
			}
			d.open = true
			tx.Insert(d.findRows, findKey, "")
			refind(tx, d)
		})

		// Over the widget's own selection (docs/rich-text-plan.md §7). Each
		// style toggles: its check is what holds over the selection, and the
		// toggle's new state picks the act. A phone carries the menu on the bar
		// above its keyboard (docs/phone-format-plan.md §2).
		format := win.Menu("Format").KeyboardBar(true)
		flag := func(label, name, chord string, symbol kaya.Symbol) {
			on := tx.Signal(false)
			inline[name] = on
			item := format.Toggle(label).BindChecked(on).OnToggle(func(tx *kaya.Tx, want bool) {
				tx.Write(on, want)
				if want {
					tx.FormatFlag(active.buffer, name, true)
				} else {
					tx.Unformat(active.buffer, name)
				}
			}).Shortcut(chord)
			if symbol != 0 {
				item.Symbol(symbol)
			}
		}
		flag("Bold", "bold", "primary+b", kaya.SymbolBold)
		flag("Italic", "italic", "primary+i", kaya.SymbolItalic)
		flag("Underline", "underline", "primary+u", kaya.SymbolUnderline)
		flag("Strikethrough", "strike", "primary+shift+x", kaya.SymbolStrikethrough)
		flag("Code", "code", "primary+e", 0)
		format.Separator()
		style := format.Menu("Paragraph Style")
		paragraph := func(label string, kind kaya.Block, chord string) {
			on := tx.Signal(kind == kaya.Body)
			styles[kind] = on
			item := style.Toggle(label).BindChecked(on).OnToggle(func(tx *kaya.Tx, want bool) {
				// Body cannot be taken off: a paragraph is always some kind.
				if !want || kind == kaya.Body {
					tx.SetBlock(active.buffer, kaya.Body)
					tx.Write(on, kind == kaya.Body)
					return
				}
				tx.Write(on, true)
				tx.SetBlock(active.buffer, kind)
			})
			if chord != "" {
				item.Shortcut(chord)
			}
		}
		paragraph("Heading 1", kaya.Heading1, "primary+alt+1")
		paragraph("Heading 2", kaya.Heading2, "primary+alt+2")
		paragraph("Quote", kaya.Quote, "")
		paragraph("Body", kaya.Body, "primary+alt+0")

		// The code editors' View menu (Sublime Text, VS Code, Zed): the
		// gutter, the zoom chords, and the face, each the active document's.
		numbersOn = tx.Signal(true)
		view := win.Menu("View")
		view.Toggle("Line Numbers").BindChecked(numbersOn).OnToggle(func(tx *kaya.Tx, on bool) {
			active.numbers = on
			tx.Write(numbersOn, on)
			tx.SetLineNumbers(active.buffer, on)
		})
		view.Separator()
		view.Item("Zoom In").Shortcut("primary+equal").OnActivate(func(tx *kaya.Tx) { setZoom(tx, active.zoom+1) })
		view.Item("Zoom Out").Shortcut("primary+minus").OnActivate(func(tx *kaya.Tx) { setZoom(tx, active.zoom-1) })
		view.Item("Actual Size").Shortcut("primary+0").OnActivate(func(tx *kaya.Tx) { setZoom(tx, 4) })
		view.Separator()
		view.Item("Font…").OnActivate(func(tx *kaya.Tx) {
			ask := tx.ChooseFont().CodeOnly(true).Faces(true).OnResult(func(tx *kaya.Tx, c *kaya.FontChoice) {
				if c == nil {
					return
				}
				font = *c
				kaya.Prefs().SetString("font.family", c.Family)
				kaya.Prefs().SetI64("font.weight", int64(c.Weight))
				kaya.Prefs().SetBool("font.italic", c.Italic)
				kaya.Prefs().SetI64("font.width", int64(c.Width))
				for _, d := range docs {
					wear(tx, d)
				}
				tx.Write(active.status, "font "+c.Family)
			})
			if font.Family != "" {
				ask = ask.Initial(font)
			}
			ask.Show()
		})

		newDocument(tx)
	})

	return app
}
