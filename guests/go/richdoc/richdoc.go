// The rich document scene (tools/scenes/richdoc.steps,
// docs/rich-document-plan.md §9 step 2): a heading, a body paragraph with a
// preset colour, a bullet list with a nested item, a numbered list and a
// checklist, then the paragraph acts from buttons, the platform's colour
// picker and a `.kdoc` round trip. label#1 is the binding's own Document,
// folded from the same deltas, so it must spell what the core holds.
package richdoc

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

// BYTE-IDENTICAL to guests/rust/richdoc.rs's DOC.
const document = "Groceries\nFresh from the market.\nApples\nGreen ones\nBread\nWash\nSlice\nMilk\nEggs"

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

func seeded() kaya.Document {
	return kaya.NewDocument(document).
		Block(0, 9, kaya.Heading1).
		Color(25, 31, "#016FEF").
		List(33, 56, kaya.ListBullet).
		Indent(40, 50, 1).
		List(57, 67, kaya.ListNumbered).
		Checked(68, 72).
		List(68, 77, kaya.ListCheck)
}

func App() *kaya.App {
	app := kaya.NewApp()

	var last, runs, kdoc kaya.Signal[string]
	var editor kaya.Widget
	doc := seeded()

	app.Build(func(tx *kaya.Tx) {
		win := tx.Window(0).Title("richdoc").Size(560, 620)
		edit := win.Menu("Edit")
		edit.Item("Cut").Role(kaya.RoleCut)
		edit.Item("Copy").Role(kaya.RoleCopy)
		edit.Item("Paste").Role(kaya.RolePaste)

		last = tx.Signal("")
		runs = tx.Signal(spell(doc.Runs))
		kdoc = tx.Signal("")

		tx.Mount(tx.Column(func() {
			editor = tx.Textarea(nil).Rich().Grow(1).A11yID("doc").A11yLabel("Document")
			editor.OnEdit(func(tx *kaya.Tx, edit kaya.Edit) {
				source := string(edit.Source)
				if edit.Source == kaya.SourceNone {
					source = "?"
				}
				tx.Write(last, fmt.Sprintf("edit %d:%d <%s> %s [%s]",
					edit.Range.Start, edit.Range.End, strings.ReplaceAll(edit.Inserted, "\n", `\n`),
					source, spell(edit.Runs)))
				tx.Write(runs, spell(app.Document(editor).Runs))
			})
			editor.OnFormat(func(tx *kaya.Tx, act kaya.Format) {
				value := act.Value
				if act.Removed {
					value = "off"
				}
				tx.Write(last, fmt.Sprintf("format %d:%d %s=%s",
					act.Range.Start, act.Range.End, act.Name, value))
				tx.Write(runs, spell(app.Document(editor).Runs))
			})

			tx.Label(last) // label#0
			tx.Label(runs) // label#1
			tx.Label(kdoc) // label#2

			tx.Row(func() {
				tx.Button("numbered", func(tx *kaya.Tx) { // button#0
					tx.SetList(editor, kaya.ListNumbered)
				})
				tx.Button("indent", func(tx *kaya.Tx) { // button#1
					tx.Indent(editor)
				})
				tx.Button("red", func(tx *kaya.Tx) { // button#2
					tx.Color(editor, "#DD1F24")
				})
				tx.Button("colour", func(tx *kaya.Tx) { // button#3
					tx.PickTextColor(editor)
				})
				tx.Button("kdoc", func(tx *kaya.Tx) { // button#4
					now := app.Document(editor)
					bytes := now.ToKdoc()
					back, err := kaya.FromKdoc(bytes)
					if err != nil {
						panic("kaya wrote a .kdoc it cannot read: " + err.Error())
					}
					readOnly := back.ReadOnly
					if readOnly == "" {
						readOnly = "none"
					}
					same := back.Document.Equal(now)
					tx.SetDocument(editor, back.Document)
					tx.Write(kdoc, fmt.Sprintf("kdoc %d bytes, read_only %s, same %t", len(bytes), readOnly, same))
					tx.Write(runs, spell(back.Document.Runs))
				})
			})
		}))
		tx.SetDocument(editor, doc)
	})

	return app
}
