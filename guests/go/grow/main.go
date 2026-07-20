// The grow conformance scene, Go port — see guests/rust/grow.rs for
// the full rationale. Every child of the column and of the row is a
// grower, so each split is exactly weight/Σweight: 1,1,2 divide the
// column 25/25/50 and the row's 1,3 divide its width 25/75. The
// harness (KAYA_SELFTEST=grow) asserts both splits plus root-fills,
// byte-for-byte against every other language and backend.
package main

import (
	"os"
	"runtime"

	kaya "dev.kaya/bindings/go"
)

func init() {
	// The core must own the process main thread.
	runtime.LockOSThread()
}

func main() {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		probe := tx.Signal("grow probe")
		one := tx.Signal("one")

		tx.Mount(tx.Column(func() {
			label := tx.Label(probe) // label#0
			tx.SetGrow(label, 1.0)
			quarter := tx.Button("quarter", nil)
			tx.SetGrow(quarter, 1.0)
			band := tx.Row(func() {
				tick := tx.Label(one) // label#1
				tx.SetGrow(tick, 1.0)
				three := tx.Button("three", nil)
				tx.SetGrow(three, 3.0)
			})
			tx.SetGrow(band, 2.0)
		}))
	})

	os.Exit(app.Run())
}
