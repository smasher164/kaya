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

        if failures == 0 {
            print("swiftui-pane-ladder: OK — arithmetic and the real "
                + "1400 -> 700 -> 1400 walk")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
