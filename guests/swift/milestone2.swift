// The milestone2 scene, Swift port — guests/rust/milestone2.rs,
// tools/scenes/milestone2.steps.

import Foundation

let app = KayaApp()

var steps = 0

let (status, items, removeButton) = app.build {
    tx -> (KayaSignal, KayaCollection, KayaNodeHandle) in
    let status = tx.signal(.str("step 0"))
    let stepCount = tx.signal(.i64(0))
    let groups = tx.collection()

    // A node parents at CREATION, so both handles are built inside the
    // template bodies (docs/traps.md, result builders).
    var items: KayaCollection! = nil
    var removeButton: KayaNodeHandle! = nil

    let root = tx.column {
        tx.button("step") { t in
            steps += 1
            if steps == 1 {
                t.insert(groups, .str("g1"), .str("Work"))
                let todos = items.at(.str("g1"))
                t.insert(todos, .str("a"), .str("send report"))
                t.insert(todos, .str("b"), .str("buy milk"))
            } else if steps == 2 {
                t.insert(groups, .str("g2"), .str("Home"))
                t.insert(items.at(.str("g2")), .str("a"), .str("water plants"))
                t.update(groups, .str("g1"), .str("Office"))
            }
            t.write(stepCount, .i64(Int64(steps)))
            t.write(status, .str("step \(steps)"))
        }
        tx.label(bind: status)
        tx.when(stepCount == 1) { t in t.label("extras on") }.0
        tx.each(groups) { g in
            _ = g.column {
                g.label(KayaField<String>(index: 0))
                let todos = g.collection()
                items = todos
                g.each(todos) { item in
                    _ = item.column {
                        item.label(KayaField<String>(index: 0))
                        removeButton = item.button("remove")
                    }
                }
            }
        }
    }
    tx.mount(root)
    return (status, items, removeButton)
}

app.onClick(removeButton) { tx, keys in
    guard case .str(let group) = keys[0], case .str(let item) = keys[1] else { return }
    let todos = items.at(.str(group))
    tx.remove(todos, .str(item))
    let left = tx.count(todos)
    tx.write(status, .str("removed \(group)/\(item), \(left) left"))
}

// Takes over the main thread; on iOS this never returns.
app.run()
