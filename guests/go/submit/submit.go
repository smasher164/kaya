// The submit scene (tools/scenes/submit.steps): Return in an entry, a
// search field and a Submits textarea publishes the field's text
// (docs/submit-plan.md S1); a plain textarea's Return is its newline.
// The app writes each submit into one label.
package submit

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Thread -key string
type Thread struct {
	Title string
}

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		sent := tx.Signal("sent: -")
		threads := ThreadCollection(tx)
		var reply kaya.Node

		tx.Mount(tx.Column(func() {
			tx.Label(sent).A11yID("sent")
			wrote := func(tx *kaya.Tx, text string) {
				tx.Write(sent, fmt.Sprintf("sent: %s", text))
			}
			tx.Entry(nil).Placeholder("Name").A11yID("name").OnSubmitted(wrote)
			tx.Search(nil).Placeholder("Search").A11yID("find").OnSubmitted(wrote)
			tx.Textarea(nil).A11yID("plain").OnSubmitted(wrote)
			tx.Textarea(nil).Submits().A11yID("compose").OnSubmitted(wrote)
			for row := range ThreadRows(tx, threads).All() {
				row.Label(row.Title())
				reply = row.Entry(nil)
				row.SetA11yID(reply, "reply")
			}
		}))

		reply.OnSubmitted(func(tx *kaya.Tx, keys []any, text string) {
			tx.Write(sent, fmt.Sprintf("sent: %v: %s", keys[0], text))
		})

		threads.Insert(tx, "r1", Thread{Title: "First"})
		threads.Insert(tx, "r2", Thread{Title: "Second"})
	})

	return app
}
