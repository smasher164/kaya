// The textarea conformance scene, Go port. See
// guests/rust/textarea.rs and tools/scenes/textarea.steps.
package main

import (
	"fmt"
	"os"
	"runtime"
	"strings"

	kaya "dev.kaya/bindings/go"
)

func init() {
	runtime.LockOSThread()
}

func count(text string) string {
	if text == "" {
		return "0 lines"
	}
	return fmt.Sprintf("%d lines", len(strings.Split(strings.TrimSuffix(text, "\n"), "\n")))
}

func main() {
	app := kaya.NewApp()

	var lines kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("textarea")
		lines = tx.Signal("0 lines")

		tx.Mount(tx.Column(func() {
			editor := tx.Textarea(func(tx *kaya.Tx, text string) {
				tx.Write(lines, count(text))
			})
			tx.Label(lines) // label#0
			tx.Button("clear", func(tx *kaya.Tx) {
				tx.Clear(editor)
				tx.Focus(editor)
			})
		}))
	})

	os.Exit(app.Run())
}
