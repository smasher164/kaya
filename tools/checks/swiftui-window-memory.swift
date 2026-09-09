// THE SWIFTUI WINDOW-MEMORY RULE, DRIVEN FOR REAL. The interpreter's own
// `// MARK: - Window memory` block is cut out of swift/KayaSwiftUI.swift by
// tools/check-window-memory.py and compiled with this file, so there is no
// second copy of the rule to drift. GTK and WinUI each already have this
// test (gtk::frame_tests,
// winui::tests::window_memory_parses_clamps_and_opts_out); nothing a scene
// can drive tells any of these decisions apart — taskspersist.steps asserts
// ONE size on ONE window and stays green with the by-value rule inverted,
// with the clamp gone, with a malformed stored line taken at face value and
// with the opt-out ignored.
//
// Everything below the doubles is the interpreter's own source. The doubles
// are the five names the cut block reaches outside itself.

import AppKit

// MARK: - The interpreter's environment, doubled

final class KayaWindowModel {
    let id: UInt64
    var width: Double?
    var height: Double?
    var rememberFrame = true
    init(id: UInt64) { self.id = id }
}

final class KayaSceneModel {
    var windows: [UInt64: KayaWindowModel] = [:]
}

nonisolated(unsafe) let kayaScene = KayaSceneModel()
nonisolated(unsafe) var kayaNSWindows: [UInt64: NSWindow] = [:]

func kayaInvalidateTableGeometry() {}
func kayaDiag(_ msg: String) {}

/// The core's pref store, stood in for — and COUNTED, since "the frame was
/// written once" and "the frame was written three times" are the same store
/// afterwards and only the count tells the coalescing from its absence.
enum KayaHost {
    nonisolated(unsafe) static var store: [UInt64: String] = [:]
    nonisolated(unsafe) static var writes = 0

    static func windowFrame(_ window: UInt64) -> String? { store[window] }

    static func setWindowFrame(_ window: UInt64, _ text: String) {
        writes += 1
        store[window] = text
    }
}

// MARK: - The probe

@main
@MainActor
enum KayaWindowMemoryProbe {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ name: String, _ got: Bool) {
        if !got {
            print("swiftui-window-memory: FAIL — \(name)")
            failures += 1
        }
    }

    static func window(_ id: UInt64, _ w: Double?, _ h: Double?,
                       remember: Bool = true) {
        let model = KayaWindowModel(id: id)
        model.width = w
        model.height = h
        model.rememberFrame = remember
        kayaScene.windows[id] = model
    }

    static func declare(_ id: UInt64, _ w: Double?, _ h: Double?) {
        kayaScene.windows[id]?.width = w
        kayaScene.windows[id]?.height = h
    }

    /// Pump the main queue until `done` or the deadline: the save rides
    /// DispatchQueue.main.async, so nothing has been written when
    /// kayaNoteWindowFrame returns.
    static func pump(_ seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !done() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // VACUITY FIRST. Under a recording tile every one of these
        // functions is a no-op by design (kayaFrameMemoryInert), so a
        // probe run with KAYA_WIN_SLOT set would measure nothing and say
        // OK.
        if kayaFrameMemoryInert {
            print("swiftui-window-memory: REFUSAL — KAYA_WIN_SLOT is set, "
                + "so every window-memory function is inert and this probe "
                + "would measure nothing.")
            exit(2)
        }
        let screen = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
        guard let screen, screen.width >= 900, screen.height >= 700 else {
            print("swiftui-window-memory: REFUSAL — no NSScreen answered, or "
                + "its visible frame is under 900x700: the clamp and restore "
                + "halves place real rects inside it. This needs a logged-in "
                + "GUI session on an ordinary display.")
            exit(2)
        }
        print("swiftui-window-memory: the visible frame this run measured "
            + "against is \(kayaWindowFrameText(screen))")

        byValue()
        parse()
        clamp()
        saveAndRestore()

        if failures == 0 {
            print("swiftui-window-memory: OK — the six by-value cases, both "
                + "frame spellings and six malformed lines, the clamp, the "
                + "coalesced and deduplicated save, and the opt-out")
        }
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: The by-value rule (docs/tasks-s4-plan.md §4)

    static func byValue() {
        let remembered = NSRect(x: 120, y: 40, width: 900, height: 620)
        kayaFrameMemory.removeAll()
        kayaFrameMemoryDeclared.removeAll()

        // 1. A window that opened at its own default size: every write
        //    applies, because there is nothing to defend.
        window(0, 960, 640)
        expect("a window with no memory takes every write",
            !kayaMemoryHoldsSize(0))

        // 2. A window restored from the store. The first size it is asked
        //    for is the app's launch declaration, whichever side of
        //    materialization the props land on, and it is refused.
        kayaFrameMemory[0] = remembered
        kayaFrameMemoryDeclared[0] = nil
        declare(0, 960, 640)
        expect("a restored window's first size is its declaration and is refused",
            kayaMemoryHoldsSize(0))
        expect("the refused declaration is remembered as the declaration",
            kayaFrameMemoryDeclared[0] == NSSize(width: 960, height: 640))

        // 3. The same size again is the same declaration, however many
        //    batches later it arrives — a rebuild re-declaring its size is
        //    not the app resizing itself.
        expect("the same declaration again is still the declaration",
            kayaMemoryHoldsSize(0))

        // 4. The declaration arrives ONE PROP AT A TIME, so a window whose
        //    other axis has not landed yet has not declared anything: the
        //    memory holds and nothing is recorded as the declaration.
        window(1, 960, nil)
        kayaFrameMemory[1] = remembered
        kayaFrameMemoryDeclared[1] = nil
        expect("a declaration still arriving (one axis) holds the memory",
            kayaMemoryHoldsSize(1))
        expect("a half-arrived declaration is not recorded as the declaration",
            kayaFrameMemoryDeclared[1] == nil)
        declare(1, 960, 640)
        expect("the completed pair is the declaration",
            kayaMemoryHoldsSize(1))
        // ...and a later value differing on the OTHER axis alone is still
        // the app resizing itself.
        declare(1, 960, 700)
        expect("a runtime resize on the height axis alone wins",
            !kayaMemoryHoldsSize(1))
        expect("...and ends that window's memory",
            kayaFrameMemory[1] == nil)

        // 5. The first DIFFERENT size is the app resizing itself. It
        //    applies, and the memory is over for that window on BOTH axes:
        //    a window the app has resized once is the app's from then on.
        declare(0, 1200, 640)
        expect("the first DIFFERENT size is the app resizing itself and ends the memory",
            !kayaMemoryHoldsSize(0))
        expect("the ended memory keeps no frame", kayaFrameMemory[0] == nil)
        expect("the ended memory keeps no declaration",
            kayaFrameMemoryDeclared[0] == nil)
        declare(0, 960, 640)
        expect("everything after it applies too, the declared size included",
            !kayaMemoryHoldsSize(0))

        // 6. Per window, never process-wide.
        window(2, 800, 600)
        kayaFrameMemory[2] = remembered
        kayaFrameMemoryDeclared[2] = nil
        window(3, 800, 600)
        expect("a remembered window still refuses its declaration",
            kayaMemoryHoldsSize(2))
        expect("the memory is per window, never process-wide",
            !kayaMemoryHoldsSize(3))
    }

    // MARK: Both frame spellings, and six malformed lines

    static func parse() {
        let current = NSRect(x: 11, y: 22, width: 33, height: 44)
        let frame = NSRect(x: 120, y: 40, width: 900, height: 620)
        expect("what this backend writes is four words",
            kayaWindowFrameText(frame) == "120 40 900 620")
        expect("what it writes, read back",
            kayaParseWindowFrame(kayaWindowFrameText(frame), current: current)
                == frame)
        // A backend with no window position to give writes `-` twice, and
        // this side keeps the window where it is (GTK4 has no position).
        expect("`- - <w> <h>` restores the size and keeps the position",
            kayaParseWindowFrame("- - 900 620", current: current)
                == NSRect(x: 11, y: 22, width: 900, height: 620))
        expect("a negative position is a position, not a `-`",
            kayaParseWindowFrame("-40 -20 900 620", current: current)
                == NSRect(x: -40, y: -20, width: 900, height: 620))
        // Anything else is no frame at all rather than a guessed one.
        for bad in ["900 620", "120 40 900 620 7", "120 40 0 620",
                    "120 40 -900 620", "120 40 wide 620", ""] {
            expect("a malformed stored line answers nil, not a guess: \(bad.isEmpty ? "<empty>" : bad)",
                kayaParseWindowFrame(bad, current: current) == nil)
        }
    }

    // MARK: The clamp — onto a screen that still has the frame

    static func clamp() {
        guard let visible = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
        else { return }

        let inside = NSRect(x: visible.minX + 40, y: visible.minY + 40,
                            width: 400, height: 300)
        expect("a frame already on a screen is left alone",
            kayaClampFrameToScreens(inside) == inside)

        // Saved on a display that has since left: unclamped is a window
        // nobody can reach, so the caller keeps the app's own size instead.
        expect("a frame off EVERY screen falls back to nil",
            kayaClampFrameToScreens(
                NSRect(x: -50000, y: -50000, width: 400, height: 300)) == nil)

        // Hanging off the right edge of the screen it mostly overlaps:
        // slid back inside, at its own size.
        let straddling = NSRect(x: visible.maxX - 100, y: visible.minY + 20,
                                width: 400, height: 300)
        let slid = kayaClampFrameToScreens(straddling)
        expect("a frame partly on a screen is slid inside it",
            slid == NSRect(x: visible.maxX - 400, y: visible.minY + 20,
                           width: 400, height: 300))

        // Saved on a bigger screen: the size shrinks to what this one has.
        let oversize = NSRect(x: visible.minX - 50, y: visible.minY - 50,
                              width: visible.width + 300,
                              height: visible.height + 200)
        expect("a frame bigger than the screen is trimmed onto it",
            kayaClampFrameToScreens(oversize) == visible)
    }

    // MARK: The save — coalesced, deduplicated, and the opt-out

    static func saveAndRestore() {
        guard let visible = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
        else { return }
        let origin = NSPoint(x: visible.minX + 60, y: visible.minY + 60)

        func makeWindow(_ size: NSSize) -> NSWindow {
            // Never ordered front: this runs on the maintainer's own desk.
            NSWindow(
                contentRect: NSRect(origin: origin, size: size),
                styleMask: [.titled, .resizable], backing: .buffered,
                defer: false)
        }

        // --- A remembering window. -----------------------------------
        kayaNSWindows.removeAll()
        KayaHost.store.removeAll()
        KayaHost.writes = 0
        kayaFrameCoalesced.removeAll()
        kayaFrameMemory.removeAll()
        kayaFrameMemoryDeclared.removeAll()

        let live = makeWindow(NSSize(width: 500, height: 400))
        kayaNSWindows[9] = live
        window(9, nil, nil)

        kayaSaveWindowFrame(9)
        expect("a remembering window's frame reaches the store",
            KayaHost.writes == 1
                && KayaHost.store[9] == kayaWindowFrameText(live.frame))
        kayaSaveWindowFrame(9)
        expect("a frame that did not move is not written again",
            KayaHost.writes == 1)
        live.setFrame(NSRect(origin: origin, size: NSSize(width: 620, height: 480)),
                      display: false)
        kayaSaveWindowFrame(9)
        expect("a frame that DID move is written",
            KayaHost.writes == 2
                && KayaHost.store[9] == kayaWindowFrameText(live.frame))

        // ONE WRITE PER WINDOW PER TURN: a drag fires didMove per frame,
        // and the notifications of one turn coalesce into the single save
        // that follows them. Nothing is written before the queue turns —
        // which is also what tells this apart from a synchronous write.
        KayaHost.writes = 0
        live.setFrame(NSRect(origin: origin, size: NSSize(width: 700, height: 520)),
                      display: false)
        kayaNoteWindowFrame(9, live)
        kayaNoteWindowFrame(9, live)
        kayaNoteWindowFrame(9, live)
        expect("a noted frame is coalesced, not written on the spot",
            KayaHost.writes == 0 && kayaFrameCoalesced.contains(9))
        pump(2) { KayaHost.writes > 0 }
        expect("three notes on one turn are ONE write",
            KayaHost.writes == 1
                && KayaHost.store[9] == kayaWindowFrameText(live.frame))
        expect("the turn's coalescing is released for the next one",
            !kayaFrameCoalesced.contains(9))

        // --- The restore. --------------------------------------------
        let restoring = makeWindow(NSSize(width: 500, height: 400))
        kayaNSWindows[11] = restoring
        window(11, 960, 640)
        let wanted = NSRect(x: visible.minX + 30, y: visible.minY + 30,
                            width: min(720, visible.width - 80),
                            height: min(500, visible.height - 80))
        KayaHost.store[11] = kayaWindowFrameText(wanted)
        kayaRestoreWindowFrame(11, restoring)
        expect("the stored frame is the window's",
            restoring.frame.size == wanted.size)
        expect("the restored frame goes on the record as the memory",
            kayaFrameMemory[11] == wanted)
        expect("the declaration standing at restore is the one refused later",
            kayaFrameMemoryDeclared[11] == NSSize(width: 960, height: 640))
        expect("and the restored window then refuses that declaration",
            kayaMemoryHoldsSize(11))

        // A stored frame on a display that has left restores nothing: the
        // app keeps the size it asked for.
        let orphaned = makeWindow(NSSize(width: 500, height: 400))
        kayaNSWindows[12] = orphaned
        window(12, 960, 640)
        let before = orphaned.frame
        KayaHost.store[12] = "-50000 -50000 400 300"
        kayaRestoreWindowFrame(12, orphaned)
        expect("a frame off every screen restores nothing",
            orphaned.frame == before && kayaFrameMemory[12] == nil)

        // --- remember_frame false: nothing saved, nothing restored. ---
        kayaNSWindows.removeAll()
        KayaHost.store.removeAll()
        KayaHost.writes = 0
        kayaFrameCoalesced.removeAll()

        let optedOut = makeWindow(NSSize(width: 500, height: 400))
        kayaNSWindows[10] = optedOut
        window(10, nil, nil, remember: false)

        kayaNoteWindowFrame(10, optedOut)
        expect("an opted-out window is not even coalesced",
            kayaFrameCoalesced.isEmpty)
        kayaSaveWindowFrame(10)
        expect("an opted-out window's frame is not saved",
            KayaHost.writes == 0 && KayaHost.store[10] == nil)
        // The last hop before a process that is about to leave.
        kayaFlushWindowFrames()
        expect("...not on the way out either", KayaHost.writes == 0)

        KayaHost.store[10] = kayaWindowFrameText(
            NSRect(x: visible.minX + 10, y: visible.minY + 10,
                   width: 800, height: 600))
        let held = optedOut.frame
        kayaRestoreWindowFrame(10, optedOut)
        expect("an opted-out window's frame is not restored",
            optedOut.frame == held && kayaFrameMemory[10] == nil)
    }
}
