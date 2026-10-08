// The content type scene, Swift port — guests/rust/autofill.rs,
// tools/scenes/autofill.steps (docs/autofill-plan.md §5): a sign-in form,
// a sign-up form, a code field and a phone field, each saying what it
// holds; a button that turns the sign-in name into an email address and
// back; and a stamped code field.

import Foundation
import Kaya

struct Account: KayaGen {
    var name: String
}

KayaApp.run { app in
    var email = false
    app.build { tx in
        let accounts = accountCollection(tx)
        let mode = tx.signal(.str("sign in with a username"))

        let root = tx.column { root in
            let user = tx.entry(contentType: .username)
            tx.setPlaceholder(user, "Username")
            tx.setA11yId(user, "user")
            let password = tx.secureField(contentType: .password)
            tx.setPlaceholder(password, "Password")
            tx.setA11yId(password, "password")
            tx.setA11yId(tx.label(bind: mode), "mode")
            let useEmail = tx.button("Use email") { t in
                email = !email
                if email {
                    t.setContentType(user, .email)
                    t.write(mode, .str("sign in with an email address"))
                } else {
                    t.setContentType(user, .username)
                    t.write(mode, .str("sign in with a username"))
                }
            }
            tx.setA11yId(useEmail, "switch")
            let emailField = tx.entry(contentType: .email)
            tx.setPlaceholder(emailField, "Email")
            tx.setA11yId(emailField, "email")
            let newPassword = tx.secureField(contentType: .newPassword)
            tx.setPlaceholder(newPassword, "New password")
            tx.setA11yId(newPassword, "new")
            let code = tx.entry(contentType: .oneTimeCode)
            tx.setPlaceholder(code, "Code")
            tx.setA11yId(code, "code")
            let phone = tx.entry(contentType: .phone)
            tx.setPlaceholder(phone, "Phone")
            tx.setA11yId(phone, "phone")
            let note = tx.entry()
            tx.setPlaceholder(note, "Note")
            tx.setA11yId(note, "note")
            for row in accounts.rows {
                row.label(row.name)
                let pin = row.t.secureField()
                row.t.setContentType(pin, .oneTimeCode)
                row.t.setA11yId(pin, "pin")
            }
            return root
        }
        tx.mount(root)

        accounts.insert(tx, .str("a"), Account(name: "a"))
    }
}
