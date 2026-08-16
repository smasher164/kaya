// The sections conformance scene, Go port: two peer roots in the
// primary window's section set — presentation context, not
// lifecycle. The archive pane folds OnSelected into a visit count,
// pinning the echo doctrine from both sides: the user's switch emits
// (the harness drives the real switcher), while the feed button's
// programmatic SelectSection moves the selection silently. The count
// surviving switch round trips proves retention. See
// guests/rust/sections.rs and tools/scenes/sections.steps.
package sections

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

const (
	feed    = 7
	archive = 8

	// The SIDEBAR half of the presentation enum, in an AUX WINDOW so
	// one shared scene covers BOTH arms: the primary stays `bar`, and
	// this window opens from a handler only the desktop tail's click
	// reaches — the phone runners cut the tail, the click never fires,
	// and CreateWindow never runs where the capability is absent. No
	// capability read needed: reachability is the gate.
	library = 1
	shelves = 2
	loans   = 3
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

	visitCount := 0
	var visits kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		// One construct carries the window's attributes (the
		// unification rule). The hint is ADVISORY: `bar` is each
		// desktop's horizontal spelling and the phones' physics
		// regardless — no observable rides on it.
		tx.Window(0).Title("sections").SectionsPresentation(kaya.SectionsPresentationBar)
		visits = tx.Signal("archive: 0 visits")

		// THE SEMANTIC ICON (docs/styling-plan.md D6): a tab bar without
		// icons is not the platform's real thing, and the glyph that
		// means `home` differs per platform — SF Symbols spells it
		// `house`, and no shared asset would be legal anyway (SF Symbols
		// are licensed to Apple platforms only).
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
				// Programmatic selection: configuration, no echo —
				// OnSelected must NOT fire (the scene asserts the
				// count holds).
				tx.SelectSection(archive)
			})
			tx.Button("open library", func(tx *kaya.Tx) { // button#1
				tx.CreateWindow(library).
					Title("library").
					SectionsPresentation(kaya.SectionsPresentationSidebar)

				// The SIDEBAR arm carries symbols too: the source list
				// is where a mac app most wants them.
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
