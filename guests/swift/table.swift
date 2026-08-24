// The table scene from Swift: column headers and click-to-sort on the
// For vocabulary (docs/tables-plan.md). A header click is a REQUEST —
// this guest reorders its collection BY KEY (the reorder scene's
// idiom) and re-declares the header with the new indicator; the
// platform sorts nothing. The byte-frozen contract is
// tools/scenes/table.steps.

import Foundation

struct TableItem: KayaGen {
    var name: String
    var size: String
}

let app = KayaApp()

// The guest's sort policy — the platform never has one: clicking the
// sorted column flips it, clicking another starts ascending.
var sortedCol: Int64 = -1
var sortedDesc = false

app.build { tx in
    let items = tableItemCollection(tx)
    // The root is a row so the For's container is the scene's only
    // column-kind widget (the reorder scene's rule). The table IS the
    // For, headers declared on the widget the template form returns.
    let root = tx.row {
        let table = tableItemEach(tx, items) { row in
            _ = row.row {
                row.label(row.name)
                row.label(row.size)
            }
        }
        // Grown on purpose: this scene asserts the fill-and-scroll
        // viewport, the grown half of the empty-row ruling — ungrown
        // would hug its rows (tables-plan decision 8).
        tx.setGrow(table, 1)
        tx.columns(table, ["Name", "Size"], .none)
        app.onSort(table) { tx, column in
            let desc = sortedCol == Int64(column) && !sortedDesc
            sortedCol = Int64(column)
            sortedDesc = desc
            var entries = items.items(tx)
            entries.sort { a, b in
                let (ka, kb) = column == 0 ? (a.value.name, b.value.name) : (a.value.size, b.value.size)
                return desc ? ka > kb : ka < kb
            }
            // Keys, never indices: moving each key to the end in the
            // target order leaves the collection sorted.
            for e in entries {
                items.moveToEnd(tx, e.key)
            }
            tx.columns(table, ["Name", "Size"], desc ? .desc(column) : .asc(column))
        }
    }
    tx.mount(root)
    for (key, name, size) in [("b", "banana", "30"), ("a", "apple", "10"), ("c", "cherry", "20")] {
        items.insert(tx, .str(key), TableItem(name: name, size: size))
    }
}

app.run()
