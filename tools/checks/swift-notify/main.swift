// The process-level notification handler's DISPATCH ORDER
// (docs/tasks-s9-plan.md R1), run rather than read. HEADLESS: the library
// links and records submit, but the core loop is never entered. Compiled
// as ONE MODULE with bindings/swift/*.swift, so the internal decision
// method is in reach — the ring loop's switch has no seam a test can
// reach, which is why that decision is a method at all.

import Foundation

func check(_ ok: Bool, _ what: String) {
    if !ok {
        print("notify-order: FAIL — " + what)
        exit(1)
    }
}

let app = KayaApp()
var oneShot: [UInt32] = []
var process: [(UInt64, UInt32)] = []
app.onNotificationActivation { _, id, outcome in process.append((id, outcome)) }
try! app.build { tx in
    _ = tx.showNotification(
        12, title: "bound at the show",
        onResult: { _, outcome in oneShot.append(outcome) })
}

// CASE 1: an id WITH a one-shot handler is answered by it, and the
// process-level handler is not consulted at all.
app.notificationResult(12, UInt32(KAYA_NOTIFICATION_OUTCOME_ACTIVATED))
check(oneShot == [UInt32(KAYA_NOTIFICATION_OUTCOME_ACTIVATED)],
      "the one-shot handler did not answer: \(oneShot)")
check(process.isEmpty,
      "the process-level handler answered an id that HAD a one-shot handler")

// CASE 2: an id this process never showed — the relaunch case.
app.notificationResult(77, UInt32(KAYA_NOTIFICATION_OUTCOME_ACTIVATED))
check(process.count == 1 && process[0] == (77, UInt32(KAYA_NOTIFICATION_OUTCOME_ACTIVATED)),
      "a result with no one-shot handler did not reach the process-level one")

// CASE 3: it does NOT retire.
app.notificationResult(78, UInt32(KAYA_NOTIFICATION_OUTCOME_REFUSED))
check(process.count == 2 && process[1] == (78, UInt32(KAYA_NOTIFICATION_OUTCOME_REFUSED)),
      "the process-level handler retired after its first result")

// AND THE DROP IS ANNOUNCED, compared in full: a drop nobody announced is
// R5's defect class, and this sentence is the only signal a relaunched
// process's author gets that nothing listened. The child re-exec is the
// swift-abort file's own trick one reason over — stderr is a real fd
// here, so the sentence is read back from a pipe.
if ProcessInfo.processInfo.environment["KAYA_NOTIFY_DROP"] != nil {
    // A FRESH app with neither handler registered — Swift has no
    // one-app-per-process latch.
    let bare = KayaApp()
    bare.notificationResult(41, UInt32(KAYA_NOTIFICATION_OUTCOME_REFUSED))
    exit(0)
}

let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
child.environment = ProcessInfo.processInfo.environment.merging(
    ["KAYA_NOTIFY_DROP": "1"]) { _, new in new }
let pipe = Pipe()
child.standardError = pipe
try! child.run()
let said = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
child.waitUntilExit()
let want = "kaya: notification 41 outcome refused reached no handler — "
    + "none was bound at the show and no process-level handler is "
    + "registered (KayaApp.onNotificationActivation)"
check(said.trimmingCharacters(in: .whitespacesAndNewlines) == want,
      "the drop was announced as \"\(said.trimmingCharacters(in: .whitespacesAndNewlines))\", wanted \"\(want)\"")

print("notify-order: OK — the one-shot wins, an unknown id reaches the "
      + "process handler, it does not retire, and an unclaimed result "
      + "announces its drop")
