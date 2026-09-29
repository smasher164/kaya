// The colour picker scene (tools/scenes/colorpicker.steps;
// docs/color-picker-plan.md §5).
package colorpicker

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Swatch -key string
type Swatch struct {
	Name string
	Fill kaya.Color
}

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		titleText := tx.Signal("color: none")
		glazeText := tx.Signal("alpha: none")
		rowText := tx.Signal("row: none")
		titleColor := tx.Signal(kaya.ColorHex(0x336699FF))
		swatches := SwatchCollection(tx)

		tx.Mount(tx.Column(func() {
			tx.Label(titleText)
			tx.Label(glazeText)
			tx.Label(rowText)
			tx.ColorPickerBound(titleColor, func(tx *kaya.Tx, picked kaya.Color) {
				tx.Write(titleText, fmt.Sprintf("color: %v", picked))
			}).A11yLabel("Title colour").A11yID("title")
			tx.ColorPicker(kaya.ColorHex(0x26A269FF), func(tx *kaya.Tx, picked kaya.Color) {
				tx.Write(glazeText, fmt.Sprintf("alpha: %v", picked))
			}).Alpha(true).A11yLabel("Glaze")
			tx.Button("reset", func(tx *kaya.Tx) {
				// Must NOT come back as a Title occurrence.
				tx.Write(titleColor, kaya.ColorHex(0x3584E4FF))
			})
			for row := range SwatchRows(tx, swatches).All() {
				row.Label(row.Name())
				fill := row.ColorPicker(row.Fill(), func(tx *kaya.Tx, key string, picked kaya.Color) {
					tx.Write(rowText, fmt.Sprintf("row %s: %v", key, picked))
				})
				row.SetA11yID(fill, "fill")
			}
		}))

		swatches.Insert(tx, "a", Swatch{Name: "a", Fill: kaya.ColorHex(0xE66100FF)})
		swatches.Insert(tx, "b", Swatch{Name: "b", Fill: kaya.ColorHex(0xF6D32DFF)})
	})

	return app
}
