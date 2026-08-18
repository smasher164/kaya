// The standard-commands scene, Go port: a chord on every leaf kind,
// the punctuation keys those chords need, and the `settings` role —
// which macOS shows in the application menu while the item stays
// addressable where it was declared. See guests/rust/commands.rs and
// tools/scenes/commands.steps.
package commands

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()
	settingsCount := 0

	app.Build(func(tx *kaya.Tx) {
		status := tx.Signal("ready")
		details := tx.Signal(false)
		sort := tx.Signal(0.0)

		win := tx.Window(0).Title("commands")

		// The settings command declares its own punctuation chord and
		file := win.Menu("File")
		file.Item("Reload")
		file.Item("Settings…").Shortcut("primary+comma").Role(kaya.RoleSettings).
			OnActivate(func(tx *kaya.Tx) {
				// Fires twice on purpose: once by the chord, once by
				// activating the item at its DECLARED path, which on
				// macOS is the application menu by then.
				settingsCount++
				tx.Write(status, fmt.Sprintf("settings %d", settingsCount))
			})

		view := win.Menu("View")
		view.Toggle("Details").BindChecked(details).Shortcut("primary+backslash").
			OnToggle(func(tx *kaya.Tx, on bool) {
				if on {
					tx.Write(status, "details on")
				} else {
					tx.Write(status, "details off")
				}
			})

		// Option order IS the index vocabulary: Name = 0, Date = 1.
		sortGroup := view.RadioGroup("Sort")
		sortGroup.Option("Name").Shortcut("primary+1")
		sortGroup.Option("Date").Shortcut("primary+2")
		sortGroup.BindValue(sort).OnSelect(func(tx *kaya.Tx, index int) {
			if index == 1 {
				tx.Write(status, "sorted date")
			} else {
				tx.Write(status, "sorted name")
			}
		})

		tx.Mount(tx.Column(func() {
			tx.Label(status) // label#0
		}))
	})

	return app
}
