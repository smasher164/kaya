// The secure field scene, Swift port — guests/rust/secure.rs,
// tools/scenes/secure.steps (docs/secure-entry-plan.md §5): a password
// field whose text the app receives whole and answers only as a length and
// a match, a clear button, and a stamped field per account whose edits name
// the row.

import Foundation
import Kaya

struct Account: KayaGen {
    var name: String
}

func status(_ text: String) -> String {
    let password = "Zq7vKeXw9pLm"
    let n = text.unicodeScalars.count
    if n == 0 { return "empty" }
    return text == password ? "\(n) characters, match" : "\(n) characters, no match"
}

KayaApp.run { app in
    app.build { tx in
        let accounts = accountCollection(tx)
        let statusText = tx.signal(.str("empty"))
        let sentText = tx.signal(.str("sent: -"))
        let pinText = tx.signal(.str("pin: -"))

        let root = tx.column { root in
            let field = tx.secureField(
                onChange: { t, text in t.write(statusText, .str(status(text))) },
                onSubmit: { t, text in t.write(sentText, .str("sent: \(status(text))")) })
            tx.setPlaceholder(field, "Password")
            tx.setA11yId(field, "password")
            tx.setA11yLabel(field, "Password")
            tx.setA11yId(tx.label(bind: statusText), "status")
            tx.setA11yId(tx.label(bind: sentText), "sent")
            let clear = tx.button("Clear", onClick: { t in t.clear(field) })
            tx.setA11yId(clear, "clear")
            tx.setA11yId(tx.label(bind: pinText), "pin_status")
            for row in accounts.rows {
                row.label(row.name)
                let pin = row.t.secureField(onChange: { t, keys, text in
                    guard case .str(let key) = keys[0] else { return }
                    t.write(pinText, .str("pin \(key): \(text.unicodeScalars.count)"))
                })
                row.t.setA11yId(pin, "pin")
            }
            return root
        }
        tx.mount(root)

        accounts.insert(tx, .str("a"), Account(name: "a"))
        accounts.insert(tx, .str("b"), Account(name: "b"))
    }
}
