// The toolbar conformance scene, Go port: the `primary` bit as real
// window chrome (docs/chrome-plan.md C2). The app declares ONE catalog
// and marks two actions primary; every host promotes the same first two
// in catalog preorder and leaves the rest where its catalog lives. There
// is no toolbar vocabulary to spell here, and that is the point.
// Canonical semantics in guests/rust/toolbar.rs; the contract in
// tools/scenes/toolbar.steps.
package toolbar

import (
	kaya "dev.kaya/bindings/go"
)

func App() *kaya.App {
	app := kaya.NewApp()

	// The guest's own copy of the enablement; the signal is the model.
	saveEnabled := true

	app.Build(func(tx *kaya.Tx) {
		status := tx.Signal("ready")
		// The one signal the enablement round-trip turns on, written
		// against the MENU ITEM and saying nothing about any button: the
		// promoted button is that same item, so it follows or the
		// lowering kept a copy.
		canSave := tx.Signal(true)

		// CATALOG PREORDER DECIDES PROMOTION: top-level groupings in
		// menubar-append order, then each node's children depth-first.
		// Save is the first primary and Find the second, however large a
		// host's k is.
		win := tx.Window(0).Title("toolbar")
		file := win.Menu("File")
		// SymbolDone is the checkmark idiom: the vocabulary has no
		// save-specific glyph, and neither does Apple's own catalog
		// (docs/styling-plan.md D6).
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
		// The remainder: everything below is catalog, not chrome, on
		// every platform.
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
