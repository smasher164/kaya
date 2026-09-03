import Foundation

/// The watchdog's fire path dumps the interpreter's verb trace
/// (KayaVTrace in swift/KayaSwiftUI.swift) before it leaves; the cut this
/// probe compiles is the watchdog alone, so the ring is a no-op here —
/// tools/check-verbs.py holds the real one's shape and its call sites.
enum KayaVTrace {
    static func dump(_ reason: String) {}
}

/// THE RUNTIME NEGATIVE FOR THE STEP CEILING: a REAL wedged main thread,
/// the interpreter's OWN watchdog source (tools/check-harness-ceiling.py
/// cuts it out of swift/KayaSwiftUI.swift and compiles it with this
/// file), and the question the four choke measurements asked — does
/// anything come out of a harness whose hop is never answered?
///
/// BOTH HOPS, because the measurement found both: a STEP that never
/// answers (no verdict at all, macOS and iOS) and, once a verdict IS
/// published, an EXIT that never runs (linux N=6000, verdict at 103.63s
/// and killed from outside at 120s).
///
/// IN A CHILD PROCESS, because what the guard promises is that the
/// harness LEAVES: the watchdog publishes and `_exit`s, which the
/// process it ends cannot report on. This binary is both halves.
@main
enum KayaWedgeProbe {
    static let ceilingMs = 1500

    static func main() {
        if let mode = ProcessInfo.processInfo.environment["KAYA_WEDGE_CHILD"] {
            child(mode)
        }
        parent()
    }

    /// The harness thread's shape: arm, then wait on a main thread that
    /// will never answer.
    static func child(_ mode: String) -> Never {
        let watchdog = KayaStepWatchdog(ceiling: kayaStepCeilingSetting())
        watchdog.start()
        if mode == "exit" {
            // The verdict is already out; only the platform's own exit
            // path is missing.
            watchdog.published(0)
        } else {
            Thread.detachNewThread {
                watchdog.enter("expect label#0 \"x\"")
                DispatchQueue.main.sync { print("swiftui-wedge: the main thread answered") }
                print("swiftui-wedge: the step returned on its own")
                exit(9)
            }
        }
        // THE WEDGE: a main thread that never gets back to its run loop,
        // so nothing enqueued on the main queue can ever run. The
        // measured one was BUSY rather than asleep (a SwiftUI update
        // pass over 20000 rows); the hop cannot complete either way, and
        // sleeping keeps the gate off the CPU.
        while true {
            Thread.sleep(forTimeInterval: 1)
        }
    }

    static func parent() -> Never {
        let (status, out, waited) = runChild("step")
        if status == nil {
            fail(
                String(format: "the wedged child was still running after %.1fs", waited)
                    + " — the step ceiling never fired, which is the silence the four choke"
                    + " measurements recorded (docs/measurements/choke-*-2026-08-24.txt)."
                    + " Its output:\n" + out)
        }
        if status != 1 {
            fail("the wedged child left with status \(status!), wanted 1:\n\(out)")
        }
        if !out.contains("KAYA_SELFTEST: FAILED (no verdict") {
            fail("the wedged child left without publishing a verdict:\n\(out)")
        }
        // The sentence NAMES THE STEP: a fixed one would be printed for
        // every wedge and name none of them.
        if !out.contains("expect label#0") {
            fail("the verdict does not name the step it was inside:\n\(out)")
        }
        if waited * 1000 < Double(ceilingMs) {
            fail(String(format: "the ceiling fired at %.2fs, before its own deadline", waited))
        }

        let (exitStatus, exitOut, exitWaited) = runChild("exit")
        if exitStatus == nil {
            fail(
                String(format: "the child was still running %.1fs after publishing its", exitWaited)
                    + " verdict — the exit grace never fired, which is the linux lane's"
                    + " N=6000. Its output:\n" + exitOut)
        }
        // UNDER THE VERDICT'S OWN CODE: that run passed, and a wedged
        // exit must not turn a pass into a failure.
        if exitStatus != 0 {
            fail("the wedged exit left with status \(exitStatus!), wanted 0:\n\(exitOut)")
        }
        if !exitOut.contains("the verdict is published and the platform's exit path has not run") {
            fail("the exit grace left without saying why:\n\(exitOut)")
        }
        print(String(
            format: "swiftui-wedge: OK (verdict published %.2fs into a wedged main thread; a "
                + "published verdict left %.2fs after its exit hop went unanswered)",
            waited, exitWaited))
        exit(0)
    }

    /// (exit status or nil if it outlived the cap, its output, seconds).
    static func runChild(_ mode: String) -> (Int32?, String, TimeInterval) {
        let capMs = Int(ProcessInfo.processInfo.environment["KAYA_WEDGE_CAP_MS"] ?? "") ?? 30000
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kaya-swiftui-wedge-\(getpid())-\(mode).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let sink = try? FileHandle(forWritingTo: log) else {
            fail("cannot open \(log.path) for the child's output")
        }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var env = ProcessInfo.processInfo.environment
        env["KAYA_WEDGE_CHILD"] = mode
        env["KAYA_STEP_CEILING_MS"] = String(ceilingMs)
        child.environment = env
        child.standardOutput = sink
        child.standardError = sink
        do {
            try child.run()
        } catch {
            fail("cannot start the child: \(error)")
        }
        let started = Date()
        while child.isRunning, Date().timeIntervalSince(started) * 1000 < Double(capMs) {
            usleep(20000)
        }
        let waited = Date().timeIntervalSince(started)
        let running = child.isRunning
        if running {
            child.terminate()
        }
        let out = (try? String(contentsOf: log, encoding: .utf8)) ?? "<no output>"
        try? FileManager.default.removeItem(at: log)
        return (running ? nil : child.terminationStatus, out, waited)
    }

    static func fail(_ why: String) -> Never {
        FileHandle.standardError.write(Data("swiftui-wedge: FAIL — \(why)\n".utf8))
        exit(1)
    }
}
