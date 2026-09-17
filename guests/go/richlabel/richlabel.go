// The rich label scene (tools/scenes/richlabel.steps; docs/rich-text-plan.md
// R8, §15): a label carries the inline vocabulary read-only — the app writes
// its document and edits it, and the widget draws the runs over the role's
// own font. THE OFFSETS ARE UTF-8 BYTES, which is what Go's own string
// indexing already produces (docs/ranges-units.md).
package richlabel

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

const document = "Héllo world, code"

// spell is the core's spelling of runs (`expect_runs`), so the binding's
// document and the core's mirror are compared as one string.
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

	var runs kaya.Signal[string]
	var body, heading kaya.Widget

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("richlabel")
		runs = tx.Signal("")

		tx.Mount(tx.Column(func() {
			bodyText := tx.Signal("")
			headingText := tx.Signal("Heading with italic")

			body = tx.Label(bodyText).Rich().A11yID("body") // label#0
			heading = tx.Label(headingText).Role(kaya.RoleHeading).
				Rich().A11yID("heading") // label#1
			tx.Label(runs).A11yID("runs") // label#2

			tx.Row(func() {
				tx.Button("seed", func(tx *kaya.Tx) { // button#0
					doc := kaya.NewDocument(document).
						Bold(0, 6).
						Link(7, 12, "https://kaya.dev").
						Flag(14, 18, "code", true)
					title := kaya.NewDocument("Heading with italic").
						Flag(13, 19, "italic", true)
					tx.SetDocument(body, doc)
					tx.SetDocument(heading, title)
					tx.Write(runs, spell(doc.Runs))
				})
				tx.Button("insert", func(tx *kaya.Tx) { // button#1
					tx.ApplyEdit(body, kaya.Insert(6, ", big").Flag(2, 5, "italic", true))
					tx.Write(runs, spell(app.Document(body).Runs))
				})
				tx.Button("mark", func(tx *kaya.Tx) { // button#2
					tx.FormatRangeFlag(body, kaya.TextRange{Start: 1, End: 4}, "italic", true)
					tx.UnformatRange(body, kaya.TextRange{Start: 0, End: 3}, "bold") // "Hé": byte 2 is inside the é
					tx.Write(runs, spell(app.Document(body).Runs))
				})
			})
		}))
	})

	return app
}
