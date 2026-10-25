// The macOS pane ladder, measured for real — compiled INTO the
// interpreter's own module by tools/check-pane-ladder.py and run.
//   1  ARITHMETIC: kayaPaneRung / kayaPaneLadderCommand, including the
//      ordering constraint that keeps the regular band free of a one-pane
//      state (content+detail < 600), which the bare expect_panes
//      invariant depends on.
//   2  RUNTIME: the real KayaSplitRoot3 in a real NSWindow, resized
//      1400 -> 700 -> 1400. No shared scene may sample 700 (check-steps'
//      panes band), so the shed-and-restore is proven here or nowhere.

import AppKit
import SwiftUI

@main
@MainActor
enum KayaPaneLadderProbe {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var failures = 0

        // --- Half 1: the arithmetic. -----------------------------------
        let sum3 = kayaPaneMinSidebar + kayaPaneMinContent + kayaPaneMinDetail
        let sum2 = kayaPaneMinContent + kayaPaneMinDetail
        func expect(_ name: String, _ got: Bool) {
            if !got {
                print("swiftui-pane-ladder: FAIL — \(name)")
                failures += 1
            }
        }
        expect("content+detail (\(sum2)) stays under 600, the compact threshold —"
            + " otherwise a REGULAR width exists where two panes cannot fit and"
            + " the bare expect_panes invariant breaks", sum2 < 600)
        expect("rung(1400) == 3", kayaPaneRung(1400) == 3)
        expect("rung(sum3) == 3", kayaPaneRung(sum3) == 3)
        expect("rung(sum3 - 1) == 2", kayaPaneRung(sum3 - 1) == 2)
        expect("rung(700) == 2 (the middle rung the runtime half drives)",
            kayaPaneRung(700) == 2)
        expect("the constants discriminate at all",
            kayaPaneRung(700) != kayaPaneRung(1400))
        expect("first measurement commands .all wide",
            kayaPaneLadderCommand(from: nil, to: 1400) == .all)
        expect("first measurement commands .doubleColumn narrow",
            kayaPaneLadderCommand(from: nil, to: 700) == .doubleColumn)
        expect("crossing down commands .doubleColumn",
            kayaPaneLadderCommand(from: 900, to: 700) == .doubleColumn)
        expect("crossing up commands .all",
            kayaPaneLadderCommand(from: 700, to: 1400) == .all)
        // EDGE-TRIGGERED, the sidebar-toggle half: no crossing, no
        // command — a level rule would undo the user's toggle.
        expect("no command on the level (rung 2)",
            kayaPaneLadderCommand(from: 700, to: 650) == nil)
        expect("no command on the level (rung 3)",
            kayaPaneLadderCommand(from: 1400, to: 900) == nil)

        // --- Half 2: the real ladder. -----------------------------------
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let window = KayaWindowModel(id: 0, title: "ladder")
        window.panes = 3
        let rootLabel = KayaNode(
            id: 1, kind: UInt32(KAYA_KIND_LABEL), tag: Array("root".utf8))
        rootLabel.text = "root pane"
        window.root = rootLabel
        kayaScene.windows[0] = window
        for (i, name) in ["content", "detail"].enumerated() {
            let id = UInt64(10 + i)
            let entry = KayaEntryModel(id: id)
            entry.title = name
            let label = KayaNode(
                id: 20 + UInt64(i), kind: UInt32(KAYA_KIND_LABEL),
                tag: Array(name.utf8))
            label.text = "\(name) pane"
            entry.root = label
            kayaScene.navEntries[id] = entry
            kayaScene.entryWindow[id] = 0
            window.entries.append(entry)
        }

        let host = NSHostingView(rootView: KayaSplitRoot3(windowId: 0))
        let ns = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        ns.contentView = host
        ns.orderFront(nil)

        /// Pump the runloop until the split view shows `want` visible
        /// columns (width > 1 and not hidden — the expect_panes rule) or
        /// the deadline passes; either way say what was seen.
        func columns(_ want: Int, _ label: String) {
            let deadline = Date().addingTimeInterval(5)
            var seen = -1
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if let split = ns.contentView.flatMap({ kayaFindSplitView($0) }) {
                    seen = split.arrangedSubviews.filter {
                        $0.frame.width > 1 && !$0.isHidden
                    }.count
                    if seen == want { break }
                }
            }
            print("  \(label): visible columns = \(seen), wanted \(want)")
            if seen != want {
                print("swiftui-pane-ladder: FAIL — \(label)")
                failures += 1
            }
        }

        columns(3, "wide (1400): all three")
        ns.setContentSize(NSSize(width: 700, height: 800))
        columns(2, "middle rung (700): the sidebar sheds")
        ns.setContentSize(NSSize(width: 1400, height: 800))
        columns(3, "wide again (1400): the shed pane returns")

        // --- Half 3: a pane's grid sets no window width (M16 F1). --------
        // NavigationSplitView takes its detail's ideal as the window's
        // floor, so twelve 144-point cards made the window 2072 pt wide.
        let grid = NSHostingView(rootView: KayaAutoGrid(minWidth: 144, spacing: 12) {
            ForEach(0..<12, id: \.self) { _ in Color.gray.frame(width: 120, height: 120) }
        })
        let ideal = grid.fittingSize.width
        print("  an auto grid of twelve 144-point cells: ideal width \(Int(ideal))")
        if ideal > 144 {
            print("swiftui-pane-ladder: FAIL — an auto grid's ideal width is \(Int(ideal)), "
                + "wanted at most its one-column floor 144: a pane holding it widens its window")
            failures += 1
        }

        // --- Half 4: the two-pane sidebar opens at the leading pane's width
        // (docs/traps.md, the two-pane sidebar fell to SwiftUI's floor). ----
        for (total, want) in [(1000.0, 250.0), (600.0, 180.0), (4000.0, 280.0), (100.0, 100.0)] {
            expect("kayaLeadingPaneWidth(\(Int(total))) == \(Int(want)), protocol.rs's leading_pane_width",
                kayaLeadingPaneWidth(total) == want)
        }
        let two = KayaWindowModel(id: 7, title: "two panes")
        two.panes = 2
        two.width = 1100
        two.height = 720
        let side = KayaNode(id: 70, kind: UInt32(KAYA_KIND_COLUMN), tag: Array("side".utf8))
        let words = KayaNode(id: 71, kind: UInt32(KAYA_KIND_LABEL), tag: Array("words".utf8))
        words.text = "Through The Olive Branches, a title of several words"
        side.children = [words]
        kayaScene.windows[7] = two
        let twoWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        twoWindow.contentView = NSHostingView(rootView: KayaSplitRoot(windowId: 7).modifier(KayaDockHost(windowId: 7)))
        twoWindow.orderFront(nil)
        // The window's root arrives after its split view exists, as it does
        // from a guest.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        two.root = side
        func sidebarWidth() -> CGFloat {
            var seen: CGFloat = -1
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if let split = twoWindow.contentView.flatMap({ kayaFindSplitView($0) }),
                    let first = split.arrangedSubviews.first, !first.isHidden, first.frame.width > 1
                {
                    seen = first.frame.width
                }
            }
            return seen
        }
        let lead = kayaLeadingPaneWidth(1100)
        let opened = sidebarWidth()
        print("  two panes at 1100: the sidebar opens \(Int(opened)) wide, the leading pane is \(Int(lead))")
        // The modern sidebar floats 8 pt inside its split view column (148
        // read against SwiftUI's 140 floor), so the column may carry them.
        if opened < lead - 1 || opened > lead + 9 {
            print("swiftui-pane-ladder: FAIL — the two-pane sidebar opened \(Int(opened)) wide, wanted "
                + "the leading pane's \(Int(lead)) (protocol.rs's leading_pane_width)")
            failures += 1
        }
        // Hidden and shown again, it comes back at the width it had.
        for round in 1...3 {
            for half in 0..<2 {
                let split = twoWindow.contentView.flatMap { kayaFindSplitView($0) }
                (split?.delegate as? NSSplitViewController)?.toggleSidebar(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                let first = split?.arrangedSubviews.first
                let hidden = first.map { $0.isHidden || $0.frame.width <= 1 } ?? false
                if half == 0, !hidden {
                    print("swiftui-pane-ladder: FAIL — toggleSidebar did not hide the two-pane sidebar "
                        + "(round \(round)), so its return was never exercised")
                    failures += 1
                }
            }
            let back = sidebarWidth()
            print("  hidden and shown \(round) time(s): the sidebar is \(Int(back)) wide")
            if abs(back - opened) > 1 {
                print("swiftui-pane-ladder: FAIL — hidden and shown \(round) time(s), the two-pane sidebar "
                    + "came back \(Int(back)) wide, wanted the \(Int(opened)) it opened at")
                failures += 1
            }
        }

        // --- Half 5: a sidebar title offered less than a word keeps the word
        // whole (docs/flex-shrink-plan.md §2.3). ------------------------------
        let title = KayaNode(id: 80, kind: UInt32(KAYA_KIND_LABEL), tag: Array("title".utf8))
        title.text = "Through The Olive Branches"
        let word = kayaLongestWord(title.text, kayaClippingFont(title))
        let offered = NSHostingController(rootView: KayaRender(node: title))
            .sizeThatFits(in: CGSize(width: 30, height: 1000)).width
        print("  a label offered 30 pt: \(Int(offered.rounded())) wide, its longest word \(Int(word.rounded()))")
        if offered + 1 < word {
            print("swiftui-pane-ladder: FAIL — a wrapping label offered 30 pt is \(Int(offered.rounded())) wide, "
                + "narrower than its longest word at \(Int(word.rounded())), so SwiftUI breaks the word")
            failures += 1
        }

        if failures == 0 {
            print("swiftui-pane-ladder: OK — arithmetic, the real "
                + "1400 -> 700 -> 1400 walk, the grid's ideal width, the two-pane sidebar's width and a label's word floor")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
