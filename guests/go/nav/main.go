// The nav conformance scene, Go port — the serial navigation grammar
// via the chain spelling: PushEntry chains props, MountIn presents
// the entry's root, OnEntryPopped hears the user's native pop, and
// OnBackRequested answers the intercept_back veto with PopEntry. The
// covered root is RETAINED (status keeps taking writes while
// covered); a programmatic PopEntry does not echo entry_popped, so
// the settings round's final status stays "back requested". See
// guests/rust/nav.rs and tools/scenes/nav.steps.
package main

import (
	"os"
	"runtime"

	kaya "dev.kaya/bindings/go"
)

func init() {
	runtime.LockOSThread()
}

const (
	detail   = 7
	settings = 8
)

func main() {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("nav")
		status = tx.Signal("at root")

		tx.Mount(tx.Column(func() {
			tx.Label(status) // label#0
			tx.Button("open detail", func(tx *kaya.Tx) { // button#0
				// The popped handler rides the push (per-entry, the
				// request-bound alert precedent): it can only ever
				// mean the detail screen popped, and it retires with
				// the one pop.
				entry := tx.PushEntry(detail).
					Title("detail").
					OnPopped(func(tx *kaya.Tx) {
						tx.Write(status, "popped detail")
					}).
					Id()
				pane := tx.Column(func() {
					caption := tx.Signal("detail pane")
					tx.Label(caption)
				})
				tx.MountIn(entry, pane)
				// The covered root keeps taking writes —
				// retention, observable after the pop.
				tx.Write(status, "pushed detail")
			})
			tx.Button("open settings", func(tx *kaya.Tx) { // button#1
				// The veto class: nothing has popped; agree and
				// confirm. No entry_popped will fire — the write is
				// the round's final status.
				entry := tx.PushEntry(settings).
					Title("settings").
					InterceptBack(true).
					OnBackRequested(func(tx *kaya.Tx) {
						tx.Write(status, "back requested")
						tx.PopEntry()
					}).
					Id()
				pane := tx.Column(func() {
					caption := tx.Signal("settings pane")
					tx.Label(caption)
				})
				tx.MountIn(entry, pane)
				tx.Write(status, "pushed settings")
			})
		}))
	})

	os.Exit(app.Run())
}
