// The menus scene, Swift port — guests/rust/menus.rs,
// tools/scenes/menus.steps.

import Foundation

let app = KayaApp()

let (groups, items) = app.build { tx -> (KayaCollection, KayaCollection) in
    let status = tx.signal(.str("ready"))
    let canExport = tx.signal(.bool(false))
    let details = tx.signal(.bool(false))
    let sort = tx.signal(.f64(0.0))

    let onShare: (KayaAppTx) throws -> Void = { t in t.write(status, .str("shared")) }

    let share = tx.item("Share", primary: true, onActivate: onShare)
    let file = tx.menu(
        "File", enabled: canExport,
        items: [
            // No `save` in the symbol vocabulary; `done` is the checkmark
            // idiom (docs/styling-plan.md D6).
            tx.item("Save", shortcut: "primary+s", symbol: .done) { t in
                t.write(status, .str("saved"))
            },
            tx.item("Export", enabled: canExport, symbol: .forward),
            share,
        ])
    let view = tx.menu(
        "View",
        items: [
            tx.toggle("Details", checked: details, symbol: .info) { t, on in
                t.write(status, .str(on ? "details on" : "details off"))
            }
        ])
    // Option order IS the index vocabulary: Name = 0, Date = 1.
    let sortGroup = tx.radioGroup(
        "Sort", options: [tx.option("Name"), tx.option("Date")], value: sort
    ) { t, index in
        t.write(status, .str(index == 1 ? "sorted date" : "sorted name"))
    }
    tx.window(title: "menus", menus: [file, view, sortGroup])

    let groups = tx.collection()
    var itemsOut: KayaCollection!
    let catalog = tx.contextCatalog(items: [
        tx.item("Remove", symbol: .delete) { t, keys in
            guard case .str(let group) = keys[0], case .str(let item) = keys[1] else {
                return
            }
            t.remove(itemsOut.at(.str(group)), .str(item))
            t.write(status, .str("removed \(group)/\(item)"))
        }
    ])

    let root = tx.column {
        tx.label(bind: status)  // label#0
        tx.button("enable export") { t in  // button#0
            t.write(canExport, .bool(true))
        }
        tx.button("reset menu state") { t in  // button#1
            t.write(details, .bool(false))
            t.write(sort, .f64(0.0))
            t.write(status, .str("ready"))
        }
        tx.button("extend menus") { t in  // button#2
            t.menu(share, primary: false)
            t.menu(
                file, label: "Document",
                items: [
                    t.item("Publish", symbol: .copy, primary: true, onActivate: onShare)
                ])
            t.window(menus: [t.menu("Tools", items: [t.item("Inspect", symbol: .search)])])
        }

        let targetText = tx.signal(.str("rename target"))
        let target = tx.label(bind: targetText)  // label#1
        tx.contextMenu(
            target,
            items: [
                tx.item("Rename", symbol: .edit) { t in
                    t.write(status, .str("renamed"))
                }
            ])

        tx.each(groups) { g in
            let items = g.collection()
            itemsOut = items
            // A bare mention in the builder is DISCARDED, so the For is
            // declared INSIDE the column (docs/traps.md, result builders).
            _ = g.column {
                g.each(items) { r in
                    // label#2 once g2/a stamps.
                    let row = r.label(KayaField<String>.element)
                    r.contextMenu(row, catalog)
                }
            }
        }
    }
    tx.mount(root)
    return (groups, itemsOut)
}

// Seeded after the mount, so the copy stamps from a closed template.
app.build { tx in
    tx.insert(groups, .str("g2"), .str("Home"))
    tx.insert(items.at(.str("g2")), .str("a"), .str("water plants"))
}

app.run()
