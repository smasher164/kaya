// The typeface conformance scene from Go (docs/styling-plan.md slice
// 2b): the brand typeface swaps the FAMILY and leaves the platform's
// ramp alone. The scene names NO SIZE anywhere. The bundled-font
// reasoning is guests/rust/typeface.rs; the byte-frozen contract is
// tools/scenes/typeface.steps.
package typeface

import (
	"fmt"
	"os"

	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	draft := ""

	app.Build(func(tx *kaya.Tx) {
		// Set BEFORE THE FIRST MOUNT, per the set-once wall. kaya.Env
		// and never os.Getenv — tools/check-go-env.sh.
		fontPath := kaya.Env("KAYA_FONT_FILE")
		if fontPath == "" {
			fontPath = "guests/assets/fonts/sora-wght.ttf"
		}
		font, err := os.ReadFile(fontPath)
		if err != nil {
			panic(fmt.Sprintf(
				"kaya: the typeface scene needs the vendored font at %s "+
					"(set KAYA_FONT_FILE or run from the repo root): %v",
				fontPath, err))
		}
		tx.BrandTypeface("Sora", kaya.FontBytes(font))
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
