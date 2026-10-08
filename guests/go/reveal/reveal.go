// The reveal toggle scene (tools/scenes/reveal.steps; docs/reveal-plan.md
// §5): a password field with its own show/hide toggle, the app's own Show
// and Hide buttons, and a stamped field each row reveals by its own field.
package reveal

import (
	"fmt"
	"unicode/utf8"

	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Account -key string
type Account struct {
	Name  string
	Shown bool
}

const password = "Rv4tNbHy2mQc"

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

func shown(on bool) string {
	if on {
		return "shown"
	}
	return "hidden"
}

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		statusText := tx.Signal("empty")
		sentText := tx.Signal("sent: -")
		heardText := tx.Signal("heard: -")
		pinText := tx.Signal("pin: -")
		accounts := AccountCollection(tx)

		tx.Mount(tx.Column(func() {
			field := tx.SecureField(func(tx *kaya.Tx, text string) {
				tx.Write(statusText, status(text))
			}).Placeholder("Password").ContentType(kaya.ContentTypePassword).Revealable().
				A11yID("password").A11yLabel("Password").
				OnSubmitted(func(tx *kaya.Tx, text string) {
					tx.Write(sentText, "sent: "+status(text))
				}).
				OnToggle(func(tx *kaya.Tx, on bool) {
					tx.Write(heardText, "heard: "+shown(on))
				})
			tx.Label(statusText).A11yID("status")
			tx.Label(sentText).A11yID("sent")
			tx.Label(heardText).A11yID("heard")
			tx.Button("Show", func(tx *kaya.Tx) {
				tx.SetRevealed(field, true)
			}).A11yID("show")
			tx.Button("Hide", func(tx *kaya.Tx) {
				tx.SetRevealed(field, false)
			}).A11yID("hide")
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
				row.SetRevealable(pin)
				row.Revealed(pin, row.Shown())
				pin.OnToggle(func(tx *kaya.Tx, keys []any, on bool) {
					tx.Write(pinText, fmt.Sprintf("pin %s: %s", keys[0], shown(on)))
				})
			}
		}))

		accounts.Insert(tx, "b", Account{Name: "b", Shown: true})
	})

	return app
}
