// The a11y conformance scene (tools/scenes/a11y.steps). Keep exactly ONE
// container of each kind: container targets are ordinal.
package a11y

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Mount(tx.Column(func() {
			// Deliberately NOT labelled: the platform speaks the caption.
			tx.Button("Save", nil).A11yID("save").A11yHint("save the draft")
			tx.Checkbox("Details", nil).A11yID("details").A11yHint("show more detail")
			tx.Button("Reset", nil).A11yID("reset")
			tx.LabelText("Ready").A11yID("status")
			tx.Entry(nil).A11yID("name").A11yLabel("Full name")
			tx.Textarea(nil).A11yID("notes").A11yLabel("Notes")
			tx.Slider(0.0, 1.0, 0.5, nil).A11yID("volume").A11yLabel("Volume")
			tx.Progress(0.25).A11yID("loading").A11yLabel("Loading")
			logo := tx.Asset("images/a11y-logo.png")
			tx.ImageAsset(logo).A11yID("logo").A11yLabel("Logo")
			tx.Select([]string{"Red", "Green"}, 0, nil).
				A11yID("color").A11yLabel("Color")
			tx.Radio([]string{"Small", "Large"}, 0, nil).
				A11yID("size").A11yLabel("Size")
			tx.Grid(2, func() {
				tx.LabelText("Name")
				tx.LabelText("Ada")
			}).A11yID("cells").A11yLabel("Cells")
			tx.Scroll(func() {
				tx.LabelText("Item")
			}).A11yID("feed").A11yLabel("Feed")
			tx.Row(func() {
				tx.Button("Cancel", nil).A11yID("cancel")
				tx.Button("OK", nil).A11yID("ok")
			}).A11yID("actions").A11yLabel("Actions")
			spoken := tx.Signal("Before")
			tx.LabelText("Spoken").A11yID("spoken").BindA11yLabel(spoken)
			tx.Button("Rename", func(tx *kaya.Tx) {
				tx.Write(spoken, "After")
			}).A11yID("rename")
		}).A11yID("form").A11yLabel("Form"))
	})

	return app
}
