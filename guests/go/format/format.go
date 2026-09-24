// The formatter door and the catalog (tools/scenes/format.steps,
// docs/compliance-plan.md §6): fixed inputs through every format call and
// two catalog messages, asserted against what THIS platform's formatter
// writes and against the catalog's own bytes.
package format

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()
	kaya.Catalog("format")
	d := kaya.Date{Year: 2026, Month: 9, Day: 7}
	t := kaya.Time{Hour: 8, Minute: 30}

	app.Build(func(tx *kaya.Tx) {
		// Fourteen labels and a row: taller than the default window, which
		// GTK would otherwise let the root overflow (expect_root_fills).
		tx.Window(0).Title("format").Size(540, 560)
		label := func(text string) { tx.Label(tx.Signal(text)) }
		tx.Mount(tx.Column(func() {
			label(kaya.FormatDate(d, kaya.Short))                  // label#0
			label(kaya.FormatDate(d, kaya.Medium))                 // label#1
			label(kaya.FormatDate(d, kaya.Long))                   // label#2
			label(kaya.FormatTime(t, kaya.Short))                  // label#3
			label(kaya.FormatDateTime(d, t, kaya.Medium))          // label#4
			label(kaya.FormatNumber(1234567.891, nil))             // label#5
			label(kaya.FormatPercent(0.256, nil))                  // label#6
			label(kaya.FormatCurrency(1234567.89, "USD"))          // label#7
			label(kaya.Tr("items", kaya.Args{"count": 1}))         // label#8
			label(kaya.Tr("items", kaya.Args{"count": 3}))         // label#9
			label(kaya.Tr("greeting", kaya.Args{"name": "Ada"}))   // label#10
			tx.Row(func() {
				label("first") // label#11
				tx.Spacer()
				label("last") // label#12
			}) // row#0
			label(kaya.Locale().Tag) // label#13
		}))
	})

	return app
}
