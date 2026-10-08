// The reveal toggle scene, Swift port — guests/rust/reveal.rs,
// tools/scenes/reveal.steps (docs/reveal-plan.md §5): a password field
// with its own show/hide toggle, the app's own Show and Hide buttons, and a
// stamped field each row reveals by its own field.

import Foundation
import Kaya

struct Account: KayaGen {
    var name: String
    var shown: Bool
}

func status(_ text: String) -> String {
    let password = "Rv4tNbHy2mQc"
    let n = text.unicodeScalars.count
    if n == 0 { return "empty" }
    return text == password ? "\(n) characters, match" : "\(n) characters, no match"
}

func shown(_ on: Bool) -> String {
    on ? "shown" : "hidden"
}

KayaApp.run { app in
    app.build { tx in
        let accounts = accountCollection(tx)
        let statusText = tx.signal(.str("empty"))
        let sentText = tx.signal(.str("sent: -"))
        let heardText = tx.signal(.str("heard: -"))
        let pinText = tx.signal(.str("pin: -"))

        let root = tx.column { root in
            let field = tx.secureField(
                onChange: { t, text in t.write(statusText, .str(status(text))) },
                onSubmit: { t, text in t.write(sentText, .str("sent: \(status(text))")) },
                contentType: .password,
                revealable: true,
                onToggle: { t, on in t.write(heardText, .str("heard: \(shown(on))")) })
            tx.setPlaceholder(field, "Password")
            tx.setA11yId(field, "password")
            tx.setA11yLabel(field, "Password")
            tx.setA11yId(tx.label(bind: statusText), "status")
            tx.setA11yId(tx.label(bind: sentText), "sent")
            tx.setA11yId(tx.label(bind: heardText), "heard")
            let show = tx.button("Show", onClick: { t in t.setRevealed(field, true) })
            tx.setA11yId(show, "show")
            let hide = tx.button("Hide", onClick: { t in t.setRevealed(field, false) })
            tx.setA11yId(hide, "hide")
            let clear = tx.button("Clear", onClick: { t in t.clear(field) })
            tx.setA11yId(clear, "clear")
            tx.setA11yId(tx.label(bind: pinText), "pin_status")
            for row in accounts.rows {
                row.label(row.name)
                let pin = row.t.secureField(
                    onChange: { t, keys, text in
                        guard case .str(let key) = keys[0] else { return }
                        t.write(pinText, .str("pin \(key): \(text.unicodeScalars.count)"))
                    },
                    onToggle: { t, keys, on in
                        guard case .str(let key) = keys[0] else { return }
                        t.write(pinText, .str("pin \(key): \(shown(on))"))
                    })
                row.t.setA11yId(pin, "pin")
                row.t.setRevealable(pin)
                row.t.setRevealed(pin, row.shown)
            }
            return root
        }
        tx.mount(root)

        accounts.insert(tx, .str("b"), Account(name: "b", shown: true))
    }
}
