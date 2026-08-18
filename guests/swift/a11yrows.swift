// The stamped-accessibility scene from Swift: two entries stamped from
// ONE template, each carrying its OWN ROW's accessibility identity, read
// back out of the platform's real tree. See guests/rust/a11yrows.rs and
// tools/scenes/a11yrows.steps.
//
// A SEPARATE SCENE BY DESIGN, not by size: a For materializes as a
// column and container creation order differs by language, so the a11y
// scene — which asserts every container kind ordinally — cannot host
// one. This scene asserts no container, so the For's column may land
// anywhere in the registry.

import Foundation

let app = KayaApp()

app.build { tx in
    let notes = tx.collection()
    let heads = tx.collection()
    let root = tx.column {
        tx.each(notes) { t in
            // BOTH PROPS ELEMENT-SOURCED. The id is forced: expect_ax
            // searches the real tree BY the authored identifier and
            // refuses an ambiguous one (docs/tpl-props-plan.md).
            let field = t.entry()  // entry#0 and entry#1 once the rows stamp
            t.setA11yId(field, KayaField<String>.element)
            t.setA11yLabel(field, KayaField<String>.element)
        }

        // THE STAMPED STYLING PROPS, in a second collection because
        // expect_ax refuses an ambiguous id and a scalar row has one
        // field to spend on one. Both props are CONST: what a copy MEANS
        // is a fact about the prototype, not about the row's data.
        tx.each(heads) { t in
            let bar = t.row {
                let title = t.label(KayaField<String>.element)
                t.setRole(title, .heading)
                t.setA11yId(title, KayaField<String>.element)
            }
            t.setInset(bar, 8)
        }
    }
    // OUTSIDE THE BUILDER, BEFORE THE MOUNT: an insert is not a child.
    // Seeding after the mount also stamps (reorder.swift does it), so
    // this is a difference with no upside rather than a rule.
    tx.insertFresh(notes, .str("First note"))
    tx.insertFresh(notes, .str("Second note"))
    tx.insertFresh(heads, .str("Heading one"))
    tx.insertFresh(heads, .str("Heading two"))
    tx.mount(root)
}

app.run()
