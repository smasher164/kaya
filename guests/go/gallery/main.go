// The gallery scene from Go: a row container laying a checkbox and the
// status label side by side. The box owns its checked bit and reports
// each flip through OnToggle; the app answers by writing the status
// signal — the same uncontrolled contract as the entry, with a bool.
//
// Build the library first (cargo build), then, from the repo root:
//
//	KAYA_SELFTEST=gallery go run crates/kaya/examples/gallery.go
package main

import (
	"fmt"
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

	var (
		status kaya.Signal[string]
		urgent kaya.Widget
	)

	app.Build(func(tx *kaya.Tx) {
		status = tx.Signal("urgent: false")

		column := tx.Widget(kaya.KindColumn)
		row := tx.Widget(kaya.KindRow)
		urgent = tx.Widget(kaya.KindCheckbox)
		tx.SetText(urgent, "urgent")
		statusLabel := tx.Widget(kaya.KindLabel)
		tx.BindText(statusLabel, status)

		tx.AddChild(row, urgent)
		tx.AddChild(row, statusLabel)
		tx.AddChild(column, row)
		tx.Mount(column)
	})

	app.OnToggle(urgent, func(tx *kaya.Tx, checked bool) {
		tx.Write(status, fmt.Sprintf("urgent: %t", checked))
	})

	os.Exit(app.Run())
}
