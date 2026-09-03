// The typeface conformance scene (tools/scenes/typeface.steps): the FAMILY
// swaps and the scene names NO SIZE anywhere.
package typeface

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	draft := ""

	app.Build(func(tx *kaya.Tx) {
		// Set BEFORE THE FIRST MOUNT, per the set-once wall.
		font := tx.Asset("fonts/sora-wght.ttf")
		defer font.Close()
		tx.BrandTypeface("Sora", kaya.FontAsset(font))
		tx.Window(0).Title("typeface").Size(480, 360)

		heading := tx.Signal("typeface")
		status = tx.Signal("ready")

		tx.Mount(tx.Column(func() {
			tx.Label(heading).Role(kaya.RoleHeading).A11yID("title") // label#0
			tx.Label(status)                                         // label#1
			// Two DIFFERENT routes: one alone cannot see a half-applied swap.
			tx.Entry(func(tx *kaya.Tx, text string) { // entry#0
				draft = text
			})
			tx.Textarea(nil)                    // textarea#0
			tx.Button("Go", func(tx *kaya.Tx) { // button#0
				tx.Write(status, "clicked "+draft)
			})
		}))
	})

	return app
}
