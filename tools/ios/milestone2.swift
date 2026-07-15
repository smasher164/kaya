// The milestone-2 scene from Swift, on the idiomatic surface
// (KayaApp.swift): typed handles instead of hand-numbered ids, trailing
// closures instead of template_end bookkeeping, and click handlers
// instead of a hand-rolled dispatch loop. The wire vocabulary
// underneath (KayaWire.swift) is generated from kaya::spec by
// kaya-bindgen; the kaya C declarations come from kaya.h via
// -import-objc-header.

import Foundation

let app = KayaApp()

var status: KayaSignal!
var extras: KayaSignal!
var step: KayaWidget!
var groups: KayaCollection!
var items: KayaCollection!
var removeButton: KayaNodeHandle!

app.build { tx in
    status = tx.signal(.str("step 0"))
    extras = tx.signal(.bool(false))

    let column = tx.widget(UInt32(KAYA_KIND_COLUMN))
    step = tx.widget(UInt32(KAYA_KIND_BUTTON))
    tx.setText(step, "step")
    let statusLabel = tx.widget(UInt32(KAYA_KIND_LABEL))
    tx.bindText(statusLabel, status)

    let banner = tx.when(extras) { t in
        let bannerLabel = t.widget(UInt32(KAYA_KIND_LABEL))
        t.setText(bannerLabel, "extras on")
    }

    groups = tx.collection()
    let groupList = tx.forEach(groups) { t in
        let groupColumn = t.widget(UInt32(KAYA_KIND_COLUMN))
        let name = t.widget(UInt32(KAYA_KIND_LABEL))
        t.bindTextElement(name)
        t.addChild(groupColumn, name)

        items = t.collection()
        let itemList = t.forEach(items) { item in
            let row = item.widget(UInt32(KAYA_KIND_COLUMN))
            let text = item.widget(UInt32(KAYA_KIND_LABEL))
            item.bindTextElement(text)
            removeButton = item.widget(UInt32(KAYA_KIND_BUTTON))
            item.setText(removeButton, "remove")
            item.addChild(row, text)
            item.addChild(row, removeButton)
        }
        t.addChild(groupColumn, itemList)
    }

    tx.addChild(column, step)
    tx.addChild(column, statusLabel)
    tx.addChild(column, banner)
    tx.addChild(column, groupList)
    tx.mount(column)
}

var steps = 0
app.onClick(step) { tx in
    steps += 1
    if steps == 1 {
        tx.insert(groups, [], .str("g1"), .str("Work"))
        tx.insert(items, [.str("g1")], .str("a"), .str("send report"))
        tx.insert(items, [.str("g1")], .str("b"), .str("buy milk"))
    } else if steps == 2 {
        tx.insert(groups, [], .str("g2"), .str("Home"))
        tx.insert(items, [.str("g2")], .str("a"), .str("water plants"))
        tx.update(groups, [], .str("g1"), .str("Office"))
    }
    tx.write(extras, .bool(steps == 1))
    tx.write(status, .str("step \(steps)"))
}

app.onClick(removeButton) { tx, keys in
    guard case .str(let group) = keys[0], case .str(let item) = keys[1] else { return }
    tx.remove(items, [.str(group)], .str(item))
    tx.write(status, .str("removed \(group)/\(item)"))
}

// Takes over the main thread; on iOS this never returns (the self-test
// exits the process).
app.run()
