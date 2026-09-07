// The search scene, Swift port — guests/rust/search.rs,
// tools/scenes/search.steps. The app owns the filter
// (docs/search-plan.md S9): the visible set is a diff of removes and
// inserts by key.

import Foundation

struct SearchItem: KayaGen {
    var name: String
}

let names = ["apple", "banana", "cherry", "mango"]

let app = KayaApp()
var visible = names

app.build { tx in
    let items = searchItemCollection(tx)
    let count = tx.signal(.str("\(names.count) items"))

    let root = tx.column {
        let find = tx.search { t, text in
            let query = text.lowercased()
            // Swift's String.contains("") is FALSE where every other
            // language's substring test is true, so the empty query is
            // spelled out: an empty field shows the whole list.
            let wanted = names.filter { query.isEmpty || $0.contains(query) }
            // A DIFF, never clear-and-refill: only the rows whose
            // membership changed move (docs/search-plan.md S9).
            for name in visible where !wanted.contains(name) {
                items.remove(t, .str(name))
            }
            for name in wanted where !visible.contains(name) {
                items.insert(t, .str(name), SearchItem(name: name))
            }
            // Insertion order is arrival order, so a row coming back lands
            // last; walking the wanted keys to the end in order puts the
            // list back in `names` order.
            for name in wanted {
                items.moveToEnd(t, .str(name))
            }
            t.write(count, .str(query.isEmpty
                ? "\(names.count) items"
                : "\(wanted.count) of \(names.count) match"))
            visible = wanted
        }
        tx.setPlaceholder(find, "Search")
        tx.setA11yId(find, "find")
        tx.setA11yLabel(find, "Find items")
        tx.setA11yId(tx.label(bind: count), "count")
        // The For IS the list: expect_order reads its label children.
        let list = searchItemEach(tx, items) { row in
            row.label(row.name)
        }
        tx.setA11yId(list, "list")
    }
    tx.mount(root)

    for name in names {
        items.insert(tx, .str(name), SearchItem(name: name))
    }
}

app.run()
