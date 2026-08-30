// A GROWN TABLE STACKED UNDER A HUGGING SIBLING, driven for real —
// compiled INTO the interpreter's own module and run as an executable.
//
// This is the shape the portfolio's Transactions screen takes on a phone
// once its outer row flips to a column: a summary column that hugs, and a
// grown table under it that is supposed to take the rest and window its
// rows. On a phone the table's scroll clip measures ZERO HEIGHT and it
// windows nothing (docs/deferred.md, the grown-table entry).
//
// WHY A PROBE AND NOT A LEG: the mac app cannot reach this code at all.
// `kayaTableTier` gates on TableColumnForEach's AVAILABILITY, not on
// width, so a mac with a modern SDK always renders the NATIVE tier — a
// KAYA_LAYOUT_TRACE run of the real app at 400 points wide emitted 2,423
// trace lines and not one from the synthesized tier's scroll box. The
// size class is the only knob that selects it, and on this host only an
// explicit `.environment` can set one. So the phone's path is reachable
// here and nowhere else on a Mac, which also makes this the fast loop:
// seconds, against two and a half minutes for a simulator rebuild.

import AppKit
import SwiftUI

@main
@MainActor
enum KayaStackedGrowProbe {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var failures = 0

        func expectBool(_ name: String, _ got: Bool, _ want: Bool) {
            if got != want {
                print("swiftui-stacked-grow: FAIL — \(name): got \(got), wanted \(want)")
                failures += 1
            }
        }

        // The summary side: a column that HUGS, holding one long label —
        // the `net …` line, which is what forced the wrapping ruling.
        let summary = KayaNode(
            id: 10, kind: UInt32(KAYA_KIND_COLUMN), tag: Array("summary".utf8))
        summary.align = 3  // stretch, by the interpreter's own value
        for (i, text) in [
            "15000 of 15000 transactions",
            "first 2023-10-21 BND buy $841.44",
            "net AAPL 10, BND 20, CASH 1, NVDA 4, VTI 6, VXUS 15 = $10026.50",
        ].enumerated() {
            let label = KayaNode(
                id: UInt64(11 + i), kind: UInt32(KAYA_KIND_LABEL),
                tag: Array("line\(i)".utf8))
            label.text = text
            summary.children.append(label)
        }

        // The ledger side: a GROWN table, the thing that needs a viewport.
        let table = KayaNode(
            id: 20, kind: UInt32(KAYA_KIND_COLUMN), tag: Array("ledger".utf8))
        table.grow = 1
        table.align = 3
        table.tableColumns = ["Date", "Ticker", "Side", "Total"]
        for r in 0..<40 {
            let row = KayaNode(
                id: UInt64(100 + r), kind: UInt32(KAYA_KIND_ROW),
                tag: Array("r\(r)".utf8))
            for (c, text) in ["2026-08-24", "AAPL", "sell", "$2700.00"].enumerated() {
                let cell = KayaNode(
                    id: UInt64(1000 + r * 10 + c), kind: UInt32(KAYA_KIND_LABEL),
                    tag: Array("c".utf8))
                cell.text = text
                row.children.append(cell)
            }
            table.children.append(row)
        }

        let root = KayaNode(
            id: 1, kind: UInt32(KAYA_KIND_COLUMN), tag: Array("root".utf8))
        root.children = [summary, table]

        // A PHONE'S BOX, and a COMPACT size class so `kayaTableTier` picks
        // the synthesized tier — the branch this host would otherwise
        // never render.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 393, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        // THE PHONE'S OWN VIEW, ASSEMBLED BY HAND. `KayaTableSurface`
        // picks the tier from a compile-time `#if os(macOS)` arm, so on
        // this host it always answers NATIVE and the synthesized branch —
        // the only one a phone runs — is unreachable through it. An
        // `.environment` size class does not help: the mac arm never reads
        // one. So the flex, the cells and the synthesized table are put
        // together here exactly as KayaRender would.
        window.contentView = NSHostingView(
            rootView: KayaFlex(
                vertical: true, spacing: 8, nodes: [summary, table], fillCross: true
            ) {
                KayaCell(traceId: summary.id, vertical: true, align: 3) {
                    KayaRender(node: summary, flexVertical: true, flexStretch: true)
                }
                KayaCell(traceId: table.id, vertical: true, align: 3) {
                    kayaSynthesizedTableForProbe(table)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        window.orderFront(nil)

        // Let the layout settle: the viewport is reported from a geometry
        // reader, so it lands a run-loop turn or two after the first pass.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if (table.tableViewport?.frame.height ?? 0) > 0 { break }
        }

        let registered = kayaTableWindows[table.id] != nil
        let viewport = table.tableViewport?.frame
        print("swiftui-stacked-grow: registered=\(registered) "
            + "viewport=\(viewport.map { "\(Int($0.width))x\(Int($0.height))" } ?? "none")")

        // WHAT THIS CAN ASSERT, AND WHAT IT CANNOT. There is no core here,
        // so `visible` is always nil by the tier's own early return — a
        // probe hosts this render path with no window geometry to read
        // (KayaSynthesizedWindow.report). The VIEWPORT is the part that is
        // pure layout, and it is the number that was zero on the phone.
        expectBool("the grown table registered its window", registered, true)
        expectBool("the stacked grown table is given a real viewport height",
            (viewport?.height ?? 0) > 0, true)

        if failures == 0 {
            print("swiftui-stacked-grow: OK — the stacked grown table has a viewport")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
