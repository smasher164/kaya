// The rich rows scene (tools/scenes/richrows.steps): a rich textarea per
// stamped ROW whose document is a FIELD of the row
// (docs/rich-text-plan.md §19). The app writes a copy's document by
// patching its row, and a copy's own act folds into the row the app
// reads back.
package richrows

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Note -key string
type Note struct {
	Title string
	Body  kaya.Document
}

// patched is row b's patch, read from a file that carries a member this
// kaya does not know, so the row holds a Document with an Extra
// (docs/rich-document-plan.md RD20).
const patched = `{"kaya": "document", "version": 1, "com.example.theme": "dusk", "paragraphs": [{"spans": [["Patched", {"italic": true}]]}]}`

// spell is the core's spelling of runs (expect_runs), so the row's field
// and the core's mirror are compared as one string.
func spell(runs []kaya.TextRun) string {
	parts := make([]string, 0, len(runs))
	for _, run := range runs {
		if run.IsFlag() {
			parts = append(parts, fmt.Sprintf("%d:%d %s", run.Range.Start, run.Range.End, run.Name))
			continue
		}
		parts = append(parts, fmt.Sprintf("%d:%d %s=%s", run.Range.Start, run.Range.End, run.Name, run.Value))
	}
	return strings.Join(parts, "|")
}

func App() *kaya.App {
	app := kaya.NewApp()

	var last, view kaya.Signal[string]
	var notes kaya.RecordCollection[string, Note]

	row := func(tx *kaya.Tx, key string) Note {
		note, ok := notes.Get(tx, key)
		if !ok {
			panic(fmt.Sprintf("richrows: no row %q", key))
		}
		return note
	}

	// An undo or redo moved the row back: the app reads ITS OWN mirror of
	// row b, which is the fold a restored Blob field lands in.
	restored := func(tx *kaya.Tx, _ string, _ kaya.UndoDelta) {
		note := row(tx, "b")
		tx.Write(view, fmt.Sprintf("%s | %s", note.Body.Text, spell(note.Body.Runs)))
	}

	app.Build(func(tx *kaya.Tx) {
		win := tx.Window(0).Title("richrows").OnUndone(restored).OnRedone(restored)
		edit := win.Menu("Edit")
		edit.Item("Undo").Role(kaya.RoleUndo)
		edit.Item("Redo").Role(kaya.RoleRedo)
		notes = NoteCollection(tx)
		last = tx.Signal("")
		view = tx.Signal("")

		tx.Mount(tx.Column(func() {
			tx.Label(last) // label#0
			tx.Label(view) // label#1

			tx.Row(func() {
				tx.Button("patch b", func(tx *kaya.Tx) { // button#0
					tx.Undoable("patch b")
					file, err := kaya.FromKdoc([]byte(patched))
					if err != nil {
						panic(fmt.Sprintf("richrows: the scene's file reads: %v", err))
					}
					NotePatch(notes, tx, "b").Body(file.Document)
				})
				tx.Button("read a", func(tx *kaya.Tx) { // button#1
					note := row(tx, "a")
					tx.Write(view, fmt.Sprintf("%s | %s", note.Body.Text, spell(note.Body.Runs)))
				})
				tx.Button("save b", func(tx *kaya.Tx) { // button#2
					note := row(tx, "b")
					back, err := kaya.FromKdoc(note.Body.ToKdoc())
					if err != nil {
						panic(fmt.Sprintf("richrows: kaya wrote a .kdoc it cannot read: %v", err))
					}
					extra := strings.ReplaceAll(back.Document.Extra, `"`, "'")
					tx.Write(view, fmt.Sprintf("saved %s, extra %s", back.Document.Text, extra))
				})
			})

			for r := range NoteRows(tx, notes).All() {
				r.Column(func() {
					r.Label(r.Title())
					// The row's field already carries the copy's act when
					// this fires: the app reads the row, never the widget.
					acted := func(tx *kaya.Tx, key string) {
						note := row(tx, key)
						tx.Write(last, fmt.Sprintf("%s: %s", key, spell(note.Body.Runs)))
					}
					body := r.TextareaRich(r.Body(),
						func(tx *kaya.Tx, key string, _ kaya.Edit) { acted(tx, key) },
						func(tx *kaya.Tx, key string, _ kaya.Format) { acted(tx, key) })
					r.SetA11yID(body, "body")
				})
			}
		}))

		notes.Insert(tx, "a", Note{
			Title: "a",
			Body:  kaya.NewDocument("Héllo world").Bold(0, 6),
		})
		notes.Insert(tx, "b", Note{
			Title: "b",
			Body:  kaya.NewDocument("Second note").Link(7, 11, "https://kaya.dev"),
		})
	})

	return app
}
