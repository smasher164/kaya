// The reorder scene from Swift: order as collection data. Each handler
// repositions an entry BY KEY (collection_move on the wire) and never
// touches a widget. THE ROOT IS A ROW so the For's container is the
// scene's only column-kind widget: languages disagree on whether
// containers are created before or after their children, and column#0
// must name the same widget everywhere.

import Foundation

struct Item: KayaGen {
    var title: String
}

let app = KayaApp()

app.build { tx in
    let items = itemCollection(tx)
    let root = tx.row {
        tx.button("rotate") { tx in
            let entries = items.items(tx)
            items.moveToEnd(tx, entries[0].key)
        }
        tx.button("lift") { tx in
            // Last entry to the front — the same wire op, keys never
            // indices.
            let entries = items.items(tx)
            items.moveToFront(tx, entries[entries.count - 1].key)
        }
        for row in items.rows {
            row.label(row.title)
        }
    }
    tx.mount(root)
    for key in ["a", "b", "c"] {
        items.insert(tx, .str(key), Item(title: key))
    }
}

app.run()
