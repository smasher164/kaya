// The shapes scene (tools/scenes/shapes.steps; docs/styling-pass-plan.md
// Y6): one picture clipped three ways, a wider one in a circle, and a stamped
// avatar that is round while it loads.
package shapes

import kaya "dev.kaya/bindings/go"

//go:generate go run dev.kaya/cmd/kaya-gen -type Person -key string
type Person struct {
	Name  string
	Face  []byte
	Phase kaya.ImagePhase
}

func App() *kaya.App {
	app := kaya.NewApp()
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("shapes").Size(420, 360)
		cover := tx.Asset("covers/cover-600.jpg")
		art := cover.Bytes()
		cover.Close()
		wide := tx.Asset("images/photo.jpg")
		photo := wide.Bytes()
		wide.Close()
		people := PersonCollection(tx)
		tx.Mount(tx.Column(func() {
			tx.Row(func() {
				for _, s := range []struct {
					id    string
					shape kaya.Shape
				}{{"rect", kaya.ShapeRect}, {"rounded", kaya.ShapeRounded}, {"circle", kaya.ShapeCircle}} {
					tx.Image(art).MaxWidth(48).MaxHeight(48).Fit(kaya.FitCover).Shape(s.shape).A11yID(s.id)
				}
				tx.Image(photo).MaxWidth(48).MaxHeight(48).Shape(kaya.ShapeCircle).A11yID("wide")
			}).Spacing(16)
			for row := range PersonRows(tx, people).All() {
				row.Row(func() {
					face := row.Image(row.Face())
					row.SetFit(face, kaya.FitCover)
					row.SetMaxWidth(face, 48)
					row.SetMaxHeight(face, 48)
					row.BindPhase(face, row.Phase())
					row.SetShape(face, kaya.ShapeCircle)
					row.SetA11yID(face, "avatar")
					row.Label(row.Name())
				})
			}
		}).Spacing(16))
		people.Insert(tx, "a1", Person{Name: "Ada", Face: []byte{}, Phase: kaya.ImagePhaseLoading})
	})
	return app
}
