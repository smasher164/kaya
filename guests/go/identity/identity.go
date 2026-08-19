// The app-identity conformance scene, Go port: an app declares what it
// is called and what it looks like, and the platform shows both. The
// canonical semantics is guests/rust/identity.rs; the byte-frozen
// contract is tools/scenes/identity.steps.
//
// THE MARK IS THE VENDORED ONE (four flat quadrants) because no
// platform's own default icon can land on four declared colours, so a
// lowering that never applied can never read as a pass.
//
// THE MARK IS AN ASSET NOW (docs/assets-plan.md, ratified 2026-08-18).
// This scene used to resolve the file itself — kaya.Env("KAYA_ICON_FILE")
// with a repo-relative default, os.ReadFile, and a panic in its own
// words — as its seven siblings each did in their own language.
// tx.Asset(name) is the whole thing now: WHERE the file lives is the
// core's knowledge (a repo checkout, a bundle's Resources, an APK's
// packaged assets/ with no path at all), and the four quadrants the
// scene reads back are the same four wherever it was found. The
// kaya.Env-not-os.Getenv rule this file used to carry is not merely
// obeyed here any more, it is unreachable: the scene reads no
// environment at all.
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
		// taking the system-drawn app icon with it. That is why the
		// identity has a second Windows sink at all, and a scene with no
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

		// THE UNTITLED WINDOW, and it is DESKTOP-ONLY: see the build-tag
		// pair beside this file (untitled_desktop.go / untitled_phone.go).
		mountUntitled(tx)
	})

	return app
}
