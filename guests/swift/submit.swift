// The submit scene, Swift port — guests/rust/submit.rs,
// tools/scenes/submit.steps. Return in an entry, a search field and a
// `submits` textarea publishes `submitted` with the field's text
// (docs/submit-plan.md); a plain textarea's Return is its newline. The
// app writes each submit into one label.

import Foundation
import Kaya

struct Thread: KayaGen {
    var title: String
}

KayaApp.run { app in
    app.build { tx in
        let threads = threadCollection(tx)
        let sent = tx.signal(.str("sent: -"))

        let root = tx.column { root in
            tx.setA11yId(tx.label(bind: sent), "sent")
            let name = tx.entry(onSubmit: { t, text in
                t.write(sent, .str("sent: \(text)"))
            })
            tx.setPlaceholder(name, "Name")
            tx.setA11yId(name, "name")
            let find = tx.search(onSubmit: { t, text in
                t.write(sent, .str("sent: \(text)"))
            })
            tx.setPlaceholder(find, "Search")
            tx.setA11yId(find, "find")
            let plain = tx.textarea(onSubmit: { t, text in
                t.write(sent, .str("sent: \(text)"))
            })
            tx.setA11yId(plain, "plain")
            let compose = tx.textarea(
                onSubmit: { t, text in
                    t.write(sent, .str("sent: \(text)"))
                },
                submits: true)
            tx.setA11yId(compose, "compose")
            for row in threads.rows {
                row.label(row.title)
                let reply = row.t.entry(onSubmit: { t, keys, text in
                    guard case .str(let key) = keys[0] else { return }
                    t.write(sent, .str("sent: \(key): \(text)"))
                })
                row.t.setA11yId(reply, "reply")
            }
            return root
        }
        tx.mount(root)

        threads.insert(tx, .str("r1"), Thread(title: "First"))
        threads.insert(tx, .str("r2"), Thread(title: "Second"))
    }
}
