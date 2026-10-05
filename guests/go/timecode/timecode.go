package timecode

import (
	kaya "dev.kaya/bindings/go"
	"fmt"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Line -key string
type Line struct{ Qty float64 }

func App() *kaya.App {
	app := kaya.NewApp()
	normal := kaya.TimecodeRate{Numerator: 25, Denominator: 1}
	drop := kaya.TimecodeRate{Numerator: 30000, Denominator: 1001, Drop: true}
	commits := 0
	phase := 0
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("Timecode").Size(440, 500)
		status := tx.Signal("commits: 0")
		rowStatus := tx.Signal("row: none")
		playhead := tx.Signal(kaya.FormatTimecode(93087, normal))
		rows := LineCollection(tx)
		switchValue := tx.Signal(-2.0)
		committed := func(tx *kaya.Tx, frames float64) {
			commits++
			tx.Write(status, fmt.Sprintf("commits: %d", commits))
			tx.Write(playhead, kaya.FormatTimecode(int64(frames), normal))
		}
		tx.Mount(tx.Column(func() {
			tx.LabelText("25 fps")
			tx.Label(playhead).A11yID("playhead")
			tx.NumberField(93087, committed).Format(kaya.Timecode(normal)).A11yID("position").A11yLabel("Position")
			tx.Label(status).A11yID("commits")
			tx.LabelText("29.97 drop-frame")
			tx.NumberField(1799, committed).Format(kaya.Timecode(drop)).A11yID("drop").A11yLabel("Drop frame")
			tx.Entry(nil).A11yID("note")
			for row := range LineRows(tx, rows).All() {
				field := row.NumberField(row.Qty(), func(tx *kaya.Tx, key string, frames float64) {
					tx.Write(rowStatus, fmt.Sprintf("row %s: %g", key, frames))
				})
				row.SetFormat(field, kaya.Timecode(normal))
				row.SetA11yID(field, "rowtime")
			}
			tx.Label(rowStatus).A11yID("row")
			switching := tx.NumberFieldBound(switchValue, nil).A11yID("switching")
			tx.Button("Switch format", func(tx *kaya.Tx) {
				switch phase {
				case 0:
					tx.SetFormat(switching, kaya.Timecode(drop))
					tx.Write(switchValue, 1800.0)
				case 1:
					tx.Write(switchValue, -2.0)
					tx.SetFormat(switching, kaya.Number())
				case 2:
					tx.Write(switchValue, 1800.0)
					tx.SetFormat(switching, kaya.Timecode(drop))
				default:
					tx.SetFormat(switching, kaya.Number())
					tx.Write(switchValue, -2.0)
				}
				phase = (phase + 1) % 4
			}).A11yID("switchformat")
		}))
		rows.Insert(tx, "a", Line{Qty: 25})
	})
	return app
}
