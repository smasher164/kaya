// The grow conformance scene, Go port — see guests/rust/grow.rs for
// the full rationale. Every child of the column and of the row is a
// grower, so each split is exactly weight/Σweight: 1,1,2 divide the
// column 25/25/50 and the row's 1,3 divide its width 25/75. The
// harness (KAYA_SELFTEST=grow) asserts both splits plus root-fills,
// byte-for-byte against every other language and backend.
package grow

import (
	kaya "dev.kaya/bindings/go"
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

	return app
}
