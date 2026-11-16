// The layers scene (tools/scenes/layers.steps; docs/layering-plan.md LY13): a
// cover with a badge, a caption on the fade form and a button over it; a
// button with a badge at its trailing end; a button under a veil, an unfilled
// column spanning it with a panel at its centre, that takes its taps until it
// is hidden; a cover with the flat overlay panel; and the log of which handler
// answered each tap. See guests/rust/layers.rs.
package layers

import (
	"strings"

	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()
	log := []string{"taps:"}
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("layers").Size(480, 860)
		answered := tx.Signal("taps:")
		veiled := tx.Signal(false)
		answer := func(word string) func(*kaya.Tx) {
			return func(tx *kaya.Tx) {
				log = append(log, word)
				tx.Write(answered, strings.Join(log, " "))
				if word == "hide" {
					tx.Write(veiled, true)
				}
			}
		}
		cover := tx.Asset("covers/cover-600.jpg")
		small := tx.Asset("covers/cover-320.jpg")
		tx.Mount(tx.Column(func() {
			tx.Layers(func() {
				tx.ImageAsset(cover).MaxWidth(320).A11yLabel("Kind of Blue cover").A11yID("photo")
				tx.Row(func() {
					tx.LabelText("3").A11yID("badge_text")
				}).Filled(kaya.TintAccent).Place(kaya.PlaceTopTrailing).A11yID("badge")
				tx.Row(func() {
					tx.LabelText("Kind of Blue").A11yID("caption_text")
				}).Filled(kaya.TintOverlayFade).Place(kaya.PlaceBottom).A11yID("caption")
				tx.Button("Share", answer("share")).Place(kaya.PlaceBottomTrailing).A11yID("share")
			}).Inset(8).A11yID("photostack")
			tx.Layers(func() {
				tx.Button("Press the base button here", answer("base")).A11yID("base")
				tx.Column(func() {
					tx.Row(func() {
						tx.LabelText("Busy")
					}).Filled(kaya.TintOverlay)
				}).Align(kaya.AlignCenter).Fill(true).BindHidden(veiled).A11yID("busy")
			}).A11yID("veilstack")
			tx.Layers(func() {
				tx.Button("Open the inbox", answer("side")).A11yID("side")
				tx.Row(func() {
					tx.LabelText("5")
				}).Filled(kaya.TintAccent).Place(kaya.PlaceTrailing).A11yID("sidebadge")
			}).A11yID("sidestack")
			tx.Layers(func() {
				tx.ImageAsset(small).MaxWidth(200).A11yLabel("Small cover").A11yID("smallphoto")
				tx.Row(func() {
					tx.LabelText("Flat panel").A11yID("flat_text")
				}).Filled(kaya.TintOverlay).Place(kaya.PlaceTopLeading).A11yID("flat")
			}).Inset(8).A11yID("flatstack")
			tx.Label(answered).A11yID("answered")
			tx.Button("Hide the veil", answer("hide")).A11yID("hideveil")
		}).Spacing(16))
	})
	return app
}
