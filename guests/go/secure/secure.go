// The secure field scene (tools/scenes/secure.steps;
// docs/secure-entry-plan.md §5): a password field whose text the app
// receives whole and answers only as a length and a match, a clear button,
// and a stamped field per account whose edits name the row.
package secure

import (
	"fmt"
	"unicode/utf8"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Account -key string
type Account struct {
	Name string
}

const password = "Zq7vKeXw9pLm"

func status(text string) string {
	n := utf8.RuneCountInString(text)
	switch {
	case n == 0:
		return "empty"
	case text == password:
		return fmt.Sprintf("%d characters, match", n)
	default:
		return fmt.Sprintf("%d characters, no match", n)
	}
}

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		statusText := tx.Signal("empty")
		sentText := tx.Signal("sent: -")
		pinText := tx.Signal("pin: -")
		accounts := AccountCollection(tx)

		tx.Mount(tx.Column(func() {
			field := tx.SecureField(func(tx *kaya.Tx, text string) {
				tx.Write(statusText, status(text))
			}).Placeholder("Password").A11yID("password").A11yLabel("Password").
				OnSubmitted(func(tx *kaya.Tx, text string) {
					tx.Write(sentText, "sent: "+status(text))
				})
			tx.Label(statusText).A11yID("status")
			tx.Label(sentText).A11yID("sent")
			tx.Button("Clear", func(tx *kaya.Tx) {
				tx.Clear(field)
			}).A11yID("clear")
			tx.Label(pinText).A11yID("pin_status")
			for row := range AccountRows(tx, accounts).All() {
				row.Label(row.Name())
				pin := row.SecureField(func(tx *kaya.Tx, key string, text string) {
					tx.Write(pinText, fmt.Sprintf("pin %s: %d", key, utf8.RuneCountInString(text)))
				})
				row.SetA11yID(pin, "pin")
			}
		}))

		accounts.Insert(tx, "a", Account{Name: "a"})
		accounts.Insert(tx, "b", Account{Name: "b"})
	})

	return app
}
