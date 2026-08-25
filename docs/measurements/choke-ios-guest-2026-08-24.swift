// The row-count choke guest, modelled on guests/swift/table.swift: one
// collection, a 4-column table (date, ticker, side, total), row count
// from KAYA_ROWS. Strings are generated from a counter in the guest —
// deterministic, no asset reads. The scene script asserts the LAST
// row's total, so a pass proves the whole stamp reached the tree.
//
// MEASUREMENT ONLY. Lives outside the repo; the record conformance is
// hand-written here because kaya-swift-gen only walks guests/.

import Foundation

struct Txn: KayaRecord {
    var date: String
    var ticker: String
    var side: String
    var total: String

    init(date: String, ticker: String, side: String, total: String) {
        self.date = date
        self.ticker = ticker
        self.side = side
        self.total = total
    }

    static let prototype = Txn(date: "", ticker: "", side: "", total: "")

    init(values: [KayaValue]) {
        guard case .str(let date) = values[0], case .str(let ticker) = values[1],
            case .str(let side) = values[2], case .str(let total) = values[3]
        else {
            preconditionFailure("kaya: Txn fields out of order")
        }
        self.init(date: date, ticker: ticker, side: side, total: total)
    }
}

enum TxnFields {
    static let date = KayaField<String>(index: 0)
    static let ticker = KayaField<String>(index: 1)
    static let side = KayaField<String>(index: 2)
    static let total = KayaField<String>(index: 3)
}

/// Row i's cells, from a trivial counter — the same function the
/// harness expectation is built from, host side.
func txnRow(_ i: Int) -> Txn {
    let tickers = ["AAPL", "MSFT", "NVDA", "AMZN", "GOOG", "META", "TSLA", "AVGO"]
    let day = i % 28 + 1
    let month = i / 28 % 12 + 1
    return Txn(
        date: String(format: "2026-%02d-%02d", month, day),
        ticker: tickers[i % tickers.count],
        side: i % 2 == 0 ? "BUY" : "SELL",
        total: String(format: "%d.%02d", 100 + i, i % 100))
}

let rows = Int(ProcessInfo.processInfo.environment["KAYA_ROWS"] ?? "") ?? 3
/// 0 = the natural spelling: declare, mount and insert every row in ONE
/// transaction (guests/swift/table.swift's shape). >0 = rows inserted C
/// per transaction so no single apply batch exceeds the interpreter's
/// 64 KiB pump buffer. The mount stays in the FIRST transaction either
/// way: the core refuses a transaction that creates a widget no mounted
/// root reaches (scene.rs's orphan barrier), so an empty table mounted
/// first and filled by later transactions is the only legal chunking.
let chunk = Int(ProcessInfo.processInfo.environment["KAYA_CHUNK"] ?? "") ?? 0
let t0 = Date()

func kayaNote(_ what: String) {
    let line = "KAYA_CHOKE: rows=\(rows) chunk=\(chunk) \(what) "
        + "\(Int(Date().timeIntervalSince(t0) * 1000))ms\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

let app = KayaApp()

var sortedCol: Int64 = -1
var sortedDesc = false

var txnsHandle: KayaRecordCollection<Txn>! = nil
var rootHandle: KayaWidget! = nil

app.build { tx in
    let txns = tx.collection(of: Txn.self)
    var tableHandle: KayaWidget! = nil
    let root = tx.row {
        let table = tx.each(txns.collection) { t in
            _ = t.row {
                _ = t.label(TxnFields.date)
                _ = t.label(TxnFields.ticker)
                _ = t.label(TxnFields.side)
                _ = t.label(TxnFields.total)
            }
        }
        tx.setGrow(table, 1)
        tableHandle = table
    }
    // KAYA_NO_COLUMNS: the same rows through the GENERIC container path
    // (KayaFlex) instead of the synthesized table tier — identical node
    // count, no KayaTableLayout and no per-cell KayaEdgeReporter. The
    // A/B that says where the per-row cost is.
    if ProcessInfo.processInfo.environment["KAYA_NO_COLUMNS"] == nil {
        let table = tableHandle!
        tx.columns(table, ["Date", "Ticker", "Side", "Total"], .none)
        app.onSort(table) { tx, column in
            let desc = sortedCol == Int64(column) && !sortedDesc
            sortedCol = Int64(column)
            sortedDesc = desc
            tx.columns(
                table, ["Date", "Ticker", "Side", "Total"],
                desc ? .desc(column) : .asc(column))
        }
    }
    txnsHandle = txns
    rootHandle = root
    tx.mount(root)
    if chunk == 0 {
        for i in 0..<rows {
            txns.insert(tx, .str("k\(i)"), txnRow(i))
        }
    }
    kayaNote("guest-build")
}
kayaNote("guest-submitted")

if chunk > 0 {
    var at = 0
    while at < rows {
        let end = min(at + chunk, rows)
        app.build { tx in
            for i in at..<end {
                txnsHandle.insert(tx, .str("k\(i)"), txnRow(i))
            }
        }
        at = end
    }
    kayaNote("guest-chunks-submitted")
}
_ = rootHandle

app.run()
