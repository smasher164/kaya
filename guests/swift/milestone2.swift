// The milestone-2 scene from Swift, on the construction sugar. The wire
// vocabulary underneath (KayaWire.swift) is generated from kaya::spec by
// kaya-bindgen; the C declarations come from kaya.h via
// -import-objc-header.
//
// WHAT THIS SCENE DOCUMENTS IS HOW OCCURRENCES REACH AN APP, and only
// that. The remove button is a STAMPED copy, so its handler registers
// CENTRALLY against the template node and receives that copy's key
// path — the only way to know WHICH remove was clicked. The live step
// button rides its constructor instead; both put the same closure in
// the same table.
//
// AND THE APP NAMES EVERY KEY HERE: g1 and a are the app's own
// identity, re-addressed later by name. insertFresh answers the
// opposite case (docs/fresh-key-plan.md).

import Foundation

let app = KayaApp()

var steps = 0

let (status, items, removeButton) = app.build {
    tx -> (KayaSignal, KayaCollection, KayaNodeHandle) in
    let status = tx.signal(.str("step 0"))
    // The step count as a signal, so the banner's condition is derived.
    let stepCount = tx.signal(.i64(0))
    let groups = tx.collection()

    // The two handles the central registration below needs. A node
    // parents at CREATION, so both are built inside the template bodies
    // that hold them (docs/traps.md, result builders).
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
        // The When and the Fors parent themselves where they stand.
        tx.when(stepCount == 1) { t in t.label("extras on") }.0
        tx.each(groups) { g in
            _ = g.column {
                // A scalar collection's element IS its one wire field, so
                // the row's label addresses field 0.
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
