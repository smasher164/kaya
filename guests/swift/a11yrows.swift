// The a11yrows scene, Swift port — guests/rust/a11yrows.rs,
// tools/scenes/a11yrows.steps.

import Foundation

let app = KayaApp()

app.build { tx in
    let notes = tx.collection()
    let heads = tx.collection()
    let root = tx.column {
        tx.each(notes) { t in
            // Element-sourced: expect_ax refuses an ambiguous authored id
            // (docs/tpl-props-plan.md).
            let field = t.entry()  // entry#0 and entry#1 once the rows stamp
            t.setA11yId(field, KayaField<String>.element)
            t.setA11yLabel(field, KayaField<String>.element)
        }

        // A SECOND COLLECTION because a scalar row has one field to spend
        // on an id.
        tx.each(heads) { t in
            let bar = t.row {
                let title = t.label(KayaField<String>.element)
                t.setRole(title, .heading)
                t.setA11yId(title, KayaField<String>.element)
            }
            t.setInset(bar, 8)
        }
    }
    tx.insertFresh(notes, .str("First note"))
    tx.insertFresh(notes, .str("Second note"))
    tx.insertFresh(heads, .str("Heading one"))
    tx.insertFresh(heads, .str("Heading two"))
    tx.mount(root)
}

app.run()
