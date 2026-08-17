// The toolbar conformance scene, Swift port: the `primary` bit as real
// window chrome (docs/chrome-plan.md C2). The app declares ONE catalog
// and marks two actions primary; every host promotes the same first two
// in catalog preorder — the desktop's toolbar, the phones' top bar —
// and the rest of the catalog stays reachable where that host keeps it.
//
// There is no toolbar vocabulary to spell here, and that is the point:
// this guest is the menus guest with a promotion bit and no new call.
// Canonical semantics in guests/rust/toolbar.rs; the byte-frozen
// contract in tools/scenes/toolbar.steps.

import Foundation

let app = KayaApp()

// The guest's own copy of the enablement, flipped by the button. The
// signal is the model; this is only what "the other one" means.
var saveEnabled = true

app.build { tx in
    let status = tx.signal(.str("ready"))
    // The one signal the enablement round-trip turns on. The app writes
    // it against the MENU ITEM and says nothing about any button: the
    // promoted button is that same item, so it follows or the lowering
    // kept a copy.
    let canSave = tx.signal(.bool(true))

    // CATALOG PREORDER DECIDES PROMOTION — top-level groupings in
    // menubar-append order, then each node's children in append order,
    // depth-first. Save is the first primary and Find the second, so
    // every host's promoted set is [Save, Find] however large its own k
    // is.
    let file = tx.menu(
        "File",
        items: [
            // `done` is the checkmark idiom: the vocabulary has no
            // save-specific glyph, and neither does Apple's own catalog
            // (docs/styling-plan.md D6).
            tx.item(
                "Save", shortcut: "primary+s", enabled: canSave, symbol: .done,
                primary: true
            ) { t in
                t.write(status, .str("saved"))
            },
            tx.item("Export", symbol: .forward) { t in
                t.write(status, .str("exported"))
            },
        ])
    let edit = tx.menu(
        "Edit",
        items: [
            tx.item("Find", symbol: .search, primary: true) { t in
                t.write(status, .str("found"))
            },
            // The remainder: everything below is catalog, not chrome, on
            // every platform — which is what makes the bare
            // expect_toolbar's second half a real question.
            tx.item("Replace", symbol: .edit),
        ])
    let view = tx.menu(
        "View",
        items: [
            tx.item("Refresh", symbol: .refresh),
            tx.item("Info", symbol: .info),
        ])
    tx.window(title: "toolbar", menus: [file, edit, view])

    let root = tx.column {
        tx.label(bind: status)  // label#0
        tx.button("toggle save") { t in  // button#0
            saveEnabled = !saveEnabled
            t.write(canSave, .bool(saveEnabled))
        }
    }
    tx.mount(root)
}

app.run()
