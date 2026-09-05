// The tooltips scene (tools/scenes/tooltips.steps; docs/tooltip-plan.md).
package tooltips

import (
	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Account -key string
type Account struct {
	Name string
	Note string
}

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		nameHelp := tx.Signal("Your full name as it appears on the card")
		accounts := AccountCollection(tx)

		tx.Mount(tx.Column(func() {
			tx.Button("Save", func(tx *kaya.Tx) {
				tx.Write(nameHelp, "Your name, as saved")
			}).Help("Saves the draft to disk").A11yID("save") // button#0
			tx.Button("Discard", nil).
				Help("Throws the draft away").
				A11yHint("discard every change").
				A11yID("discard") // button#1
			tx.Entry(nil).BindHelp(nameHelp).A11yID("fullname") // entry#0
			tx.Slider(0.0, 1.0, 0.5, nil).
				Help("How loud the preview plays").
				A11yID("volume") // slider#0
			for row := range AccountRows(tx, accounts).All() {
				name := row.Label(row.Name())
				row.Help(name, row.Note())
				row.A11yID(name, row.Name())
			}
		}).Help("The settings for this account").A11yID("settings")) // column#0

		accounts.Insert(tx, "a", Account{Name: "a", Note: "The first account, opened in March"})
		accounts.Insert(tx, "b", Account{Name: "b", Note: "The second account, opened in May"})
	})

	return app
}
