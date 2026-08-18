// The app-identity conformance scene, Go port: an app declares what it
// is called and what it looks like, and the platform shows both. The
// canonical semantics is guests/rust/identity.rs; the byte-frozen
// contract is tools/scenes/identity.steps.
//
// THE MARK IS THE VENDORED ONE (guests/assets/icons/kaya-mark.png, four
// flat quadrants) because no platform's own default icon can land on
// four declared colours, so a lowering that never applied can never read
// as a pass. KAYA_ICON_FILE is how a runner that cannot see the repo
// points at a pushed copy.
//
// THE SECOND WINDOW HAS NO TITLE OF ITS OWN, deliberately: that is the
// blank an app's NAME fills on every platform.
package identity

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
		// BEFORE THE FIRST MOUNT, per the declared-once wall. kaya.Env
		// and never os.Getenv — tools/check-go-env.sh.
		iconPath := kaya.Env("KAYA_ICON_FILE")
		if iconPath == "" {
			iconPath = "guests/assets/icons/kaya-mark.png"
		}
		icon, err := os.ReadFile(iconPath)
		if err != nil {
			panic(fmt.Sprintf(
				"kaya: the identity scene needs the vendored mark at %s "+
					"(set KAYA_ICON_FILE or run from the repo root): %v",
				iconPath, err))
		}
		tx.AppIdentity("Aurora Notes", icon)
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
