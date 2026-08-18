// The menus conformance scene, Swift port: the command vocabulary (a
// File/View/Sort menu bar, context menus on a live label and on stamped
// rows) and the uncontrolled-menu echo doctrine. See
// guests/rust/menus.rs and tools/scenes/menus.steps.

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
            // A semantic icon is a CONCEPT drawn per platform; `done` is
            // the checkmark idiom (docs/styling-plan.md D6).
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
    // Catalog built live: items are shared across stamped copies; the
    // template only attaches, and each activation carries its key path.
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
            // The folds never echo the user's pick; these writes reset
            // the user-state mirror.
            t.write(details, .bool(false))
            t.write(sort, .f64(0.0))
            t.write(status, .str("ready"))
        }
        tx.button("extend menus") { t in  // button#2
            // Append-only: rename the retained File, move the promotion
            // hint, grow the bar by Tools.
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

        // Remove's activation names BOTH keys (group, then item).
        //
        // `each` and not `forEach`: neither For hands anything back
        // (docs/tpl-props-plan.md §2 F2).
        tx.each(groups) { g in
            let items = g.collection()
            itemsOut = items
            // The For is declared INSIDE the column it belongs to and
            // parents itself there at creation; a bare mention in the
            // builder is DISCARDED (docs/traps.md, result builders).
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

// Seed after mount: the stamp path attaches the shared catalog and keys.
app.build { tx in
    tx.insert(groups, .str("g2"), .str("Home"))
    tx.insert(items.at(.str("g2")), .str("a"), .str("water plants"))
}

app.run()
