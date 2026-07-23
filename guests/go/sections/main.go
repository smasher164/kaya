// The sections conformance scene, Go port: two peer roots in the
// primary window's section set — presentation context, not
// lifecycle. The archive pane folds OnSelected into a visit count,
// pinning the echo doctrine from both sides: the user's switch emits
// (the harness drives the real switcher), while the feed button's
// programmatic SelectSection moves the selection silently. The count
// surviving switch round trips proves retention. See
// guests/rust/sections.rs and tools/scenes/sections.steps.
package main

import (
	"fmt"
	"os"
	"runtime"

	kaya "dev.kaya/bindings/go"
)

func init() {
	runtime.LockOSThread()
}

const (
	feed    = 7
	archive = 8
)

func main() {
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

		feedSection := tx.AddSection(feed).Title("Feed").Id()
		archiveSection := tx.AddSection(archive).
			Title("Archive").
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
		})
		tx.MountIn(feedSection, feedRoot)

		archiveRoot := tx.Column(func() {
			tx.Label(visits) // label#1
		})
		tx.MountIn(archiveSection, archiveRoot)
	})

	os.Exit(app.Run())
}
