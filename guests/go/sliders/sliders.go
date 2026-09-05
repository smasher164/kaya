// The sliders scene (tools/scenes/sliders.steps; docs/slider-plan.md).
package sliders

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Track -key string
type Track struct {
	Name  string
	Level float64
}

// spelled is the harness's own slider spelling (crates/kaya/src/harness.rs).
func spelled(v float64) string {
	s := strings.TrimRight(fmt.Sprintf("%.6f", v), "0")
	return strings.TrimSuffix(s, ".")
}

func App() *kaya.App {
	app := kaya.NewApp()
	commits := 0

	app.Build(func(tx *kaya.Tx) {
		levelText := tx.Signal("value: 50")
		commitText := tx.Signal("commits: 0")
		volumeText := tx.Signal("volume: 0.5")
		rowText := tx.Signal("row: none")
		pos := tx.Signal(50.0)
		tracks := TrackCollection(tx)
		var level kaya.Node

		tx.Mount(tx.Column(func() {
			tx.Label(levelText)  // label#0
			tx.Label(commitText) // label#1
			tx.Label(volumeText) // label#2
			tx.Label(rowText)    // label#3
			master := tx.SliderBound(0.0, 100.0, pos, func(tx *kaya.Tx, v float64) {
				tx.Write(levelText, fmt.Sprintf("value: %s", spelled(v)))
			}).Step(5).TickSpacing(25).A11yID("master").A11yLabel("Level") // slider#0
			app.OnValueCommitted(master, func(tx *kaya.Tx, _ float64) {
				commits++
				tx.Write(commitText, fmt.Sprintf("commits: %d", commits))
			})
			tx.Slider(0.0, 1.0, 0.5, func(tx *kaya.Tx, v float64) {
				tx.Write(volumeText, fmt.Sprintf("volume: %s", spelled(v)))
			}).TickSpacing(0.25).A11yLabel("Volume") // slider#1
			tx.Button("reset", func(tx *kaya.Tx) {
				// Must NOT come back as a value or a commit occurrence.
				tx.Write(pos, 25.0)
			}) // button#0
			for row := range TrackRows(tx, tracks).All() {
				row.Label(row.Name())
				level = row.Slider(0.0, 100.0, row.Level(), nil)
				row.SetStep(level, 10)
				row.SetA11yID(level, "level")
			}
		}))

		app.OnValueCommittedNode(level, func(tx *kaya.Tx, keys []any, v float64) {
			tx.Write(rowText, fmt.Sprintf("row %v: %s", keys[0], spelled(v)))
		})

		tracks.Insert(tx, "a", Track{Name: "a", Level: 70.0})
		tracks.Insert(tx, "b", Track{Name: "b", Level: 20.0})
	})

	return app
}
