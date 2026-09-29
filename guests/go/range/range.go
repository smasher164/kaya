// The range scene (tools/scenes/range.steps; docs/range-plan.md §5).
package rangescene // `range` is a keyword; select's spelling

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Clip -key string
type Clip struct {
	Name    string
	TrimIn  float64
	TrimOut float64
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
		liveText := tx.Signal("live: 2 8")
		commitText := tx.Signal("commits: 0")
		volumeText := tx.Signal("volume: 0.25")
		clipText := tx.Signal("clip: none")
		low := tx.Signal(2.0)
		high := tx.Signal(8.0)
		clips := ClipCollection(tx)
		var clip kaya.Node

		tx.Mount(tx.Column(func() {
			tx.Label(liveText)   // label#0
			tx.Label(commitText) // label#1
			tx.Label(volumeText) // label#2
			tx.Label(clipText)   // label#3
			tx.RangeBound(0.0, 10.0, low, high, func(tx *kaya.Tx, low, high float64) {
				tx.Write(liveText, fmt.Sprintf("live: %s %s", spelled(low), spelled(high)))
			}).Step(0.5).TickSpacing(1).MinGap(1).A11yLabel("Trim").
				LowLabel("In").HighLabel("Out").A11yID("trim"). // range#0
				OnRangeCommitted(func(tx *kaya.Tx, low, high float64) {
					commits++
					tx.Write(commitText, fmt.Sprintf("commits: %d at %s %s", commits, spelled(low), spelled(high)))
				})
			tx.Slider(0.0, 10.0, 5.0, nil).A11yLabel("Playhead") // slider#0
			tx.Slider(0.0, 1.0, 0.25, func(tx *kaya.Tx, v float64) {
				tx.Write(volumeText, fmt.Sprintf("volume: %s", spelled(v)))
			}).Step(0.25).Axis(kaya.AxisVertical).A11yLabel("Volume").A11yID("volume") // slider#1
			tx.Button("reset", func(tx *kaya.Tx) {
				// Must NOT come back as a move or a commit.
				tx.Write(low, 1.0)
			}) // button#0
			tx.Button("late", func(tx *kaya.Tx) {
				// Crosses a high thumb the user moved; the core clamps it (docs/range-plan.md §3).
				tx.Write(low, 6.0)
			}) // button#1
			for row := range ClipRows(tx, clips).All() {
				row.Label(row.Name())
				clip = row.Range(0.0, 10.0, row.TrimIn(), row.TrimOut(), nil)
				row.SetStep(clip, 0.5)
				row.SetMinGap(clip, 1)
				row.SetA11yID(clip, "clip")
			}
		}))

		clip.OnRangeCommitted(func(tx *kaya.Tx, keys []any, low, high float64) {
			tx.Write(clipText, fmt.Sprintf("clip %v: %s %s", keys[0], spelled(low), spelled(high)))
		})

		clips.Insert(tx, "a", Clip{Name: "a", TrimIn: 1.0, TrimOut: 4.0})
		clips.Insert(tx, "b", Clip{Name: "b", TrimIn: 3.0, TrimOut: 7.0})
	})

	return app
}
