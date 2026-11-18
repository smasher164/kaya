// The restored shape, Swift port — guests/rust/restoredocs.rs,
// tools/scenes/restoredocs.steps (docs/restoration-plan.md SR9): each
// document's title and text live in its own session scope, and act two
// recreates the documents the last launch left, takes each scope back, and
// selects the active one.

import Foundation
import Kaya

KayaApp.run { app in
    var documents: [UInt64] = [10, 11, 12]
    var active: UInt64 = 0
    var restored = false
    for w in KayaApp.restoredWindows() where w.id == 0 {
        documents = w.documents
        active = w.activeDocument
        restored = true
    }
    if !restored {
        for (id, title) in zip(documents, ["a", "b", "c"]) {
            KayaApp.documentSession(id).set("title", title)
        }
    }

    app.build { tx in
        tx.window(title: "restoredocs", width: 640, height: 420)
        for id in documents {
            let scope = KayaApp.documentSession(id)
            let title = scope.get("title", default: "untitled")
            tx.addDocument(id, title: title, restore: id)
            let caption = tx.signal(.str("\(title) body"))
            var field: KayaWidget!
            tx.mountIn(id, tx.column { root in
                tx.setA11yId(tx.label(bind: caption), "caption-\(title)")
                field = tx.entry(onChange: { _, text in scope.set("body", text) })
                tx.setA11yId(field, "body-\(title)")
                tx.setA11yId(
                    tx.button("recall", onClick: { t in
                        let now = KayaApp.documentSession(id).get("title", default: "untitled")
                        t.write(caption, .str("\(now) body"))
                    }), "recall-\(title)")
                return root
            })
            tx.setText(field, scope.get("body", default: ""))
        }
        if active != 0 {
            tx.selectDocument(active)
        }
    }
}
