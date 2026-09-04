// The pickers scene (tools/scenes/pickers.steps; docs/datetime-plan.md).
package pickers

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Task -key string
type Task struct {
	Name string
	Due  kaya.Date
}

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		dateText := tx.Signal("date: none")
		timeText := tx.Signal("time: none")
		rowText := tx.Signal("row: none")
		dateSig := tx.Signal(kaya.Date{Year: 2026, Month: 9, Day: 4})
		timeSig := tx.Signal(kaya.Time{Hour: 14, Minute: 30})
		tasks := TaskCollection(tx)

		tx.Mount(tx.Column(func() {
			tx.Label(dateText) // label#0
			tx.Label(timeText) // label#1
			tx.Label(rowText)  // label#2
			tx.DatePickerBound(dateSig, func(tx *kaya.Tx, picked kaya.Date) {
				tx.Write(dateText, fmt.Sprintf("date: %v", picked))
			}).
				MinDate(kaya.Date{Year: 2026, Month: 1, Day: 1}).
				MaxDate(kaya.Date{Year: 2026, Month: 12, Day: 31}).
				A11yID("when").A11yLabel("Due") // date_picker#0
			tx.TimePickerBound(timeSig, func(tx *kaya.Tx, picked kaya.Time) {
				tx.Write(timeText, fmt.Sprintf("time: %v", picked))
			}).MinuteStep(15).A11yID("at").A11yLabel("At") // time_picker#0
			tx.Button("reset", func(tx *kaya.Tx) {
				tx.Write(dateSig, kaya.Date{Year: 2026, Month: 3, Day: 1})
				tx.Write(timeSig, kaya.Time{Hour: 9, Minute: 0})
			}) // button#0
			for row := range TaskRows(tx, tasks).All() {
				row.Label(row.Name())
				picker := row.DatePicker(row.Due(),
					func(tx *kaya.Tx, key string, picked kaya.Date) {
						tx.Write(rowText, fmt.Sprintf("row %s: %v", key, picked))
					})
				row.SetA11yID(picker, "due")
			}
		}))

		tasks.Insert(tx, "a", Task{Name: "a", Due: kaya.Date{Year: 2026, Month: 10, Day: 1}})
		tasks.Insert(tx, "b", Task{Name: "b", Due: kaya.Date{Year: 2026, Month: 11, Day: 20}})
	})

	return app
}
