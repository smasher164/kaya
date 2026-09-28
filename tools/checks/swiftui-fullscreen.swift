// THE SWIFTUI FULLSCREEN RULE, DRIVEN. tools/check-window-memory.py cuts the
// interpreter's own `// MARK: - Fullscreen` block out of
// swift/KayaSwiftUI.swift and compiles it with this file. The window is a
// double whose toggle flips a flag and never reaches the window server: a
// real toggle would switch the host's display to a new Space
// (docs/fullscreen-plan.md §4.1). The delegate's callbacks are driven by hand,
// in the order AppKit posts them.

import AppKit

// MARK: - The interpreter's environment, doubled

final class KayaWindowModel {
    var fullscreen = false
}

final class KayaSceneModel {
    var windows: [UInt64: KayaWindowModel] = [:]
}

nonisolated(unsafe) let kayaScene = KayaSceneModel()
nonisolated(unsafe) var kayaNSWindows: [UInt64: NSWindow] = [:]

func kayaDiag(_ msg: String) {}

enum KayaHost {
    nonisolated(unsafe) static var emitted: [Bool] = []
    static func emitFullscreenChanged(_ window: UInt64, _ on: Bool) { emitted.append(on) }
}

/// The style mask carries `.fullScreen` from the call itself (§4.1), so the
/// double flips it inside toggleFullScreen, as AppKit does.
final class KayaProbeWindow: NSWindow {
    var filled = false
    var toggles = 0
    override var styleMask: NSWindow.StyleMask {
        get { filled ? [.titled, .resizable, .fullScreen] : [.titled, .resizable] }
        set {}
    }
    override func toggleFullScreen(_ sender: Any?) {
        toggles += 1
        filled.toggle()
    }
}

// MARK: - The probe

@main
@MainActor
enum KayaFullscreenProbe {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ name: String, _ got: Bool) {
        if !got {
            print("swiftui-fullscreen: FAIL — \(name)")
            failures += 1
        }
    }

    static func pump() {
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    static func fresh() -> KayaProbeWindow {
        let w = KayaProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        kayaNSWindows[0] = w
        kayaScene.windows[0] = KayaWindowModel()
        kayaFullscreenInFlight.removeAll()
        kayaFullscreenAppWrote.removeAll()
        kayaFullscreenFailures.removeAll()
        KayaHost.emitted.removeAll()
        return w
    }

    /// The user's door: will, the mask flips, did.
    static func userTurns(_ w: KayaProbeWindow, during: () -> Void = {}) {
        kayaFullscreenWillChange(0, w)
        w.filled.toggle()
        during()
        kayaFullscreenDidChange(0, w)
        pump()
        if case .kaya? = kayaFullscreenInFlight[0] { kayaFullscreenDidChange(0, w); pump() }
    }

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared

        var w = fresh()
        kayaAppWroteFullscreen(0, true)
        expect("the app's write toggles the window", w.filled && w.toggles == 1)
        kayaFullscreenDidChange(0, w)
        pump()
        expect("the app's own write never echoes", KayaHost.emitted.isEmpty)

        w = fresh()
        userTurns(w)
        expect("the user's change is reported with its state",
            KayaHost.emitted == [true] && kayaScene.windows[0]?.fullscreen == true)

        w = fresh()
        userTurns(w) { kayaAppWroteFullscreen(0, false) }
        expect("a write held during the user's transition is not toggled into it",
            w.toggles == 1)
        expect("a user change the app overrode before it settled is not reported",
            KayaHost.emitted.isEmpty)
        expect("the app's write wins: the window ends on the app's value",
            !w.filled && kayaScene.windows[0]?.fullscreen == false)

        w = fresh()
        userTurns(w) { kayaAppWroteFullscreen(0, true) }
        expect("an app write agreeing with the user's result is no override",
            KayaHost.emitted == [true] && w.filled && w.toggles == 0)

        w = fresh()
        kayaFullscreenWillChange(0, w)
        kayaAppWroteFullscreen(0, true)
        kayaFullscreenFailed(0, w, entering: true)
        pump()
        expect("a failed user transition reports nothing and the held write applies",
            KayaHost.emitted.isEmpty && w.filled && kayaFullscreenAppWrote.isEmpty)

        w = fresh()
        kayaAppWroteFullscreen(0, true)
        kayaAppWroteFullscreen(0, false)
        expect("a second write during kaya's own transition is held", w.toggles == 1)
        kayaFullscreenDidChange(0, w)
        pump()
        expect("and reconciled one turn after it settles", w.toggles == 2 && !w.filled)

        if failures == 0 {
            print("swiftui-fullscreen: OK — the app's write, the user's change, "
                + "an override held and unreported, an agreeing write, a failed "
                + "transition, and a write held during kaya's own")
            exit(0)
        }
        exit(1)
    }
}
