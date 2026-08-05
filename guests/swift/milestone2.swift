// The milestone-2 scene from Swift, on the construction sugar: typed
// handles, constructors carrying their props, result-builder containers
// taking their children, and trailing closures instead of template_end
// bookkeeping. The wire vocabulary underneath (KayaWire.swift) is
// generated from kaya::spec by kaya-bindgen; the kaya C declarations
// come from kaya.h via -import-objc-header.
//
// WHAT THIS SCENE DOCUMENTS IS HOW OCCURRENCES REACH AN APP, and only
// that (DESIGN.md, the scope ratified 2026-08-05). The remove button is
// a STAMPED copy, so its handler is registered CENTRALLY, after the
// build, against the template node the build body handed back — and it
// receives that copy's key path, which is the only way to know WHICH
// remove was clicked. The live step button spells the other half of the
// same registry: its handler rides its constructor, because a live
// widget is its own noun. Both spellings put the same closure in the
// same table. Construction is the ordinary sugar every example that is
// not a C guest uses.
//
// AND THE APP NAMES EVERY KEY HERE, on purpose. "g1" and "a" are the
// app's own identity for a group and an item — the scene's driver
// re-addresses g1 to rename it ("Work" -> "Office") and the expected
// verdict says "removed g2/a", so the names are data the app chose and
// still knows. That is exactly what insertFresh is NOT for: the minted
// key answers "this row has no identity of its own" (entry.swift,
// todos.swift, docs/fresh-key-plan.md), and minting one here would only
// force the app to remember a name it already had.

import Foundation

let app = KayaApp()

var steps = 0

let (status, items, removeButton) = app.build {
    tx -> (KayaSignal, KayaCollection, KayaNodeHandle) in
    let status = tx.signal(.str("step 0"))
    // The step count as a signal, so the banner's condition is a
    // derived signal: `stepCount == 1` is eq in operator clothes,
    // recomputed on every write — no hand-maintained Bool, no handler
    // line for it.
    let stepCount = tx.signal(.i64(0))
    let groups = tx.collection()

    // The two handles the central registration below needs. A node
    // parents into its container AT CREATION, so both are built inside
    // the template bodies that hold them and ride out through these —
    // never declared outside and named within, which parents nothing.
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
        // The When and the Fors are declared WHERE THEY STAND, between
        // their siblings, and parent themselves there. Each hands back
        // its own container widget; the builder only carries it away,
        // the parenting having happened at creation.
        tx.when(stepCount == 1) { t in t.label("extras on") }.0
        tx.each(groups) { g in
            _ = g.column {
                // A scalar collection's element IS its one wire field,
                // so the row's label addresses field 0 — the token is
                // the address, and the constructor is the same `label`
                // the live zone uses.
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
