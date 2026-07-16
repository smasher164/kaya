// The milestone-2 scene from Swift, on the construction sugar: typed
// handles, constructors carrying their handlers, result-builder
// containers taking their children, and trailing closures instead of
// template_end bookkeeping. Handles declared inside a template escape
// as the body's return value — build and forEach hand them back out,
// so nothing leaks through mutable globals. The wire vocabulary
// underneath (KayaWire.swift) is generated from kaya::spec by
// kaya-bindgen; the kaya C declarations come from kaya.h via
// -import-objc-header.

import Foundation

let app = KayaApp()

var steps = 0

let (status, items, removeButton) = app.build {
    tx -> (KayaSignal, KayaCollection, KayaNodeHandle) in
    let status = tx.signal(.str("step 0"))
    let extras = tx.signal(.bool(false))

    let (banner, _) = tx.when(extras) { t in
        let bannerLabel = t.widget(UInt32(KAYA_KIND_LABEL))
        t.setText(bannerLabel, "extras on")
    }

    let groups = tx.collection()
    let (groupList, (items, removeButton)) = tx.forEach(groups) {
        t -> (KayaCollection, KayaNodeHandle) in
        let name = t.widget(UInt32(KAYA_KIND_LABEL))
        t.bindTextElement(name)

        let items = t.collection()
        let (itemList, remove) = t.forEach(items) { item -> KayaNodeHandle in
            let text = item.widget(UInt32(KAYA_KIND_LABEL))
            item.bindTextElement(text)
            let remove = item.widget(UInt32(KAYA_KIND_BUTTON))
            item.setText(remove, "remove")
            _ = item.column {
                text
                remove
            }
            return remove
        }
        _ = t.column {
            name
            itemList
        }
        return (items, remove)
    }

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
            t.write(extras, .bool(steps == 1))
            t.write(status, .str("step \(steps)"))
        }
        tx.label(bind: status)
        banner
        groupList
    }
    tx.mount(root)
    return (status, items, removeButton)
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
