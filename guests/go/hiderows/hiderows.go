// The hidden-rows scene (tools/scenes/hiderows.steps; docs/hidden-plan.md).
// Canonical semantics in guests/rust/hiderows.rs.
package hiderows

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Note -key string
type Note struct {
	Title     string
	Unmatched bool
}

//go:generate go run dev.kaya/cmd/kaya-gen -type File -key string
type File struct {
	Name      string
	Size      string
	Unmatched bool
}

var notes = []string{"alpha", "beta", "gamma"}

func fileName(i int) string { return fmt.Sprintf("file %03d", i) }

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("hiderows")
		noteRows := NoteCollection(tx)
		fileRows := FileCollection(tx)
		two := tx.Signal(false)

		tx.Mount(tx.Column(func() {
			tx.Search(func(tx *kaya.Tx, query string) {
				for _, title := range notes {
					NotePatch(noteRows, tx, title).Unmatched(!strings.Contains(title, query))
				}
			}).Placeholder("Find notes").A11yID("find_notes")
			list := NoteRows(tx, noteRows)
			for note := range list.All() {
				line := note.Row(func() {
					note.Label(note.Title())
					field := note.Entry(nil)
					note.SetA11yID(field, "note")
				})
				note.BindHidden(line, note.Unmatched())
			}
			tx.SetA11yID(list.Widget(), "notes")
			tx.Grid(2, func() {
				tx.LabelText("one")
				tx.LabelText("two").BindHidden(two)
				tx.LabelText("three")
			}).A11yID("tiles")
			tx.Checkbox("Hide two", func(tx *kaya.Tx, on bool) { tx.Write(two, on) }).A11yID("hide_two")
			tx.Search(func(tx *kaya.Tx, query string) {
				for i := 0; i < 300; i++ {
					FilePatch(fileRows, tx, fileName(i)).Unmatched(!strings.Contains(fileName(i), query))
				}
			}).Placeholder("Find files").A11yID("find_files")
			table := FileRows(tx, fileRows).Columns([]string{"Name", "Size"}, kaya.SortNone())
			for file := range table.All() {
				line := file.Row(func() {
					file.Label(file.Name())
					file.Label(file.Size())
				})
				file.BindHidden(line, file.Unmatched())
			}
			tx.SetA11yID(table.Widget(), "files")
			tx.SetGrow(table.Widget(), 1)
		}))

		for _, title := range notes {
			noteRows.Insert(tx, title, Note{Title: title})
		}
		for i := 0; i < 300; i++ {
			fileRows.Insert(tx, fileName(i), File{Name: fileName(i), Size: fmt.Sprintf("%d KB", i)})
		}
	})

	return app
}
