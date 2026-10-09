// The segmented control scene (tools/scenes/segmented.steps;
// docs/segmented-plan.md §5).
package segmented

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Habit -key string
type Habit struct {
	Name    string
	Cadence float64
}

var (
	periods  = []string{"Day", "Week", "Month"}
	views    = []kaya.Segment{{Name: "Info", Symbol: kaya.SymbolInfo}, {Name: "Edit", Symbol: kaya.SymbolEdit}}
	cadences = []string{"Daily", "Weekly"}
)

func App() *kaya.App {
	app := kaya.NewApp()
	heard := 0

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("segmented")
		period := tx.Signal(0.0)
		periodText := tx.Signal("period: Day")
		heardText := tx.Signal("heard: 0")
		viewText := tx.Signal("view: Edit")
		cadenceText := tx.Signal("cadence: -")
		habits := HabitCollection(tx)

		tx.Mount(tx.Column(func() {
			tx.SegmentedBound(periods, period, func(tx *kaya.Tx, index int) {
				heard++
				tx.Write(period, float64(index))
				tx.Write(periodText, "period: "+periods[index])
				tx.Write(heardText, fmt.Sprintf("heard: %d", heard))
			}).A11yID("period").A11yLabel("Period")
			tx.Label(periodText)
			tx.Label(heardText)
			tx.Button("Reset", func(tx *kaya.Tx) {
				tx.Write(period, 0.0)
				tx.Write(periodText, "period: Day")
			}).A11yID("reset")
			tx.SegmentedSymbols(views, 1, func(tx *kaya.Tx, index int) {
				tx.Write(viewText, "view: "+views[index].Name)
			}).A11yID("view").A11yLabel("View")
			tx.Label(viewText)
			tx.Label(cadenceText)
			for row := range HabitRows(tx, habits).All() {
				row.Label(row.Name())
				cadence := row.Segmented(cadences, row.Cadence(), func(tx *kaya.Tx, key string, index int) {
					tx.Write(cadenceText, fmt.Sprintf("cadence %s: %s", key, cadences[index]))
				})
				row.SetA11yID(cadence, "cadence")
			}
		}))

		habits.Insert(tx, "read", Habit{Name: "read", Cadence: 1.0})
		habits.Insert(tx, "walk", Habit{Name: "walk", Cadence: 0.0})
	})

	return app
}
