// The rich text scene (tools/scenes/richtext.steps): the app declares a
// document, applies an edit, formats the widget's selection through its
// own act, and reads every delta back into its own Document. THE OFFSETS
// ARE UTF-8 BYTES, which is what Go's own string indexing already
// produces (docs/ranges-units.md).
package richtext

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

const document = "Héllo world\nSecond line"

// spell is the core's spelling of runs (`expect_runs`), so the binding's
// document and the core's mirror are compared as one string.
func spell(runs []kaya.TextRun) string {
	parts := make([]string, 0, len(runs))
	for _, run := range runs {
		if run.Value == "true" {
			parts = append(parts, fmt.Sprintf("%d:%d %s", run.Start, run.End, run.Name))
			continue
		}
		parts = append(parts, fmt.Sprintf("%d:%d %s=%s", run.Start, run.End, run.Name, run.Value))
	}
	return strings.Join(parts, "|")
}

func App() *kaya.App {
	app := kaya.NewApp()

	var last, runs kaya.Signal[string]
	var editor kaya.Widget

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("richtext")
		last = tx.Signal("")
		runs = tx.Signal("")

		tx.Mount(tx.Column(func() {
			editor = tx.Textarea(nil).Rich().A11yID("doc").A11yLabel("Document")
			app.OnEdit(editor, func(tx *kaya.Tx, edit kaya.Edit) {
				tx.Write(last, fmt.Sprintf("edit %d:%d <%s> [%s]",
					edit.Start, edit.End, edit.Inserted, spell(edit.Runs)))
				tx.Write(runs, spell(app.Document(editor).Runs))
			})
			app.OnFormat(editor, func(tx *kaya.Tx, act kaya.Format) {
				value := act.Value
				if act.Removed {
					value = "off"
				}
				tx.Write(last, fmt.Sprintf("format %d:%d %s=%s",
					act.Start, act.End, act.Name, value))
				tx.Write(runs, spell(app.Document(editor).Runs))
			})

			tx.Label(last) // label#0
			tx.Label(runs) // label#1

			tx.Row(func() {
				tx.Button("seed", func(tx *kaya.Tx) { // button#0
					doc := kaya.NewDocument(document).
						Bold(0, 6).
						Link(7, 12, "https://kaya.dev").
						Block(13, 24, kaya.Heading2)
					tx.SetDocument(editor, doc)
					tx.Write(runs, spell(doc.Runs))
				})
				tx.Button("insert", func(tx *kaya.Tx) { // button#1
					tx.ApplyEdit(editor, kaya.Insert(6, ", big").Mark(2, 5, "italic", "true"))
					tx.Write(runs, spell(app.Document(editor).Runs))
				})
				tx.Button("select word", func(tx *kaya.Tx) { // button#2
					tx.SelectRange(editor, kaya.TextRange{Start: 0, End: 6})
				})
				tx.Button("unbold", func(tx *kaya.Tx) { // button#3
					tx.Unformat(editor, "bold")
				})
				tx.Button("heading", func(tx *kaya.Tx) { // button#4
					tx.SetBlock(editor, kaya.Heading1)
				})
				tx.Button("focus", func(tx *kaya.Tx) { // button#5
					tx.Focus(editor)
				})
				tx.Button("prefix", func(tx *kaya.Tx) { // button#6
					tx.ApplyEdit(editor, kaya.Insert(0, "> "))
					tx.Write(runs, spell(app.Document(editor).Runs))
				})
			})
		}))
	})

	return app
}
