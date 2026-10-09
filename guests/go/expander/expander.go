// The expander scene (tools/scenes/expander.steps; docs/expander-plan.md §5).
package expander

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Section -key string
type Section struct {
	Name string
	Open bool
}

func word(open bool) string {
	if open {
		return "open"
	}
	return "closed"
}

func App() *kaya.App {
	app := kaya.NewApp()
	heard := 0
	opens := map[string]bool{"s01": true}

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("expander").Size(520, 860)
		state := tx.Signal("details: closed")
		heardText := tx.Signal("heard: 0")
		typed := tx.Signal("name: -")
		rowsText := tx.Signal("rows: -")
		inside := tx.Signal("Inside the body")
		sections := SectionCollection(tx)

		tx.Mount(tx.Column(func() {
			var details kaya.Widget
			details = tx.ExpanderText("Details", func() {
				tx.Entry(func(tx *kaya.Tx, text string) {
					tx.Write(typed, "name: "+text)
				}).Placeholder("Name").A11yID("name")
				tx.Label(inside).A11yID("inside")
			}).Summary("One field").Symbol(kaya.SymbolInfo).A11yID("details").
				OnToggle(func(tx *kaya.Tx, open bool) {
					heard++
					tx.Write(state, "details: "+word(open))
					tx.Write(heardText, fmt.Sprintf("heard: %d", heard))
				})
			tx.Label(state).A11yID("state")
			tx.Label(heardText).A11yID("heard")
			tx.Label(typed).A11yID("typed")
			show := func(open bool) func(*kaya.Tx) {
				return func(tx *kaya.Tx) {
					tx.SetExpanded(details, open)
					tx.Write(state, "details: "+word(open))
				}
			}
			tx.Row(func() {
				tx.Button("Show", show(true)).A11yID("show")
				tx.Button("Hide", show(false)).A11yID("hide")
			})
			tx.Column(func() {
				tx.LabeledText("Sort", func() {
					tx.Select([]string{"Due", "Name"}, 0, nil).A11yID("sort")
				})
				tx.ExpanderText("Advanced", func() {
					tx.LabeledText("Hide badge", func() {
						tx.Checkbox("", nil).A11yID("badge")
					})
					tx.LabeledText("Keep completed", func() {
						tx.Checkbox("", nil).A11yID("keep")
					})
				}).A11yID("advanced")
			}).A11yID("form")
			tx.Label(rowsText).A11yID("rows")
			tx.Button("Rebuild", func(tx *kaya.Tx) {
				sections.Remove(tx, "s00")
				sections.Insert(tx, "s00", Section{Name: "Section 0", Open: opens["s00"]})
				tx.Write(rowsText, "rebuilt s00")
			}).A11yID("rebuild")
			tx.Column(func() {
				for row := range SectionRows(tx, sections).All() {
					node := row.Expander(row.Name(), row.Open(), func(tx *kaya.Tx, key string, open bool) {
						opens[key] = open
						SectionPatch(sections, tx, key).Open(open)
						tx.Write(rowsText, fmt.Sprintf("sec %s: %s", key, word(open)))
					}, func() {
						row.Label(row.Name())
					})
					row.SetA11yID(node, "sec")
				}
			})
		}))

		for i := 0; i < 3; i++ {
			sections.Insert(tx, fmt.Sprintf("s%02d", i), Section{Name: fmt.Sprintf("Section %d", i), Open: i == 1})
		}
	})

	return app
}
