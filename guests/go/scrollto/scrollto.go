// The scroll-to scene (tools/scenes/scrollto.steps): the app scrolls a
// list of messages to a row by key (docs/scroll-to-plan.md), opening at
// the newest one before the first layout, jumping to one on a click,
// staying put on a key no row holds, and following its own send.
package scrollto

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

	app.Build(func(tx *kaya.Tx) {
		messages := MessageCollection(tx)
		count := tx.Signal("60 messages")
		var list kaya.Widget
		sent := 60

		tx.Mount(tx.Column(func() {
			tx.Label(count).A11yID("count")
			tx.Row(func() {
				tx.Button("jump", func(tx *kaya.Tx) {
					tx.ScrollToRow(list, "m10")
				}).A11yID("jump")
				tx.Button("nowhere", func(tx *kaya.Tx) {
					tx.ScrollToRow(list, "m999")
				}).A11yID("nowhere")
				tx.Button("send", func(tx *kaya.Tx) {
					sent++
					key := fmt.Sprintf("m%d", sent)
					messages.Insert(tx, key, Message{Text: fmt.Sprintf("message %d", sent)})
					tx.Write(count, fmt.Sprintf("%d messages", sent))
					tx.ScrollToRow(list, key)
				}).A11yID("send")
			})
			tx.Scroll(func() {
				// The For's own container is what a scroll_to_row
				// addresses (docs/scroll-to-plan.md S1).
				rows := MessageRows(tx, messages)
				list = rows.Widget()
				for row := range rows.All() {
					row.Label(row.Text())
				}
				tx.SetA11yID(list, "messages")
			}).Grow(1)
		}))

		for i := 1; i <= 60; i++ {
			messages.Insert(tx, fmt.Sprintf("m%d", i), Message{Text: fmt.Sprintf("message %d", i)})
		}
		tx.ScrollToRow(list, "m60")
	})

	return app
}
