// The toolbar scene, Swift port — guests/rust/toolbar.rs,
// tools/scenes/toolbar.steps.

import Foundation

let app = KayaApp()

var saveEnabled = true

app.build { tx in
    let status = tx.signal(.str("ready"))
    // Written against the MENU ITEM: the promoted button IS that item.
    let canSave = tx.signal(.bool(true))

    // CATALOG PREORDER DECIDES PROMOTION — menubar-append order, then children
    // depth-first, so every host promotes [Save, Find].
    let file = tx.menu(
        "File",
        items: [
            // `done` is the checkmark idiom (docs/styling-plan.md D6).
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
