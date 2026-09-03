// The app-identity conformance scene, Go port: an app declares what it
// is called and what it looks like, and the platform shows both. The
// canonical semantics is guests/rust/identity.rs; the byte-frozen
// contract is tools/scenes/identity.steps.
//
// THE MARK IS THE VENDORED ONE (four flat quadrants) because no
// platform's own default icon can land on four declared colours, so a
// lowering that never applied can never read as a pass.
//
// THE SECOND WINDOW HAS NO TITLE OF ITS OWN, deliberately: that is the
// blank an app's NAME fills on every platform.
package identity

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	draft := ""

	app.Build(func(tx *kaya.Tx) {
		// BEFORE THE FIRST MOUNT, per the declared-once wall. The
		// asset's bytes go from the core's read straight to the
		// platform's icon sink: this scene never holds them.
		icon := tx.Asset("icons/kaya-mark.png")
		defer icon.Close()
		tx.AppIdentityAsset("Aurora Notes", icon)
		tx.Window(0).Title("identity").Size(480, 360)
		// ONE PROMOTED COMMAND, AND IT IS NOT ABOUT COMMANDS. Windows
		// mints its custom caption from the first promotion and from
		// nothing else, and a custom caption REPLACES the system one —
		// taking the system-drawn app icon with it. A scene with no
		// promotion anywhere would leave that sink's arm unreached.
		tx.Window(0).Menu("File").Item("Save").
			Symbol(kaya.SymbolDone).Primary(true)

		heading := tx.Signal("identity")
		status = tx.Signal("ready")

		tx.Mount(tx.Column(func() {
			tx.Label(heading) // label#0
			tx.Label(status)  // label#1
			tx.Entry(func(tx *kaya.Tx, text string) { // entry#0
				draft = text
			})
			tx.Button("Go", func(tx *kaya.Tx) { // button#0
				tx.Write(status, "clicked "+draft)
			})
		}))

		// THE UNTITLED WINDOW. It declares no title at all rather than
		// an empty one: an empty string is a title an app WROTE, and
		// the rule under test is what a window with nothing written
		// shows.
		//
		// THE HOST IS ASKED, not the platform: kaya.Capabilities() reads
		// the core's own word (crates/kaya/src/scene.rs's CAPABILITIES,
		// which is also what the wall below tests), so the two cannot
		// disagree.
		//
		// THE ANSWER IS FALSE ON THE PHONES, and the core would refuse
		// this call there AT THE ROOT — "this host has no auxiliary
		// windows (KAYA_CAP_AUX_WINDOWS is unset)" then SIGABRT, after
		// one harness step, with the identity already declared.
		//
		// THE NAME IS STILL DECLARED AND STILL READ on those hosts; on a
		// phone the reader is the installed package's own label
		// (docs/app-identity-plan.md ruling 3), so the runner drops the
		// one step that reads the window instead
		// (tools/android/run-emulator.py's scene_script_drop).
		// tools/scenes/identity.steps is byte-frozen and shared verbatim
		// — the cut belongs to the runner, never to the scene.
		if kaya.Capabilities().AuxWindows {
			untitled := tx.CreateWindow(1).Size(360, 240)
			aux := tx.Column(func() {
				caption := tx.Signal("no title of its own")
				tx.Label(caption) // label#2
			})
			tx.MountIn(untitled.Id(), aux)
		}
	})

	return app
}
