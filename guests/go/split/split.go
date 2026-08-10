// The split conformance scene, Go port — adaptive list-detail via the
// chain spelling: ListDetail rides the window chain, PushEntry chains
// the entry's props, MountIn presents its root, and OnPopped hears the
// user's native pop.
//
// The guest asks for the presentation ONCE and then does nothing
// adaptive ever again. Everything after that is the platform
// re-deciding as the size class changes: an app does not write two
// layouts and pick one, and there is no prop for WHICH way it
// presents. Nothing here is split-specific except that one prop.
//
// TWO scripts drive this ONE app: split resizes and names the
// presentation on each side, listdetail asserts the bare invariant at
// whatever width its host gives. See guests/rust/split.rs,
// tools/scenes/split.steps and tools/scenes/listdetail.steps.
package split

import (
	kaya "dev.kaya/bindings/go"
)

const detail = 7

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

	var status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		// The one adaptive declaration in the whole guest.
		tx.Window(0).Title("split").ListDetail(true)
		status = tx.Signal("list pane")

		tx.Mount(tx.Column(func() {
			// Authored ids so the REAL-TREE read can address these:
			// an index read passes whether or not anything reached
			// the screen, which is the gap that let a non-rendering
			// split arm look green.
			tx.Label(status).A11yID("list") // label#0
			tx.Button("open detail", func(tx *kaya.Tx) { // button#0
				// The popped handler rides the push, per-entry —
				// the request-bound precedent, unchanged by the
				// split.
				entry := tx.PushEntry(detail).
					Title("detail").
					OnPopped(func(tx *kaya.Tx) {
						// Retention: the base root took this
						// write while the detail was up, on a
						// regular window where it was VISIBLE
						// the whole time.
						tx.Write(status, "popped detail")
					}).
					Id()
				pane := tx.Column(func() {
					caption := tx.Signal("detail pane")
					tx.Label(caption).A11yID("detail")
				})
				tx.MountIn(entry, pane)
			})
		}))
	})

	return app
}
