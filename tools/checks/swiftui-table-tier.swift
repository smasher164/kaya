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
        func expectBool(_ name: String, _ got: Bool, _ want: Bool) {
            if got != want {
                print("swiftui-table-tier: FAIL — \(name): got \(got), wanted \(want)")
                failures += 1
            }
        }
        func expectEdges(_ name: String, _ got: [Double], _ want: [Double]) {
            if got != want {
                print("swiftui-table-tier: FAIL — \(name): got \(got), wanted \(want)")
                failures += 1
            }
        }
        func geometryLabel(_ geometry: KayaCurrentTableGeometry) -> String {
            switch geometry {
            case .missingViewport:
                return "missing viewport"
            case let .partialRow(got, want):
                return "partial row \(got)/\(want)"
            case let .unrealized(realized, declared):
                return "unrealized \(realized)/\(declared)"
            case let .current(_, rows, columns):
                return "current \(rows.count)/\(columns.flatMap { $0 }.count)"
            }
        }
        func expectGeometry(
            _ name: String, _ got: KayaCurrentTableGeometry, _ want: String
        ) {
            let label = geometryLabel(got)
            if label != want {
                print("swiftui-table-tier: FAIL — \(name): got \(label), wanted \(want)")
                failures += 1
            }
        }

        let viewport = CGRect(x: 100, y: 200, width: 300, height: 120)
        expectBool(
            "an exact table viewport matches its track",
            kayaTableViewportMatchesTrack(viewport, track: 300), true)
        expectBool(
            "table track underfill is rejected",
            kayaTableViewportMatchesTrack(viewport, track: 303), false)
        expectBool(
            "table track overflow is rejected",
            kayaTableViewportMatchesTrack(viewport, track: 297), false)
        // THE PADDED CARD CONVICTS NOTHING — gtk.rs's
        // `gtk_table_padded_card_convicts_nothing` in this file's spelling,
        // for the iOS synthesized tier's inset-grouped card (ruled
        // 2026-08-25). The numbers are PASSED, never read: this host's own
        // constants are zero, so a probe that read them would drive the
        // unpadded case and call it a measurement.
        //
        // THE CARD IS TWO LAYERS AND THE CHAIN HAS TO CLOSE. The ground band
        // is OUTSIDE the scroll clip (it frames the table and never
        // scrolls); the interior is INSIDE it, on the content that scrolls
        // with the rows — so an 800pt assigned track gives a 768pt clip and
        // a 736pt cells' box, and 736 is exactly what the instrument's
        // content track must be.
        let assignedTrack = 800.0
        let clip = CGRect(x: 116, y: 200, width: 768, height: 400)
        let carded = kayaTableCellsBox(inScrollClip: clip, interior: 16)
        expectBool(
            "the carded scroll clip yields the cells' own box",
            carded.minX == 132 && carded.width == 736 && carded.height == clip.height,
            true)
        expectBool(
            "a padded card's viewport matches its own content track",
            kayaTableViewportMatchesTrack(
                carded,
                track: kayaTableContentTrack(assignedTrack, pad: 32, synthesized: true)),
            true)
        expectBool(
            "a track basis that forgets the card convicts every padded table",
            kayaTableViewportMatchesTrack(carded, track: assignedTrack), false)
        // The CLIP is not the cells' box: a writer that reported it would
        // agree with the assigned track and disagree with the cells.
        expectBool(
            "the scroll clip itself does not match the content track",
            kayaTableViewportMatchesTrack(
                clip,
                track: kayaTableContentTrack(assignedTrack, pad: 32, synthesized: true)),
            false)
        // …and the pad is never paid twice: an UNCARDED tier — the mac's
        // native one, and iOS's regular-width one — keeps its whole track.
        expectBool(
            "an uncarded table keeps its assigned track untouched",
            kayaTableViewportMatchesTrack(
                CGRect(x: 100, y: 200, width: 800, height: 120),
                track: kayaTableContentTrack(800, pad: 32, synthesized: false)),
            true)
        // AND THE VIEWPORT IS THE CELLS' OWN BOX, which is what keeps the
        // leading-edge clause flush under a card on the content layer. Read
        // at the CLIP instead, the same cells report the card's interior as
        // content underfill — the shape of a writer that forgot to inset.
        expectBool(
            "cells flush inside a carded viewport underfill nothing",
            kayaTableLeadingUnderfill(
                Double(carded.minX), viewport: carded, synthesized: true) == nil,
            true)
        expectBool(
            "a viewport read at the scroll clip reports the card's interior",
            kayaTableLeadingUnderfill(
                Double(carded.minX), viewport: clip, synthesized: true) == 16,
            true)
        expectBool(
            "global viewport origin rejects horizontally shifted cells",
            kayaTableFramesFitHorizontally(
                [CGRect(x: 90, y: 220, width: 180, height: 20)], inside: viewport),
            false)
        expectBool(
            "vertical row slack is accepted",
            kayaTableFramesFitVertically(
                [CGRect(x: 120, y: 220, width: 180, height: 20)], inside: viewport),
            true)
        expectBool(
            "vertical row overflow is rejected",
            kayaTableFramesFitVertically(
                [CGRect(x: 120, y: 310, width: 180, height: 20)], inside: viewport),
            false)
        expectEdges(
            "edge clustering is anchored to its representative",
            kayaTableEdgeClusters([100, 102, 104]), [100, 104])
        let borrowedCluster = [
            [
                CGRect(x: 100, y: 200, width: 20, height: 20),
                CGRect(x: 200, y: 220, width: 20, height: 20),
            ],
            [
                CGRect(x: 200, y: 200, width: 20, height: 20),
                CGRect(x: 100, y: 220, width: 20, height: 20),
            ],
        ]
        expectBool(
            "column identity rejects frames borrowed from an existing cluster",
            {
                if case .split(_, _) = kayaTableColumnAlignment(borrowedCluster) {
                    return true
                }
                return false
            }(),
            true)
        expectBool(
            "column representatives must remain distinct and increasing",
            kayaTableColumnRepresentativesIncrease([200, 100]), false)

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
        kayaScene.columns.append(table)

        expectGeometry(
            "missing table viewport geometry is rejected",
            kayaCurrentTableGeometry(table), "missing viewport")
        let generation = kayaTableGeometryGeneration(table)
        table.tableViewport = KayaTableViewportObservation(
            generation: generation, frame: viewport, synthesized: false)
        expectGeometry(
            "missing current row-cell geometry is rejected",
            kayaCurrentTableGeometry(table), "unrealized 0/2")
        let staleGeneration = generation == Int.max ? Int.min : generation + 1
        for row in table.children {
            for column in table.tableColumns.indices {
                let cell = row.children[column]
                table.tableCellFrames["\(row.id)/\(column)/\(cell.id)"] =
                    KayaTableCellObservation(
                        generation: staleGeneration,
                        frame: CGRect(
                            x: 120 + CGFloat(column * 120), y: 220,
                            width: 80, height: 20))
            }
        }
        expectGeometry(
            "stale row-cell geometry is rejected",
            kayaCurrentTableGeometry(table), "unrealized 0/2")
        for key in Array(table.tableCellFrames.keys) {
            guard let stale = table.tableCellFrames[key] else { continue }
            table.tableCellFrames[key] = KayaTableCellObservation(
                generation: generation, frame: stale.frame)
        }
        table.tableCellFrames["stale/far-away"] = KayaTableCellObservation(
            generation: staleGeneration,
            frame: CGRect(x: -10_000, y: -10_000, width: 1, height: 1))
        expectGeometry(
            "all and only current live row-cell geometry is accepted",
            kayaCurrentTableGeometry(table), "current 4/4")
        table.tableCellFrames = [:]
        table.tableViewport = nil

        let surface = KayaTableSurface(node: table)
        expectWidth("this host's KayaTableSurface reports its own width class",
            surface.widthClass, .noSizeClass)
        expect("…and the rule sends it to the native tier",
            kayaTableTier(width: surface.widthClass, dynamicColumns: true), .native)

        // --- Half 3: the tier that actually drew. ----------------------
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        table.grow = 1
        let geometryRoot = KayaNode(
            id: 4, kind: UInt32(KAYA_KIND_COLUMN), tag: Array("geometry-root".utf8))
        geometryRoot.children.append(table)
        let geometryWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        geometryWindow.contentView = NSHostingView(
            rootView: KayaRender(node: geometryRoot, flexVertical: true, flexStretch: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity))
        geometryWindow.orderFront(nil)

        func awaitCurrentGeometry() -> KayaCurrentTableGeometry {
            let deadline = Date().addingTimeInterval(5)
            var geometry = kayaCurrentTableGeometry(table)
            while Date() < deadline {
                if case .current = geometry { return geometry }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                geometry = kayaCurrentTableGeometry(table)
            }
            return geometry
        }

        func awaitCurrentGeometryAndTrack() -> (KayaCurrentTableGeometry, Double?) {
            let deadline = Date().addingTimeInterval(5)
            var geometry = kayaCurrentTableGeometry(table)
            var track = kayaCurrentTableTrackWidth(table)
            while Date() < deadline {
                if case .current = geometry, track != nil { return (geometry, track) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                geometry = kayaCurrentTableGeometry(table)
                track = kayaCurrentTableTrackWidth(table)
            }
            return (geometry, track)
        }

        let liveState = awaitCurrentGeometryAndTrack()
        let liveGeometry = liveState.0
        switch liveGeometry {
        case let .current(liveViewport, rows, columns):
            let frames = columns.flatMap { $0 }
            expectBool("live native row-cell geometry is present", rows.isEmpty, false)
            expectBool(
                "live native cells stay inside the recorded viewport horizontally",
                kayaTableFramesFitHorizontally(frames, inside: liveViewport), true)
            expectBool(
                "live native rows stay inside the recorded viewport vertically",
                kayaTableFramesFitVertically(rows, inside: liveViewport), true)
            expectBool(
                "live native columns align by identity with increasing representatives",
                {
                    guard case let .aligned(representatives) =
                        kayaTableColumnAlignment(columns)
                    else { return false }
                    return representatives.count == 2
                        && kayaTableColumnRepresentativesIncrease(representatives)
                }(),
                true)
            expectBool(
                "the table viewport spans its recorded track width",
                liveState.1.map {
                    kayaTableViewportMatchesTrack(liveViewport, track: $0)
                } ?? false,
                true)
        default:
            let detail = geometryLabel(liveGeometry)
            print(
                "swiftui-table-tier: FAIL — live native row-cell geometry is present: "
                    + detail)
            failures += 1
        }

        func rejectsPreviousGeometry(_ previous: Int?) -> Bool {
            guard case .current = kayaCurrentTableGeometry(table) else { return true }
            return table.tableViewport?.generation != previous
        }
        func rejectsPreviousTrack(_ previous: Int?) -> Bool {
            guard kayaCurrentTableTrackWidth(table) != nil else { return true }
            return kayaTableTrackSizes[table.id]?.generation != previous
        }

        let initialGeneration = table.tableViewport?.generation
        let initialTrackGeneration = kayaTableTrackSizes[table.id]?.generation
        kayaInvalidateTableGeometry()
        expectBool(
            "a layout invalidation rejects the previous generation",
            rejectsPreviousGeometry(initialGeneration), true)
        expectBool(
            "a layout invalidation rejects the previous track",
            rejectsPreviousTrack(initialTrackGeneration), true)
        let invalidationState = awaitCurrentGeometryAndTrack()
        expectBool(
            "a same-size layout invalidation republishes geometry and track",
            {
                guard case let .current(viewport, _, _) = invalidationState.0,
                    let track = invalidationState.1,
                    let generation = table.tableViewport?.generation,
                    let trackGeneration = kayaTableTrackSizes[table.id]?.generation,
                    let initialGeneration,
                    let initialTrackGeneration
                else { return false }
                return generation != initialGeneration
                    && trackGeneration != initialTrackGeneration
                    && kayaTableViewportMatchesTrack(viewport, track: track)
            }(),
            true)

        let preLayoutGeneration = table.tableViewport?.generation
        let preLayoutTrackGeneration = kayaTableTrackSizes[table.id]?.generation
        let preLayoutWidth: CGFloat? = {
            guard case let .current(viewport, _, _) = invalidationState.0 else { return nil }
            return viewport.width
        }()
        kayaSetWindowContentSize(geometryWindow, NSSize(width: 520, height: 700))
        expectBool(
            "a resize never accepts the previous generation",
            rejectsPreviousGeometry(preLayoutGeneration), true)
        expectBool(
            "a resize never accepts the previous track",
            rejectsPreviousTrack(preLayoutTrackGeneration), true)
        let layoutRefreshedState = awaitCurrentGeometryAndTrack()
        let layoutRefreshedGeometry = layoutRefreshedState.0
        expectBool(
            "a resized table records a fresh live generation",
            {
                guard case .current = layoutRefreshedGeometry,
                    let refreshed = table.tableViewport?.generation,
                    let preLayoutGeneration
                else { return false }
                return refreshed != preLayoutGeneration
            }(),
            true)
        expectBool(
            "a resized table refreshes its viewport and assigned track",
            {
                guard case let .current(viewport, _, _) = layoutRefreshedGeometry,
                    let preLayoutWidth,
                    let track = layoutRefreshedState.1
                else { return false }
                return viewport.width > preLayoutWidth + 100
                    && kayaTableViewportMatchesTrack(viewport, track: track)
            }(),
            true)

        let resizedGeneration = table.tableViewport?.generation
        let resizedTrackGeneration = kayaTableTrackSizes[table.id]?.generation
        let sameSize = geometryWindow.contentRect(forFrameRect: geometryWindow.frame).size
        kayaSetWindowContentSize(geometryWindow, sameSize)
        expectBool(
            "a same-size resize never accepts the previous generation",
            rejectsPreviousGeometry(resizedGeneration), true)
        expectBool(
            "a same-size resize never accepts the previous track",
            rejectsPreviousTrack(resizedTrackGeneration), true)
        let sameSizeState = awaitCurrentGeometryAndTrack()
        expectBool(
            "a same-size layout invalidation republishes geometry and track",
            {
                guard case let .current(viewport, _, _) = sameSizeState.0,
                    let track = sameSizeState.1,
                    let generation = table.tableViewport?.generation,
                    let trackGeneration = kayaTableTrackSizes[table.id]?.generation,
                    let resizedTrackGeneration,
                    let resizedGeneration
                else { return false }
                return generation != resizedGeneration
                    && trackGeneration != resizedTrackGeneration
                    && kayaTableViewportMatchesTrack(viewport, track: track)
            }(),
            true)

        // THE USER ROUTE, not a bare assignment: the model write a
        // checkbox, a slider or a keystroke makes goes through
        // kayaUserWrite, which stales the observations the way a batch
        // and a resize do. A generation derived from the model was tried
        // and did not cover the sibling-only case at all (docs/traps.md).
        let firstGeneration = table.tableViewport?.generation
        kayaUserWrite { table.children[0].children[0].text = "row zero changed" }
        expectBool(
            "a user-route model write immediately refuses the previous generation",
            {
                if case .current = kayaCurrentTableGeometry(table) { return false }
                return true
            }(),
            true)
        let refreshedGeometry = awaitCurrentGeometry()
        expectBool(
            "a user-route model write records a fresh live generation",
            {
                guard case .current = refreshedGeometry,
                    let refreshed = table.tableViewport?.generation,
                    let firstGeneration
                else { return false }
                return refreshed != firstGeneration
            }(),
            true)
        geometryWindow.orderOut(nil)

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

        // --- Half 4: the tier's window contract at the view layer. -----
        // Ruled 2026-08-25: expect_window carries first-visible and
        // total only; the band-width arithmetic (visible plus one
        // viewport of overscan each side) is held by the CORE's own
        // watched tests (crates/kaya/src/rowwindow.rs), because a
        // hand-built probe node has no core window to have arithmetic
        // about. What the VIEW layer owes, and this clause holds: with
        // no core window reported, the driver answers the UNREPORTED
        // fallback — every row realized, band (0, N, N) — which is the
        // compatibility bridge's tier half; and firstVisible reads the
        // real visible range, not the band.
        let bandTable = KayaNode(
            id: 40, kind: UInt32(KAYA_KIND_COLUMN), tag: Array("band".utf8))
        bandTable.tableColumns = ["Only"]
        for i in 0..<400 {
            let row = KayaNode(
                id: UInt64(41_000 + i), kind: UInt32(KAYA_KIND_ROW),
                tag: Array("band-r\(i)".utf8))
            let cell = KayaNode(
                id: UInt64(42_000 + i), kind: UInt32(KAYA_KIND_LABEL),
                tag: Array("band-c\(i)".utf8))
            cell.text = "row \(i)"
            row.children.append(cell)
            bandTable.children.append(row)
        }
        bandTable.grow = 1
        let bandWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        bandWindow.contentView = NSHostingView(
            rootView: KayaRender(node: bandTable, flexVertical: true, flexStretch: false))
        bandWindow.orderFront(nil)
        let bandDeadline = Date().addingTimeInterval(5)
        while Date() < bandDeadline, kayaTableDrivers[bandTable.id] == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if let driver = kayaTableDrivers[bandTable.id] {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let band = driver.band()
            let visible = driver.firstVisible()
            print("  window contract: band (\(band.first), \(band.count), "
                + "\(band.total)), first visible \(visible.first) of \(visible.total)")
            if band.first != 0 || band.count != 400 || band.total != 400 {
                print("swiftui-table-tier: FAIL — an UNREPORTED table must answer "
                    + "the fallback band (0, 400, 400), got (\(band.first), "
                    + "\(band.count), \(band.total)) — the bridge's tier half")
                failures += 1
            }
            if visible.total != 400 {
                print("swiftui-table-tier: FAIL — firstVisible's total "
                    + "\(visible.total), wanted the collection's 400")
                failures += 1
            }
            // 400 rows at 24pt in a ~300pt window: the visible range is
            // a strict subset, so a firstVisible that echoed the band
            // would be indistinguishable from realized-everything —
            // scroll and demand the read moves with the viewport.
            driver.scroll(toRow: 200)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let scrolled = driver.firstVisible()
            if scrolled.first != 200 {
                print("swiftui-table-tier: FAIL — after scroll(toRow: 200) "
                    + "firstVisible reads \(scrolled.first), wanted 200 — the "
                    + "verb's number must be the viewport's, not the band's")
                failures += 1
            }
        } else {
            print("swiftui-table-tier: FAIL — no driver materialized for the "
                + "window-contract clause, so it was checked against nothing")
            failures += 1
        }
        bandWindow.orderOut(nil)

        // --- Half 5: content is the floor (ruled 2026-08-26). ----------
        // A HUGGING container narrower than the table's content is the
        // shape the transactions view shipped: the panel measured 210pt,
        // the columns' content wanted 267, and every Date and Total cell
        // ellipsized. Two things are read here, one per half of the
        // ruling — the MINIMUM each column declares to AppKit, and the
        // content width the tier hands UP — and the second is read off
        // the real NSScrollView, so "it published a number" and "the
        // container actually widened" are separate readings.
        //
        // The floors are recomputed here from the SAME cell measurement
        // the tier uses, deliberately: what this holds is the ASSIGNMENT,
        // which is where the defect was. The measurement itself is the
        // capture's to prove.
        func findTableView(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for sub in view.subviews {
                if let table = findTableView(sub) { return table }
            }
            return nil
        }

        let floorTable = KayaNode(
            id: 50, kind: UInt32(KAYA_KIND_COLUMN), tag: Array("floor".utf8))
        floorTable.tableColumns = ["Date", "Ticker"]
        floorTable.sortTag = Array("floor-sort".utf8)
        for r in 0..<6 {
            let row = KayaNode(
                id: UInt64(51_000 + r), kind: UInt32(KAYA_KIND_ROW),
                tag: Array("floor-r\(r)".utf8))
            for (c, value) in ["2026-08-24 09:15:00", "VANGUARD-TOTAL-WORLD"].enumerated() {
                let cell = KayaNode(
                    id: UInt64(52_000 + r * 2 + c), kind: UInt32(KAYA_KIND_LABEL),
                    tag: Array("floor-c\(r)-\(c)".utf8))
                cell.text = value
                row.children.append(cell)
            }
            floorTable.children.append(row)
        }
        kayaScene.columns.append(floorTable)
        let floorRoot = KayaNode(
            id: 53, kind: UInt32(KAYA_KIND_COLUMN), tag: Array("floor-root".utf8))
        floorRoot.children.append(floorTable)
        // THE HUG IS ASKED WHERE IT IS A HUG (rewritten 2026-08-29). This
        // clause holds ruling A's substance — a container grows to the
        // table's content rather than ellipsizing inside it — and it used
        // to ask that inside a 200pt window against 335pt of columns,
        // where the only way to pass was for the table's own VIEWPORT to
        // be wider than the window containing it. That is not a hug; it is
        // 135pt of table hanging off the side of the window with no way to
        // reach it, and it is exactly what the overflow ruling replaced
        // with scrolling (docs/tables-plan.md, 2026-08-29). A test may not
        // demand the behaviour its own project has ruled against.
        //
        // So: room for the hug, and a SPACER beside it so the container
        // hugs rather than fills — which is the shape a real hugging panel
        // has, and asks the question without `fixedSize`, whose ideal-width
        // resolution feeds this tier SwiftUI's 10x10 substitution default
        // and pins it there (measured 2026-08-29). The narrow case is the
        // ruling's now, and the scene drives it. TEETH INTACT: a tier that
        // publishes no content width answers ~10pt here, which is what this
        // gate's own self-test perturbs it into doing.
        let floorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        // THE HUG IN KAYA'S OWN VOCABULARY: an ungrown column beside a
        // GROWN sibling, which is the shape a real hugging panel has (the
        // portfolio's dashboard is exactly this). The ungrown one takes its
        // natural width — the table's content — and the grown one takes the
        // rest. SwiftUI-side tricks do not serve here: the root fills its
        // host, and `fixedSize` feeds this tier the 10x10 substitution
        // default and pins it there (both measured 2026-08-29).
        let floorFiller = KayaNode(
            id: 55, kind: UInt32(KAYA_KIND_COLUMN), tag: Array("floor-filler".utf8))
        floorFiller.grow = 1
        let floorPair = KayaNode(
            id: 54, kind: UInt32(KAYA_KIND_ROW), tag: Array("floor-pair".utf8))
        floorPair.children = [floorRoot, floorFiller]
        floorWindow.contentView = NSHostingView(
            rootView: KayaRender(node: floorPair, flexVertical: false, flexStretch: false))
        floorWindow.orderFront(nil)

        /// (worst deficit against the floor, worst minimum deficit, the
        /// floors' total, the clip the cells were given, cells read).
        func floorReading() -> (CGFloat, CGFloat, CGFloat, CGFloat, Int) {
            guard let content = floorWindow.contentView,
                let table = findTableView(content)
            else { return (0, 0, 0, 0, 0) }
            var floors = table.tableColumns.map {
                max(24, $0.headerCell.cellSize.width + 16)
            }
            var seen = 0
            let visible = table.rows(in: table.visibleRect)
            for offset in 0..<max(0, visible.length) {
                for c in table.tableColumns.indices {
                    guard
                        let cell = table.view(
                            atColumn: c, row: visible.location + offset,
                            makeIfNecessary: false) as? KayaTableCellView
                    else { continue }
                    floors[c] = max(floors[c], cell.contentWidth + 16)
                    seen += 1
                }
            }
            var widthDeficit: CGFloat = 0
            var minDeficit: CGFloat = 0
            for (c, column) in table.tableColumns.enumerated() {
                widthDeficit = max(widthDeficit, floors[c] - column.width)
                minDeficit = max(minDeficit, floors[c] - column.minWidth)
            }
            let clip = table.enclosingScrollView?.contentView.bounds.width ?? 0
            return (widthDeficit, minDeficit, floors.reduce(0, +), clip, seen)
        }

        var floorState = floorReading()
        let floorDeadline = Date().addingTimeInterval(6)
        while Date() < floorDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            floorState = floorReading()
            if floorState.4 > 0, floorState.1 <= 0.5, floorState.3 >= floorState.2 { break }
        }
        let (widthDeficit, minDeficit, floorTotal, clipWidth, cellsRead) = floorState
        print("  content floor: \(cellsRead) cells read, floors total "
            + "\(floorTotal), clip \(clipWidth), worst width deficit "
            + "\(widthDeficit), worst minimum deficit \(minDeficit), published "
            + "\(floorTable.tableContentWidth)")
        // A census that read nothing agrees with everything.
        expectBool(
            "the content-floor clause read some realized cells", cellsRead >= 2, true)
        expectBool(
            "no native column declares a minimum below its measured content",
            minDeficit <= 0.5, true)
        expectBool(
            "no native column is narrower than its measured content",
            widthDeficit <= 0.5, true)
        expectBool(
            "the native tier publishes its measured content width upward",
            floorTable.tableContentWidth >= Double(floorTotal), true)
        expectBool(
            "a hugging container widens to the native table's content",
            clipWidth >= floorTotal, true)
        floorWindow.orderOut(nil)

        if failures == 0 {
            print("swiftui-table-tier: OK — rule, geometry, this host's branch, "
                + "and the rendered tier")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
