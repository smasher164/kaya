// The styling conformance scene from Go (docs/styling-plan.md, slice
// 1): the brand accent, the role tier and the window inset, together
// because they are one design — brand slots fill each platform's token
// system, roles say what a widget MEANS, and the inset is the one
// layout knob the pass admitted (D3).
//
// What each piece demonstrates:
//   - BrandAccent(0x3584E4) — Adwaita blue, the derivation's empirical
//     anchor: one hex is the whole call, the core derives fills and
//     foregrounds, and a platform may let its user override the result
//     (D2). The per-appearance form is kaya.LightAccent/kaya.DarkAccent
//     beside the seed; this scene wants neither, which is the point —
//     one hex in, a correct two-appearance result out.
//   - Role(kaya.RoleHeading) on the title label — the platform's
//     heading text style AND the assistive heading trait, which is the
//     one role the steps freeze from the real tree on every lane.
//   - Role(kaya.RoleDestructive) / Role(kaya.RoleProminent) on the two
//     buttons — the platform's own emphasis chrome, and (the scene's
//     point) NO change to what pressing them does.
//   - Inset(0) — full bleed, the editor's own need, honored
//     unconditionally because the inset is kaya's padding (D3).
//
// See guests/rust/styling.rs; the byte-frozen contract is
// tools/scenes/styling.steps.
package styling

import (
	kaya "dev.kaya/bindings/go"
)

// App builds the scene and hands it back ready to be served.
//
// THE TAIL IS THE ONLY THING THAT DIFFERS BY PLATFORM, and it differs
// because the hosting does: a desktop or iOS guest owns the process
// main thread and lends it to kaya (guests/go/cmd/main_desktop.go),
// while on Android the OS owns main and kaya starts the guest on a
// thread of its own (guests/go/cmd/main_android.go). Both tails are
// one package over one scene table, so everything above them — the
// transaction, the handlers, the strings — is compiled into every
// platform's artifact from these bytes.
func App() *kaya.App {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		// BEFORE THE FIRST MOUNT, per the set-once wall: brand is
		// identity, not state.
		tx.BrandAccent(0x3584E4)
		tx.Window(0).Title("styling").Size(480, 360).Inset(0)

		heading := tx.Signal("Sections")
		status = tx.Signal("ready")

		tx.Mount(tx.Column(func() {
			// expect_ax resolves a target through its AUTHORED id into
			// the real tree, so everything the steps read back is
			// identified (the a11y scene's discipline).
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
