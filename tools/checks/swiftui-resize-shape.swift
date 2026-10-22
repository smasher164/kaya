// THE WINDOW SERVER'S HIT SHAPE, DRIVEN. tools/check-window-memory.py cuts
// the interpreter's own `// MARK: - The window server's hit shape` block out
// of swift/KayaSwiftUI.swift and compiles it with this file. The window is
// REAL and reaches the window server, because the shape the server hit-tests
// is the thing measured and nothing in the process can stand in for it; it
// is small and sits under the menu bar's right end, where no lane's guest is
// placed, since the gate sweep runs beside the mac lane. The premise is read
// inside the resize's own main-thread block, where no frame at the new size
// can have been drawn yet; the content view's 300 ms draw is what the shape
// then follows (326-329 ms to cover the corners against 13-16 ms with a plain
// view, docs/measurements/window-server-shape-2026-10-21.md).

import AppKit

final class KayaSlowView: NSView {
    override func draw(_ rect: NSRect) {
        Thread.sleep(forTimeInterval: 0.3)
        NSColor.systemBlue.setFill()
        rect.fill()
    }
}

@main
enum KayaResizeShapeProbe {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ name: String, _ got: Bool, _ saw: String = "") {
        if !got {
            print("swiftui-resize-shape: FAIL — \(name)" + (saw.isEmpty ? "" : " (saw: \(saw))"))
            failures += 1
        }
    }

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first else {
            print("swiftui-resize-shape: FAIL — no screen to put a window on")
            exit(1)
        }
        let small = NSSize(width: 120, height: 80)
        let big = NSSize(width: 240, height: 160)
        let visible = screen.visibleFrame
        let window = NSWindow(
            contentRect: NSRect(
                x: visible.maxX - 260, y: visible.maxY - 8 - 28 - small.height,
                width: small.width, height: small.height),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "kaya resize-shape probe"
        window.contentView = KayaSlowView()
        window.orderFrontRegardless()

        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.5)
            let number = DispatchQueue.main.sync { window.windowNumber }
            // 1. The premise, read inside the resize's own main-thread block so
            //    no run-loop turn can draw a frame first: the server still hands
            //    a corner the growth brought in to whatever lies beneath.
            let (before, point, early, earlyBounds): (NSRect, NSPoint, (ours: Bool, above: [String]), String) =
                DispatchQueue.main.sync {
                    let was = window.frame
                    window.setContentSize(big)
                    let now = window.frame
                    let corner = NSPoint(x: now.maxX - 8, y: now.minY + 8)
                    return (was, corner, kayaServerHolds(window, corner), kayaServerBounds(number))
                }
            print("  right after setContentSize: corner \(point) covered \(early.ours), under "
                + "\(early.above); the server's bounds \(earlyBounds), AppKit's frame "
                + "\(DispatchQueue.main.sync { window.frame })")
            expect("right after the resize the window server's shape of this window leaves out a "
                + "corner the resize brought in", !early.ours, "\(early.above)")

            // 2. The wait, off the main thread, returns once the shape moved.
            let waited = kayaAwaitResizeShape(window, before: before)
            print("  " + waited)
            let late = DispatchQueue.main.sync { kayaServerHolds(window, point) }
            expect("after the wait the server's shape of this window covers that corner",
                late.ours, "\(late.above)")
            expect("the wait says how long it took and what sat above",
                waited.hasPrefix("resize shape: the window server's shape of window \(number) covered all ")
                    && waited.contains(" ms, with up to "), waited)
            let top = DispatchQueue.main.sync { kayaServerHit(point) }
            expect("the server names a pid for the top window at the corner",
                top.owner.contains("(pid "), top.owner)

            // 3. A shrink brings no corner in.
            let shrunk = DispatchQueue.main.sync { () -> NSRect in
                let was = window.frame
                window.setContentSize(small)
                return was
            }
            let shrink = kayaAwaitResizeShape(window, before: shrunk)
            print("  " + shrink)
            expect("a shrink brings no corner in and waits nothing",
                shrink.contains("brought no content corner outside"), shrink)

            // 4. Past the bound the sentence names each corner's holder.
            let grown = DispatchQueue.main.sync { () -> NSRect in
                let was = window.frame
                window.setContentSize(big)
                return was
            }
            let expired = kayaAwaitResizeShape(window, before: grown, bound: 0.05) { _ in
                (false, ["window 1 of Elsewhere (pid 1, layer 0, bounds 0,0,1,1)"])
            }
            print("  " + expired)
            expect("past the bound the sentence names each corner's holder and both frames",
                expired.contains("still leaves out 3 of 3 corner(s)")
                    && expired.contains("under window 1 of Elsewhere")
                    && expired.contains("AppKit's frame") && expired.contains("the server's bounds"),
                expired)
            _ = kayaAwaitResizeShape(window, before: grown)

            // 5. Asked on the main thread it refuses in a sentence.
            let refused = DispatchQueue.main.sync { kayaAwaitResizeShape(window, before: grown) }
            print("  " + refused)
            expect("asked on the main thread it refuses rather than waits",
                refused.contains("asked on the main thread"), refused)

            // 6. A point no window holds.
            let nowhere = DispatchQueue.main.sync {
                kayaServerHit(NSPoint(x: screen.frame.maxX + 5000, y: screen.frame.maxY + 5000))
            }
            expect("a point off every screen reads as no window", nowhere.owner == "no window", nowhere.owner)
            let nowhereOurs = DispatchQueue.main.sync {
                kayaServerHolds(window, NSPoint(x: screen.frame.maxX + 5000, y: screen.frame.maxY + 5000))
            }
            expect("a point off every screen is outside this window's shape under nothing",
                !nowhereOurs.ours && nowhereOurs.above.isEmpty, "\(nowhereOurs)")

            DispatchQueue.main.sync {
                window.orderOut(nil)
                print("swiftui-resize-shape: \(failures == 0 ? "OK" : "FAILED (\(failures))")")
                exit(failures == 0 ? 0 : 1)
            }
        }
        app.run()
    }
}
