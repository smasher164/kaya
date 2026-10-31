// The search scene, Swift port — guests/rust/search.rs,
// tools/scenes/search.steps. The app owns the predicate
// (docs/search-plan.md S9) and each row hides in place
// (docs/hidden-plan.md).

import Foundation
import Kaya

struct SearchItem: KayaGen {
    var name: String
    var unmatched: Bool
}

let names = ["apple", "banana", "cherry", "mango"]

KayaApp.run { app in
    app.build { tx in
        tx.window(title: "search")
        let items = searchItemCollection(tx)
        let count = tx.signal(.str("\(names.count) items"))

        let root = tx.column { root in
            let find = tx.search { t, text in
                let query = text.lowercased()
                // Swift's String.contains("") is FALSE where every other
                // language's substring test is true, so the empty query is
                // spelled out: an empty field shows the whole list.
                let wanted = names.filter { query.isEmpty || $0.contains(query) }
                for name in names {
                    items.patch(t, .str(name)).set(\.unmatched, !wanted.contains(name))
                }
                t.write(count, .str(query.isEmpty
                    ? "\(names.count) items"
                    : "\(wanted.count) of \(names.count) match"))
            }
            tx.setPlaceholder(find, "Search")
            tx.setA11yId(find, "find")
            tx.setA11yLabel(find, "Find items")
            tx.setA11yId(tx.label(bind: count), "count")
            // The For IS the list: expect_order reads its label children.
            let list = searchItemEach(tx, items) { row in
                row.t.setHidden(row.label(row.name), row.unmatched)
            }
            tx.setA11yId(list, "list")
            return root
        }
        tx.mount(root)

        for name in names {
            items.insert(tx, .str(name), SearchItem(name: name, unmatched: false))
        }
    }
}
