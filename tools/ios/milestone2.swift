// The milestone-2 scene from Swift, on the idiomatic surface
// (KayaApp.swift): typed handles instead of hand-numbered ids, trailing
// closures instead of template_end bookkeeping, and click handlers
// instead of a hand-rolled dispatch loop. Handles declared inside a
// template escape as the body's return value — build and forEach hand
// them back out, so nothing leaks through mutable globals. The wire
// vocabulary underneath (KayaWire.swift) is generated from kaya::spec
// by kaya-bindgen; the kaya C declarations come from kaya.h via
// -import-objc-header.

import Foundation

let app = KayaApp()

let (status, extras, step, groups, items, removeButton) = app.build {
    tx -> (KayaSignal, KayaSignal, KayaWidget, KayaCollection, KayaCollection, KayaNodeHandle) in
    let status = tx.signal(.str("step 0"))
    let extras = tx.signal(.bool(false))

    let column = tx.widget(UInt32(KAYA_KIND_COLUMN))
    let step = tx.widget(UInt32(KAYA_KIND_BUTTON))
    tx.setText(step, "step")
    let statusLabel = tx.widget(UInt32(KAYA_KIND_LABEL))
    tx.bindText(statusLabel, status)

    let (banner, _) = tx.when(extras) { t in
        let bannerLabel = t.widget(UInt32(KAYA_KIND_LABEL))
        t.setText(bannerLabel, "extras on")
    }

    let groups = tx.collection()
    let (groupList, (items, removeButton)) = tx.forEach(groups) {
        t -> (KayaCollection, KayaNodeHandle) in
        let groupColumn = t.widget(UInt32(KAYA_KIND_COLUMN))
        let name = t.widget(UInt32(KAYA_KIND_LABEL))
        t.bindTextElement(name)
        t.addChild(groupColumn, name)

        let items = t.collection()
        let (itemList, remove) = t.forEach(items) { item -> KayaNodeHandle in
            let row = item.widget(UInt32(KAYA_KIND_COLUMN))
            let text = item.widget(UInt32(KAYA_KIND_LABEL))
            item.bindTextElement(text)
            let remove = item.widget(UInt32(KAYA_KIND_BUTTON))
            item.setText(remove, "remove")
            item.addChild(row, text)
            item.addChild(row, remove)
            return remove
        }
        t.addChild(groupColumn, itemList)
        return (items, remove)
    }

    tx.addChild(column, step)
    tx.addChild(column, statusLabel)
    tx.addChild(column, banner)
    tx.addChild(column, groupList)
    tx.mount(column)
    return (status, extras, step, groups, items, removeButton)
}

var steps = 0
app.onClick(step) { tx in
    steps += 1
    if steps == 1 {
        tx.insert(groups, .str("g1"), .str("Work"))
        let todos = items.at(.str("g1"))
        tx.insert(todos, .str("a"), .str("send report"))
        tx.insert(todos, .str("b"), .str("buy milk"))
    } else if steps == 2 {
        tx.insert(groups, .str("g2"), .str("Home"))
        tx.insert(items.at(.str("g2")), .str("a"), .str("water plants"))
        tx.update(groups, .str("g1"), .str("Office"))
    }
    tx.write(extras, .bool(steps == 1))
    tx.write(status, .str("step \(steps)"))
}

app.onClick(removeButton) { tx, keys in
    guard case .str(let group) = keys[0], case .str(let item) = keys[1] else { return }
    // The instance handle names the target once; mutation and read hang
    // off the same value. The collection is the model: the count read
    // is the fold of the patches, this one included.
    let todos = items.at(.str(group))
    tx.remove(todos, .str(item))
    let left = tx.count(todos)
    tx.write(status, .str("removed \(group)/\(item), \(left) left"))
}

// Takes over the main thread; on iOS this never returns (the self-test
// exits the process).
app.run()
