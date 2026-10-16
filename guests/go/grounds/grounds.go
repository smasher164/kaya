// The grounds scene (tools/scenes/grounds.steps; docs/styling-pass-plan.md
// Y2, Y3): an album header fading from the art's own colour into the page, an
// artist header covered by the picture with the name on the platform's panel,
// and a column with no ground.
package grounds

import kaya "dev.kaya/bindings/go"

func App() *kaya.App {
	app := kaya.NewApp()
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("grounds").Size(480, 560)
		a := tx.Asset("covers/cover-600.jpg")
		art := a.Bytes()
		a.Close()
		colour, ok := kaya.ImageDominant(art)
		if !ok {
			panic("the cover decodes")
		}
		tx.Mount(tx.Column(func() {
			tx.Column(func() {
				tx.HeadingText("Kind of Blue").A11yID("title")
				tx.CaptionText("Miles Davis · 1959")
			}).Inset(24).GroundGradient(colour).A11yID("header")
			tx.Column(func() {
				tx.Row(func() {
					tx.LabelText("Miles Davis")
				}).Filled(kaya.TintOverlay).A11yID("scrim")
			}).Inset(24).GroundImage(art).A11yID("hero")
			tx.Column(func() {
				tx.LabelText("Plain")
			}).Inset(24).A11yID("plain")
		}).Spacing(12))
	})
	return app
}
