// The number field scene (tools/scenes/numberfield.steps;
// docs/number-field-plan.md §5).
package numberfield

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Line -key string
type Line struct {
	Name string
	Qty  float64
}

// spelled is the harness's own value spelling (crates/kaya/src/harness.rs).
func spelled(v float64) string {
	s := strings.TrimRight(fmt.Sprintf("%.6f", v), "0")
	return strings.TrimSuffix(s, ".")
}

func App() *kaya.App {
	app := kaya.NewApp()
	commits := 0

	app.Build(func(tx *kaya.Tx) {
		commitText := tx.Signal("commits: 0")
		rowText := tx.Signal("row: none")
		amountValue := tx.Signal(0.0)
		lines := LineCollection(tx)

		tx.Mount(tx.Column(func() {
			tx.Label(commitText).A11yID("commits")
			tx.Label(rowText).A11yID("row")
			tx.NumberFieldBound(amountValue, func(tx *kaya.Tx, _ float64) {
				commits++
				tx.Write(commitText, fmt.Sprintf("commits: %d", commits))
			}).Min(0).Max(100).Step(0.5).A11yID("amount").A11yLabel("Amount")
			tx.Entry(nil).A11yID("note")
			tx.Button("forty", func(tx *kaya.Tx) {
				// Must NOT come back as a commit.
				tx.Write(amountValue, 40.0)
			}).A11yID("forty")
			for row := range LineRows(tx, lines).All() {
				row.Label(row.Name())
				qty := row.NumberField(row.Qty(), func(tx *kaya.Tx, key string, v float64) {
					tx.Write(rowText, fmt.Sprintf("row %s: %s", key, spelled(v)))
				})
				row.SetMin(qty, 0)
				row.SetA11yID(qty, "qty")
			}
		}))

		lines.Insert(tx, "a", Line{Name: "a", Qty: 1.0})
		lines.Insert(tx, "b", Line{Name: "b", Qty: 2.0})
	})

	return app
}
