// The typeface conformance scene from Go (docs/styling-plan.md slice
// 2b): the brand typeface swaps the FAMILY and leaves the platform's
// ramp alone. The scene names NO SIZE anywhere. The bundled-font
// reasoning is guests/rust/typeface.rs; the byte-frozen contract is
// tools/scenes/typeface.steps.
//
// THE FONT IS AN ASSET NOW (docs/assets-plan.md, ratified 2026-08-18).
// This scene used to resolve the file itself — kaya.Env("KAYA_FONT_FILE")
// with a repo-relative default, os.ReadFile, and a panic in its own
// words — as its seven siblings each did in their own language.
// tx.Asset(name) is the whole thing now: where the file lives is the
// core's knowledge, and the failure sentence has one author. The
// kaya.Env-not-os.Getenv rule this file used to carry is not merely
// obeyed here any more, it is unreachable: the scene reads no
// environment at all.
package typeface

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	draft := ""

	app.Build(func(tx *kaya.Tx) {
		// Set BEFORE THE FIRST MOUNT, per the set-once wall. The
		// asset's bytes go from the core's read straight to the
		// platform's font API.
		font := tx.Asset("fonts/sora-wght.ttf")
		defer font.Close()
		tx.BrandTypeface("Sora", kaya.FontAsset(font))
		tx.Window(0).Title("typeface").Size(480, 360)

		heading := tx.Signal("typeface")
		status = tx.Signal("ready")

		tx.Mount(tx.Column(func() {
			tx.Label(heading).Role(kaya.RoleHeading).A11yID("title") // label#0
			tx.Label(status)                                         // label#1
			// A field AND a textarea: they take the swap by DIFFERENT
			// routes, so one alone could not tell a half-applied
			// lowering from a whole one.
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
