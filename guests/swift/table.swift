// The table scene, Swift port — guests/rust/table.rs,
// tools/scenes/table.steps.

import Foundation

struct TableItem: KayaGen {
    var name: String
    var size: String
}

let app = KayaApp()

// The guest's sort policy; the platform never has one.
var sortedCol: Int64 = -1
var sortedDesc = false

app.build { tx in
    let items = tableItemCollection(tx)
    // The root is a row so the For's container is the scene's only
    // column-kind widget (the reorder scene's rule).
    let root = tx.row {
        let table = tableItemEach(tx, items) { row in
            _ = row.row {
                row.label(row.name)
                row.label(row.size)
            }
        }
        // Grown on purpose: ungrown would hug its rows (docs/tables-plan.md
        // decision 8).
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
            // Keys, never indices.
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
