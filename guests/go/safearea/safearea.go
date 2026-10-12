// The safe-area scene (tools/scenes/safearea.steps; docs/safe-area-plan.md
// A3, A8).
package safearea

import (
	kaya "dev.kaya/bindings/go"
)

var ground = kaya.Viewbox{W: 300, H: 200}

func drawGround(d *kaya.Draw, size kaya.Viewbox) {
	d.MoveTo(0, 0).
		LineTo(size.W, 0).
		LineTo(size.W, size.H).
		LineTo(0, size.H).
		Close().
		Fill(kaya.PaintSeriesFill, kaya.FillRuleNonzero)
}

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("safearea").Size(420, 640)
		caption := tx.Signal("inset 16")
		photo := tx.Asset("images/photo.jpg")

		tx.Mount(tx.Column(func() {
			tx.ImageAsset(photo).MaxHeight(160).Bleed().A11yID("picture").A11yLabel("Photo")
			tx.Label(caption).A11yID("caption")
			tx.Button("No inset", func(tx *kaya.Tx) {
				tx.Window(0).Inset(0)
				tx.Write(caption, "inset 0")
			}).A11yID("inset")
			tx.Button("Fullscreen", func(tx *kaya.Tx) {
				tx.Window(0).Fullscreen(true)
				tx.Write(caption, "fullscreen")
			}).A11yID("full")
			tx.Canvas(ground).Grow(1).Bleed().A11yID("ground").A11yLabel("Ground").
				OnDraw(drawGround)
		}))
	})

	return app
}
