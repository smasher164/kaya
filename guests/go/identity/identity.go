// The app-identity scene (tools/scenes/identity.steps): the mark's four
// flat quadrants, and a second window whose blank title the NAME fills.
package identity

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	draft := ""

	app.Build(func(tx *kaya.Tx) {
		// BEFORE THE FIRST MOUNT, per the declared-once wall.
		icon := tx.Asset("icons/kaya-mark.png")
		defer icon.Close()
		tx.AppIdentityAsset("Aurora Notes", icon)
		tx.Window(0).Title("identity").Size(480, 360)
		// ONE PROMOTED COMMAND, AND NOT ABOUT COMMANDS: Windows mints its
		// custom caption from it, replacing the system-drawn icon.
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

		// No title at all: an empty string is a title an app WROTE. FALSE ON
		// THE PHONES, where this call aborts and the runner drops the step.
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
