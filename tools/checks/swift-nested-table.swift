// The DYNAMIC-TABLE surface, Swift arm: the one place this binding's
// nested-table spelling is COMPILED (tools/swift-typecheck.sh runs it).
// No guest ships a table-per-row scene in Swift, so without this pass the
// surface is held by tools/tpl-surfaces.py alone — and a census reads
// text, not types.

import Foundation

private let kayaPositionTitles = ["Symbol", "Shares"]

/// The nested table's ROW TYPE: two named fields, which is what a table
/// inside a row template is for (docs/deferred.md, the
/// nested-record-collection gap).
struct KayaPosition: KayaRecord {
    var symbol: String
    var shares: String

    static let prototype = KayaPosition(symbol: "", shares: "")

    init(symbol: String, shares: String) {
        self.symbol = symbol
        self.shares = shares
    }

    init(values: [KayaValue]) {
        guard case .str(let symbol) = values[0], case .str(let shares) = values[1] else {
            preconditionFailure("kaya: KayaPosition fields out of order")
        }
        self.init(symbol: symbol, shares: shares)
    }
}

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
                    // SLICE 1) — AND record-typed, so the row's two cells
                    // are the record's two fields rather than the one
                    // string a scalar collection's element can be.
                    let positions = account.collection(of: KayaPosition.self)
                    let table = account.each(positions.collection) { position in
                        _ = position.row {
                            positions.label(position, \.symbol)
                            positions.label(position, \.shares)
                        }
                    }
                    // AFTER the nested For closed, in the parent's still
                    // open scope: where this op finds its For.
                    account.columns(table, kayaPositionTitles, .none)
                    app.onSort(table) { tx, keys, column in
                        // The copy's key path IS the message, and `at`
                        // KEEPS THE RECORD TYPE: a KayaCollection here
                        // would take a bare KayaValue and the row's
                        // fields would be unreachable.
                        let instance = positions.at(keys[0])
                        for entry in instance.items(tx) {
                            instance.moveToEnd(tx, entry.key)
                        }
                        instance.patch(tx, .str("aapl")).set(\.shares, "20")
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
