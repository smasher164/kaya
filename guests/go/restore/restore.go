// The restoration scene (tools/scenes/restore.steps,
// docs/restoration-plan.md SR15): the draft lives in the session store and
// comes back through the ordinary build; the list's scroll and the text's
// caret come back on their own.
package restore

import (
	"fmt"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Message -key string
type Message struct {
	Text string
}

func App() *kaya.App {
	app := kaya.NewApp()
	session := kaya.Session()

	// Posted: the session answers once the app runs (docs/traps.md, iOS's restoration token).
	app.Post(func(tx *kaya.Tx) {
		tx.Window(0).Title("restore")
		messages := MessageCollection(tx)
		launch := tx.Signal("launch " + kaya.Restored())
		var list, doc kaya.Widget
		tx.Mount(tx.Column(func() {
			tx.Label(launch)
			field := tx.Entry(func(_ *kaya.Tx, text string) {
				session.SetString("draft", text)
			})
			tx.SetText(field, session.GetString("draft", ""))
			tx.Row(func() {
				tx.Button("jump", func(tx *kaya.Tx) { tx.ScrollToRow(list, "m30") }).A11yID("jump")
				tx.Button("select", func(tx *kaya.Tx) {
					tx.SelectRange(doc, kaya.TextRange{Start: 4, End: 9})
				}).A11yID("select")
			})
			doc = tx.Textarea(nil).A11yID("doc")
			tx.SetText(doc, "the quick brown fox")
			tx.Scroll(func() {
				rows := MessageRows(tx, messages)
				list = rows.Widget()
				for row := range rows.All() {
					row.Label(row.Text())
				}
				tx.SetA11yID(list, "messages")
			}).Grow(1).A11yID("list")
		}))
		for i := 1; i <= 60; i++ {
			messages.Insert(tx, fmt.Sprintf("m%d", i), Message{Text: fmt.Sprintf("message %d", i)})
		}
	})

	return app
}
