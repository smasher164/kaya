// The code surface scene (tools/scenes/codesurface.steps,
// docs/code-surface-plan.md): a textarea that numbers its lines, the
// platform's monospaced face, a family the app picks from the platform's
// list, a family the platform lacks, and a label at twice the platform's size.
package codesurface

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

// Forty lines; the third wraps at every lane's width. Byte-identical to
// guests/rust/codesurface.rs's document.
func document() string {
	lines := []string{
		"// codesurface",
		"fn main() {",
		"    let note = \"this line is long on purpose, so that the textarea wraps it onto a second row " +
			"and the gutter has a continuation to leave unnumbered, the way every editor does\";",
	}
	for i := 4; i < 40; i++ {
		lines = append(lines, fmt.Sprintf("    let value_%02d = %d * 2;", i, i))
	}
	lines = append(lines, "}")
	return strings.Join(lines, "\n")
}

func App() *kaya.App {
	app := kaya.NewApp()
	doc := document()

	var code, picked kaya.Widget
	var listed kaya.Signal[string]

	app.OnFontFamilies(func(tx *kaya.Tx, families []string) {
		ordered := true
		for i := 1; i < len(families); i++ {
			if families[i-1] >= families[i] {
				ordered = false
			}
		}
		switch {
		case len(families) == 0:
			tx.Write(listed, "families: none")
		case ordered:
			tx.Write(listed, "families: listed, unique, in order")
		default:
			tx.Write(listed, "families: out of order")
		}
		if len(families) > 0 {
			tx.SetFamily(picked, families[0])
		}
	})

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("codesurface")
		listed = tx.Signal("families: -")

		tx.Mount(tx.Column(func() {
			code = tx.Textarea(nil).LineNumbers(true).Monospaced(true).A11yID("code")
			tx.SetText(code, doc)
			plain := tx.Textarea(nil).A11yID("plain")
			tx.SetText(plain, "plain text\nin the app's face")
			tx.LabelText("let x = 1;").Monospaced(true).A11yID("mono")
			monoEntry := tx.Entry(nil).Monospaced(true).A11yID("mono_entry")
			tx.SetText(monoEntry, "let y = 2;")
			tx.LabelText("missing").Family("Kaya No Such Family").Monospaced(true).A11yID("missing")
			tx.LabelText("Big").TextScale(2).A11yID("big")
			tx.LabelText("Plain").A11yID("plain_label")
			tx.Label(listed).A11yID("families")
			picked = tx.LabelText("picked").A11yID("picked")
			tx.Row(func() {
				tx.Button("end", func(tx *kaya.Tx) {
					end := len(doc)
					tx.Focus(code)
					tx.SelectRange(code, kaya.TextRange{Start: end, End: end})
					tx.RevealRange(code, kaya.TextRange{Start: end, End: end})
				}).A11yID("end")
				tx.Button("fonts", func(tx *kaya.Tx) { tx.ListFontFamilies() }).A11yID("fonts")
			})
		}))
	})

	return app
}
