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
			tx.Label(probe).Grow(1)   // label#0
			tx.Button("quarter", nil).Grow(1)
			tx.Row(func() {
				tx.Label(one).Grow(1) // label#1
				tx.Button("three", nil).Grow(3)
			}).Grow(2).Spacing(12)
		}))
	})

	os.Exit(app.Run())
}
