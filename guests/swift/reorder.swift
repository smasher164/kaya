// The reorder scene from Swift: order as collection data, end to end.
// Three stamped rows and two buttons that never touch a widget — each
// handler repositions an entry by key (collection_move on the wire,
// move_child at the toolkit), and the selftest's expect_order reads
// the toolkit's actual child order back. The root is a row so the
// For's container is the scene's only column-kind widget: languages
// disagree on whether containers are created before or after their
// children, and column#0 must name the same widget everywhere.

import Foundation

struct Item: KayaRecord {
    var title: String

    static let prototype = Item(title: "")

    init(title: String) {
        self.title = title
    }

    init(values: [KayaValue]) {
        guard case .str(let title) = values[0] else {
            preconditionFailure("kaya: Item fields out of order")
        }
        self.init(title: title)
    }
}

let app = KayaApp()

app.build { tx in
    let items = tx.collection(of: Item.self)
    let root = tx.row {
        tx.button("rotate") { tx in
            // First entry to the end. The model owns the order, so the
            // handler asks it which key is first — it never counts
            // widgets.
            let entries = items.items(tx)
            items.moveToEnd(tx, entries[0].key)
        }
        tx.button("lift") { tx in
            // Last entry to the front: moveToFront is sugar for
            // moveBefore the current first key — the same wire op,
            // keys never indices.
            let entries = items.items(tx)
            items.moveToFront(tx, entries[entries.count - 1].key)
        }
        tx.each(items.collection) { t in
            _ = items.label(t, \.title)
        }
    }
    tx.mount(root)
    for key in ["a", "b", "c"] {
        items.insert(tx, .str(key), Item(title: key))
    }
}

app.run()
