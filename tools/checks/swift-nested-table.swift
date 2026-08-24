// The DYNAMIC-TABLE surface, Swift arm: the one place this binding's
// nested-table spelling is COMPILED. No guest ships a table-per-row
// scene in Swift, so without this pass the surface is held by
// tools/tpl-surfaces.py alone — and a census reads text, not types.
// Typecheck-only, as one module with the bindings; tools/swift-typecheck.sh
// runs it:
//
//   swiftc -typecheck -import-objc-header crates/kaya/include/kaya.h \
//     bindings/swift/KayaWire.swift bindings/swift/KayaApp.swift \
//     bindings/swift/KayaRecords.swift bindings/swift/KayaSums.swift \
//     tools/checks/swift-nested-table.swift

import Foundation

private let kayaPositionTitles = ["Symbol", "Shares"]

/// One table per account: the accounts For stamps a card, each card
/// stamps its OWN positions For, and that nested For's bar is declared
/// once for every copy (docs/tables-plan.md, dynamic tables).
func kayaNestedTableSurface(_ app: KayaApp) {
    app.build { tx in
        let accounts = tx.collection()
        let root = tx.column {
            tx.each(accounts) { account in
                _ = account.column {
                    account.label(KayaField<String>(index: 0))
                    // Declared INSIDE the template scope — the core's
                    // own-scope wall (docs/tables-plan.md, MEASURED IN
                    // SLICE 1).
                    let positions = account.collection()
                    let table = account.each(positions) { position in
                        _ = position.row {
                            position.label(KayaField<String>(index: 0))
                            position.label(KayaField<String>(index: 0))
                        }
                    }
                    // AFTER the nested For closed, in the parent's still
                    // open scope: where this op finds its For.
                    account.columns(table, kayaPositionTitles, .none)
                    app.onSort(table) { tx, keys, column in
                        // The copy's key path IS the message: reorder
                        // THAT copy's instance and move THAT copy's
                        // indicator — a sibling's bar does not stir.
                        let instance = positions.at(keys[0])
                        for entry in tx.items(instance) {
                            tx.moveToEnd(instance, entry.key)
                        }
                        tx.columns(
                            table, at: keys, kayaPositionTitles,
                            column == 0 ? .asc(column) : .desc(column))
                    }
                }
            }
        }
        tx.mount(root)
    }
}
