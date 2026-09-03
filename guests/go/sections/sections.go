// The sections conformance scene (tools/scenes/sections.steps): two peer
// roots in the primary window's section set.
package sections

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

const (
	feed    = 7
	archive = 8

	// An AUX WINDOW, reached only by the desktop tail's click, so
	// CreateWindow never runs where the capability is absent.
	library = 1
	shelves = 2
	loans   = 3
)

func App() *kaya.App {
	app := kaya.NewApp()

	visitCount := 0
	var visits kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("sections").SectionsPresentation(kaya.SectionsPresentationBar)
		visits = tx.Signal("archive: 0 visits")

		// SF Symbols are licensed to Apple platforms: no shared asset exists.
		feedSection := tx.AddSection(feed).Title("Feed").Symbol(kaya.SymbolHome).Id()
		archiveSection := tx.AddSection(archive).
			Title("Archive").
			Symbol(kaya.SymbolStar).
			OnSelected(func(tx *kaya.Tx) {
				visitCount++
				tx.Write(visits, fmt.Sprintf("archive: %d visits", visitCount))
			}).
			Id()

		feedRoot := tx.Column(func() {
			ready := tx.Signal("feed ready")
			tx.Label(ready) // label#0
			tx.Button("to archive", func(tx *kaya.Tx) { // button#0
				// Programmatic selection: OnSelected must NOT fire.
				tx.SelectSection(archive)
			})
			tx.Button("open library", func(tx *kaya.Tx) { // button#1
				tx.CreateWindow(library).
					Title("library").
					SectionsPresentation(kaya.SectionsPresentationSidebar)

				shelvesSection := tx.AddSectionIn(library, shelves).
					Title("Shelves").Symbol(kaya.SymbolSearch).Id()
				loansSection := tx.AddSectionIn(library, loans).
					Title("Loans").Symbol(kaya.SymbolLock).Id()

				shelvesRoot := tx.Column(func() {
					ready := tx.Signal("shelves ready")
					tx.Label(ready) // label#2
				})
				tx.MountIn(shelvesSection, shelvesRoot)

				loansRoot := tx.Column(func() {
					ready := tx.Signal("loans ready")
					tx.Label(ready) // label#3
				})
				tx.MountIn(loansSection, loansRoot)
			})
		})
		tx.MountIn(feedSection, feedRoot)

		archiveRoot := tx.Column(func() {
			tx.Label(visits) // label#1
		})
		tx.MountIn(archiveSection, archiveRoot)
	})

	return app
}
