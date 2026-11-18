// The restoration scene, Swift port — guests/rust/restore.rs,
// tools/scenes/restore.steps (docs/restoration-plan.md SR15): the draft
// lives in the session store and comes back through the ordinary build;
// the list's scroll and the text's caret come back on their own.

import Foundation
import Kaya

struct Message: KayaGen {
    var text: String
}

KayaApp.run { app in
    let session = KayaApp.session()
    app.build { tx in
        tx.window(title: "restore")
        let messages = messageCollection(tx)
        let launch = tx.signal(.str("launch \(KayaApp.restored())"))
        var list: KayaWidget!
        var doc: KayaWidget!
        let root = tx.column { root in
            tx.label(bind: launch)
            let field = tx.entry(onChange: { _, text in session.set("draft", text) })
            tx.setText(field, session.get("draft", default: ""))
            tx.row { _ in
                tx.setA11yId(
                    tx.button("jump", onClick: { t in t.scrollToRow(list, .str("m30")) }), "jump")
                tx.setA11yId(
                    tx.button("select", onClick: { t in t.selectRange(doc, 4..<9) }), "select")
            }
            doc = tx.textarea()
            tx.setA11yId(doc, "doc")
            tx.setText(doc, "the quick brown fox")
            tx.scroll(grow: 1) { scroll in
                tx.setA11yId(scroll, "list")
                list = messageEach(tx, messages) { row in
                    row.label(row.text)
                }
                tx.setA11yId(list, "messages")
            }
            return root
        }
        tx.mount(root)
        for i in 1...60 {
            messages.insert(tx, .str("m\(i)"), Message(text: "message \(i)"))
        }
    }
}
