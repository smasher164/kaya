// The layout scene, Go port — the native-default observation vehicle;
// see guests/rust/layout.rs for the axes it stresses. The two label
// expects (KAYA_SELFTEST=layout) only prove the tree built; the scene
// asserts no geometry — container targets index by creation order,
// which legitimately differs per language. The grow contract is
// asserted in the grow scene instead.
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
		probe := tx.Signal("Layout probe")
		tail := tx.Signal("tail")
		mixed := tx.Signal("mixed")
		nested := tx.Signal("nested")
		deep := tx.Signal("deep")

		tx.Mount(tx.Column(func() {
			tx.Label(probe) // label#0

			// Main-axis free space: three unequal children with
			// leftover room.
			tx.Row(func() {
				tx.Button("A", nil)
				tx.Button("longer", nil)
				tx.Label(tail) // label#1
			})

			// Cross-axis alignment: three different intrinsic heights,
			// one grower filling the leftover row width.
			tx.Row(func() {
				tx.Checkbox("check", nil)
				tx.Label(mixed) // label#2
				s := tx.Slider(0.0, 1.0, 0.5, nil)
				tx.SetGrow(s, 1.0)
			})

			// Proportional grow: two growers of unequal weight in one
			// row.
			tx.Row(func() {
				thin := tx.Slider(0.0, 1.0, 0.25, nil)
				tx.SetGrow(thin, 1.0)
				wide := tx.Slider(0.0, 1.0, 0.75, nil)
				tx.SetGrow(wide, 3.0)
			})

			// Nesting: a column inside the root column, a row inside
			// that.
			tx.Column(func() {
				tx.Label(nested) // label#3
				tx.Row(func() {
					tx.Label(deep) // label#4
					tx.Button("x", nil)
				})
			})
		}))
	})

	os.Exit(app.Run())
}
