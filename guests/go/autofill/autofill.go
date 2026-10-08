// The content type scene (tools/scenes/autofill.steps;
// docs/autofill-plan.md §5): a sign-in form, a sign-up form, a code field
// and a phone field, each saying what it holds; a button that turns the
// sign-in name into an email address and back; and a stamped code field.
package autofill

import (
	kaya "dev.kaya/bindings/go"
)

//go:generate go run dev.kaya/cmd/kaya-gen -type Account -key string
type Account struct {
	Name string
}

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		mode := tx.Signal("sign in with a username")
		accounts := AccountCollection(tx)
		email := false

		tx.Mount(tx.Column(func() {
			user := tx.Entry(nil).Placeholder("Username").
				ContentType(kaya.ContentTypeUsername).A11yID("user")
			tx.SecureField(nil).Placeholder("Password").
				ContentType(kaya.ContentTypePassword).A11yID("password")
			tx.Label(mode).A11yID("mode")
			tx.Button("Use email", func(tx *kaya.Tx) {
				email = !email
				if email {
					tx.SetContentType(user, kaya.ContentTypeEmail)
					tx.Write(mode, "sign in with an email address")
				} else {
					tx.SetContentType(user, kaya.ContentTypeUsername)
					tx.Write(mode, "sign in with a username")
				}
			}).A11yID("switch")
			tx.Entry(nil).Placeholder("Email").ContentType(kaya.ContentTypeEmail).A11yID("email")
			tx.SecureField(nil).Placeholder("New password").
				ContentType(kaya.ContentTypeNewPassword).A11yID("new")
			tx.Entry(nil).Placeholder("Code").ContentType(kaya.ContentTypeOneTimeCode).A11yID("code")
			tx.Entry(nil).Placeholder("Phone").ContentType(kaya.ContentTypePhone).A11yID("phone")
			tx.Entry(nil).Placeholder("Note").A11yID("note")
			for row := range AccountRows(tx, accounts).All() {
				row.Label(row.Name())
				pin := row.SecureField(nil)
				row.SetContentType(pin, kaya.ContentTypeOneTimeCode)
				row.SetA11yID(pin, "pin")
			}
		}))

		accounts.Insert(tx, "a", Account{Name: "a"})
	})

	return app
}
