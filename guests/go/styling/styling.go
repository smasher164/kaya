// The styling conformance scene (tools/scenes/styling.steps): brand
// accent, role tier, window inset.
package styling

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		// BEFORE THE FIRST MOUNT, per the set-once wall.
		tx.BrandAccent(0x3584E4)
		tx.Window(0).Title("styling").Size(480, 360).Inset(0)

		heading := tx.Signal("Sections")
		status = tx.Signal("ready")

		tx.Mount(tx.Column(func() {
			// expect_ax resolves a target through its AUTHORED id.
			tx.Heading(heading).A11yID("title") // label#0
			tx.Label(status)                                         // label#1
			tx.Button("Delete", func(tx *kaya.Tx) {                  // button#0
				tx.Write(status, "deleted")
			}).Role(kaya.RoleDestructive).A11yID("delete")
			tx.Button("Save", func(tx *kaya.Tx) { // button#1
				tx.Write(status, "saved")
			}).Role(kaya.RoleProminent).A11yID("save")
			// Declared so every backend's caption arm runs: no AX observable.
			tx.CaptionText("captioned") // label#2
		}))
	})

	return app
}
