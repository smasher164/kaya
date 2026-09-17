// The reorder scene, Swift port — guests/rust/reorder.rs,
// tools/scenes/reorder.steps.

import Foundation

struct Item: KayaGen {
    var title: String
}

let app = KayaApp()

app.build { tx in
    let items = itemCollection(tx)
    let root = tx.row { root in
        tx.button("rotate") { tx in
            let entries = items.items(tx)
            items.moveToEnd(tx, entries[0].key)
        }
        tx.button("lift") { tx in
            // Keys, never indices.
            let entries = items.items(tx)
            items.moveToFront(tx, entries[entries.count - 1].key)
        }
        for row in items.rows {
            _ = row.label(row.title)
        }
        return root
    }
    tx.mount(root)
    for key in ["a", "b", "c"] {
        items.insert(tx, .str(key), Item(title: key))
    }
}

app.run()
