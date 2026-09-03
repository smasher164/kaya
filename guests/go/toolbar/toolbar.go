// The toolbar scene (tools/scenes/toolbar.steps): the `primary` bit as
// window chrome, with no toolbar vocabulary to spell.
package toolbar

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	saveEnabled := true

	app.Build(func(tx *kaya.Tx) {
		status := tx.Signal("ready")
		// Written against the MENU ITEM: the promoted button IS that item.
		canSave := tx.Signal(true)

		// CATALOG PREORDER DECIDES PROMOTION.
		win := tx.Window(0).Title("toolbar")
		file := win.Menu("File")
		// The vocabulary has no save glyph, so `done` is the spelling.
		file.Item("Save").Symbol(kaya.SymbolDone).Primary(true).
			BindEnabled(canSave).Shortcut("primary+s").
			OnActivate(func(tx *kaya.Tx) {
				tx.Write(status, "saved")
			})
		file.Item("Export").Symbol(kaya.SymbolForward).
			OnActivate(func(tx *kaya.Tx) {
				tx.Write(status, "exported")
			})

		edit := win.Menu("Edit")
		edit.Item("Find").Symbol(kaya.SymbolSearch).Primary(true).
			OnActivate(func(tx *kaya.Tx) {
				tx.Write(status, "found")
			})
		edit.Item("Replace").Symbol(kaya.SymbolEdit)

		view := win.Menu("View")
		view.Item("Refresh").Symbol(kaya.SymbolRefresh)
		view.Item("Info").Symbol(kaya.SymbolInfo)

		tx.Mount(tx.Column(func() {
			tx.Label(status) // label#0
			tx.Button("toggle save", func(tx *kaya.Tx) { // button#0
				saveEnabled = !saveEnabled
				tx.Write(canSave, saveEnabled)
			})
		}))
	})

	return app
}
