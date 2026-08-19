// The styling conformance scene from Go (docs/styling-plan.md slice 1):
// the brand accent, the role tier and the window inset together,
// because they are one design. One hex is the whole accent call and the
// core derives fills and foregrounds from it, which a platform may let
// its user override (D2); Role says what a widget MEANS and changes
// nothing about what pressing it does; Inset(0) is the full bleed (D3).
// See guests/rust/styling.rs and tools/scenes/styling.steps.
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
			// expect_ax resolves a target through its AUTHORED id into
			// the real tree.
			tx.Label(heading).Role(kaya.RoleHeading).A11yID("title") // label#0
			tx.Label(status)                                         // label#1
			tx.Button("Delete", func(tx *kaya.Tx) {                  // button#0
				tx.Write(status, "deleted")
			}).Role(kaya.RoleDestructive).A11yID("delete")
			tx.Button("Save", func(tx *kaya.Tx) { // button#1
				tx.Write(status, "saved")
			}).Role(kaya.RoleProminent).A11yID("save")
		}))
	})

	return app
}
