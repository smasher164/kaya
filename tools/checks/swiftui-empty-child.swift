// The SwiftUI layout negative, compiled INTO the interpreter's own
// module by tools/check-empty-child.py and run as an executable: the
// reproduction of docs/deferred.md's half-decoded-image crash.
//
// WHAT IT DRIVES IS THE REAL THING: the real `kayaDecodeImage`, the real
// `KayaRender` switch, and the real `KayaFlex`/`KayaCell` layouts, hosted
// in an `NSHostingView` and measured. Only the node graph is written
// here, and that is what a wire batch would have built.
//
// THE POSITION IS THE WHOLE POINT. `KayaCell` wraps each child of a FLEX
// container, and the gallery scene puts its undecodable image in a
// growerless nested row that takes the stock HStack branch instead — so
// this mounts the image as a DIRECT CHILD OF THE ROOT, the arrangement
// no scene has.
//
// The kind numbers come from crates/kaya/include/kaya.h through the same
// bridging header the interpreter compiles against.

import AppKit
import SwiftUI

/// The bytes, worst first. Each must reach the placeholder OR decode; the
/// contract this asserts is that neither outcome is a crash.
private let cases: [(String, [UInt8])] = [
    // No recognisable container: NSImage(data:) answers nil, which is
    // the branch that used to render nothing at all.
    ("junk", Array("not an image".utf8)),
    // Header valid, data cut mid-deflate, no IEND — the shape the ledger
    // entry named. ImageIO decodes it leniently on this platform; it is
    // here so the day that changes, the crash does not come with it.
    (
        "truncated",
        [
            137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 2,
            8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248,
        ]
    ),
    // Structurally whole, IDAT payload clobbered so the deflate stream
    // and the chunk CRC both fail.
    (
        "corrupt-tail",
        [
            137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 2,
            8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248,
            207, 192, 192, 0, 194, 12, 255, 255, 255, 255, 255, 255, 255, 255, 11, 217, 104, 139,
            0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
        ]
    ),
    // Empty bytes: the degenerate placeholder, and the one a guest hits
    // by handing over a file it failed to read.
    ("empty", []),
]

@main
@MainActor
enum KayaEmptyChildProbe {
    static func main() {
        // LINE BUFFERING, and not cosmetic: the failure this exists for
        // is a TRAP and a trapped process flushes nothing, so under a
        // pipe the output dies with it and the crash reads as having
        // happened on the FIRST case when it happened on the last.
        setvbuf(stdout, nil, _IOLBF, 0)
        // Reaching the end of `probe()` at all is most of the test: the
        // crash it guards happened during layout, so a process that gets
        // there has already survived it.
        let status = probe()
        if status == 0 {
            print(
                "swiftui-empty-child: OK — \(cases.count) undecodable inputs "
                    + "laid out in a KayaCell")
        }
        exit(status)
    }
}

/// How many subviews the kind under test handed its enclosing layout,
/// keyed by case name. `nonisolated(unsafe)` because a Layout's protocol
/// requirements are nonisolated and this probe is one main thread from
/// start to finish.
nonisolated(unsafe) private var contributed: [String: Int] = [:]

/// A one-child Layout that RECORDS what it was given and then behaves.
/// Deliberately NOT KayaCell: KayaCell tolerates an empty child, so it
/// can no longer tell "the image rendered nothing" from "the image
/// rendered a 0x0 box" — and everything that counts children
/// positionally reads the wrong child in the first case.
private struct CountingCell: Layout {
    let name: String

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        contributed[name] = subviews.count
        return subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}

@MainActor
private func probe() -> Int32 {
    var failures = 0
    for (name, bytes) in cases {
        let image = KayaNode(
            id: 2, kind: UInt32(KAYA_KIND_IMAGE), tag: Array("probe".utf8))
        kayaDecodeImage(Data(bytes), into: image)
        // A direct child of the mounted root, so KayaFlex wraps it in a
        // KayaCell. A grower as well, which is the OTHER way a container
        // takes the flex branch.
        image.grow = 1.0
        let root = KayaNode(
            id: 1, kind: UInt32(KAYA_KIND_COLUMN), tag: [])
        root.children = [image]

        let host = NSHostingView(rootView: KayaRender(node: root, isRoot: true))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        // Both halves of the Layout protocol: sizeThatFits ran first
        // (that is where it trapped), placeSubviews needs a real pass.
        let measured = host.fittingSize
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        // The presence half, in its own hierarchy: the same node, wrapped
        // in a layout that reports how many subviews it received.
        let counter = NSHostingView(
            rootView: CountingCell(name: name) { KayaRender(node: image) })
        counter.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        _ = counter.fittingSize
        counter.layoutSubtreeIfNeeded()

        let decoded = image.image != nil
        let count = contributed[name] ?? -1
        print(
            "  \(name): imageSize=\(image.imageSize) decoded=\(decoded) "
                + "fitting=\(Int(measured.width))x\(Int(measured.height)) subviews=\(count)")
        // The decode may legitimately succeed (ImageIO is lenient) or
        // fail; what may not happen is a size string that agrees with
        // neither — and a nil decode MUST read 0x0, which is the string
        // the gallery scene freezes on five platforms.
        if !decoded && image.imageSize != "0x0" {
            print("  \(name): FAIL — nil decode read \(image.imageSize), wanted 0x0")
            failures += 1
        }
        // ONE NODE, ONE VIEW, whatever the decoder said: a kind that
        // renders nothing leaves a hole every positional reader falls
        // into. GTK and WinUI have this by construction.
        if count != 1 {
            print(
                "  \(name): FAIL — the image kind handed its layout \(count) subviews, "
                    + "wanted exactly 1. A failed decode must still occupy the node's slot.")
            failures += 1
        }
    }

    // AND THE CELL'S OWN CLAUSE, which the image cases can no longer
    // reach now that no image renders nothing. A kind number this
    // interpreter does not know falls to KayaRender's `default:` arm and
    // produces no view at all — the state a guest reaches by running an
    // app built against a newer core than the interpreter it loaded.
    let stranger = KayaNode(id: 4, kind: 250, tag: Array("stranger".utf8))
    stranger.grow = 1.0
    let stray = KayaNode(id: 3, kind: UInt32(KAYA_KIND_COLUMN), tag: [])
    stray.children = [stranger]
    let host = NSHostingView(rootView: KayaRender(node: stray, isRoot: true))
    host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    let measured = host.fittingSize
    host.layoutSubtreeIfNeeded()
    print("  unknown-kind-250: fitting=\(Int(measured.width))x\(Int(measured.height))")

    return failures == 0 ? 0 : 1
}
