// The dock scene (tools/scenes/dock.steps; docs/styling-pass-plan.md Y8): a
// window with a now-playing bar docked under its content, gone while nothing
// plays because the dock's root then holds no widget.
package dock

import kaya "dev.kaya/bindings/go"

func App() *kaya.App {
	app := kaya.NewApp()
	app.Build(func(tx *kaya.Tx) {
		a := tx.Asset("covers/cover-600.jpg")
		art := a.Bytes()
		a.Close()
		playing := tx.Signal(true)
		tx.Window(0).Title("dock").Size(720, 480).Dock(40, func() kaya.Widget {
			return tx.Column(func() {
				tx.When(playing, func(t *kaya.Tpl) {
					bar := t.Row(func() {
						image := t.Image(art)
						t.SetFit(image, kaya.FitCover)
						t.SetMaxWidth(image, 40)
						t.SetMaxHeight(image, 40)
						t.SetShape(image, kaya.ShapeRounded)
						t.Column(func() {
							t.LabelText("Blue in Green")
							t.CaptionText("Miles Davis")
						})
						progress := t.Slider(0, 1, 0.4)
						t.SetA11yID(progress, "progress")
						pause := t.Button("Pause")
						t.SetA11yID(pause, "pause")
					})
					t.SetA11yID(bar, "bar")
				})
			})
		})
		tx.Mount(tx.Column(func() {
			tx.LabelText("Library")
			tx.Button("stop", func(tx *kaya.Tx) { tx.Write(playing, false) }).A11yID("stop")
			tx.Button("play", func(tx *kaya.Tx) { tx.Write(playing, true) }).A11yID("play")
		}))
	})
	return app
}
