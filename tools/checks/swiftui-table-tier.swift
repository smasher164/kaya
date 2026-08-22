// The table tier rule, driven for real — compiled INTO the interpreter's
// own module by tools/check-table-tier.sh and run as an executable.
// Three halves:
//
//   1  THE TRUTH TABLE: kayaTableTier over every width the rule knows
//      crossed with both availabilities, and kayaTableWidth's mapping
//      from the environment's own type. This is the part no device can
//      assert: both tiers present identical bytes, so a leg cannot name
//      the one that drew it (docs/traps.md).
//   2  THIS HOST'S BRANCH: KayaTableSurface.widthClass on a mac, which is
//      the `#if os(macOS)` arm the truth table cannot reach by itself.
//   3  THE RENDERED TIER: a real KayaTableSurface in a real NSWindow, and
//      the NSTableView the native tier is made of, found in the view
//      tree — the discriminator the shared scene gave up. A plain label
//      tree is walked beside it, so a finder that says yes to everything
//      fails here.

import AppKit
import SwiftUI

@main
@MainActor
enum KayaTableTierProbe {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var failures = 0

        func expect(_ name: String, _ got: KayaTableTier, _ want: KayaTableTier) {
            if got != want {
                print("swiftui-table-tier: FAIL — \(name): got \(got), wanted \(want)")
                failures += 1
            }
        }
        func expectWidth(_ name: String, _ got: KayaTableWidth, _ want: KayaTableWidth) {
            if got != want {
                print("swiftui-table-tier: FAIL — \(name): got \(got), wanted \(want)")
                failures += 1
            }
        }

        // --- Half 1: the whole truth table. ----------------------------
        // macOS: the native Table always, at or above its floor. There is
        // no compact mode to collapse into.
        expect("mac (no size class) at/above the floor -> native",
            kayaTableTier(width: .noSizeClass, dynamicColumns: true), .native)
        expect("mac (no size class) below the floor -> synthesized",
            kayaTableTier(width: .noSizeClass, dynamicColumns: false), .synthesized)
        // iOS regular: the native Table only where TableColumnForEach
        // exists; kaya's floor is below it.
        expect("iOS regular at/above the floor -> native",
            kayaTableTier(width: .regular, dynamicColumns: true), .native)
        expect("iOS regular below the floor -> synthesized",
            kayaTableTier(width: .regular, dynamicColumns: false), .synthesized)
        // iOS compact: kaya's own header at ANY availability — the native
        // Table collapses to a first-column list and hides the declared
        // columns (docs/tables-plan.md decision 5, revised 2026-08-21).
        expect("iOS compact at/above the floor -> synthesized",
            kayaTableTier(width: .compact, dynamicColumns: true), .synthesized)
        expect("iOS compact below the floor -> synthesized",
            kayaTableTier(width: .compact, dynamicColumns: false), .synthesized)
        // A host that reported no size class at all is not a regular one.
        expect("unknown width at/above the floor -> synthesized",
            kayaTableTier(width: .unknown, dynamicColumns: true), .synthesized)
        expect("unknown width below the floor -> synthesized",
            kayaTableTier(width: .unknown, dynamicColumns: false), .synthesized)

        expectWidth("the environment's .regular maps to regular",
            kayaTableWidth(sizeClass: .regular), .regular)
        expectWidth("the environment's .compact maps to compact",
            kayaTableWidth(sizeClass: .compact), .compact)
        expectWidth("no size class in the environment maps to unknown",
            kayaTableWidth(sizeClass: nil), .unknown)

        // --- Half 2: the branch this host compiles. --------------------
        let table = KayaNode(
            id: 1, kind: UInt32(KAYA_KIND_COLUMN), tag: Array("table".utf8))
        table.tableColumns = ["Name", "Size"]
        table.sortTag = Array("sort".utf8)
        for r in 0..<2 {
            let row = KayaNode(
                id: 10 + UInt64(r), kind: UInt32(KAYA_KIND_ROW),
                tag: Array("row\(r)".utf8))
            for c in 0..<2 {
                let cell = KayaNode(
                    id: 100 + UInt64(r * 2 + c), kind: UInt32(KAYA_KIND_LABEL),
                    tag: Array("cell\(r)\(c)".utf8))
                cell.text = c == 0 ? "row \(r)" : "\(r * 100) B"
                row.children.append(cell)
            }
            table.children.append(row)
        }

        let surface = KayaTableSurface(node: table)
        expectWidth("this host's KayaTableSurface reports its own width class",
            surface.widthClass, .noSizeClass)
        expect("…and the rule sends it to the native tier",
            kayaTableTier(width: surface.widthClass, dynamicColumns: true), .native)

        // --- Half 3: the tier that actually drew. ----------------------
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        /// True once an NSTableView exists under `view` — SwiftUI's Table
        /// on macOS is one, and nothing kaya draws by hand is.
        func hasTableView(_ view: NSView) -> Bool {
            if view is NSTableView { return true }
            for sub in view.subviews where hasTableView(sub) { return true }
            return false
        }

        func viewCount(_ view: NSView) -> Int {
            view.subviews.reduce(1) { $0 + viewCount($1) }
        }

        /// Host `root` and pump. A `want: true` case stops as soon as the
        /// NSTableView appears; a `want: false` case pumps the whole
        /// settle window instead, because "not there yet" and "not there"
        /// are the same reading a beat too early. The tree's view count
        /// is printed either way: a walk over an EMPTY tree would answer
        /// false about nothing.
        func drew<V: View>(_ root: V, _ want: Bool, _ label: String) {
            let ns = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            ns.contentView = NSHostingView(rootView: root)
            ns.orderFront(nil)
            let deadline = Date().addingTimeInterval(want ? 5 : 1)
            var seen = false
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                seen = ns.contentView.map { hasTableView($0) } ?? false
                if want, seen { break }
            }
            let views = ns.contentView.map { viewCount($0) } ?? 0
            print("  \(label): NSTableView present = \(seen), wanted \(want) "
                + "(\(views) views hosted)")
            if seen != want {
                print("swiftui-table-tier: FAIL — \(label)")
                failures += 1
            }
            if views < 2 {
                print("swiftui-table-tier: FAIL — \(label): the host put \(views) "
                    + "view(s) on screen, so this reading is about an empty tree")
                failures += 1
            }
            ns.orderOut(nil)
        }

        drew(surface, true,
            "the mac surface draws the NATIVE tier (an NSTableView)")

        // The control is a tree of REAL AppKit views — an entry is an
        // NSTextField — so "no NSTableView" is a reading about something.
        let plain = KayaNode(
            id: 2, kind: UInt32(KAYA_KIND_COLUMN), tag: Array("plain".utf8))
        let entry = KayaNode(
            id: 3, kind: UInt32(KAYA_KIND_ENTRY), tag: Array("entry".utf8))
        entry.text = "no table here"
        plain.children.append(entry)
        drew(KayaRender(node: plain, flexVertical: true, flexStretch: false), false,
            "a widget tree with no table draws no NSTableView (the finder discriminates)")

        if failures == 0 {
            print("swiftui-table-tier: OK — 11 rule cells, this host's branch, "
                + "and the rendered tier")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
