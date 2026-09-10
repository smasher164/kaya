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

// THE LINK DROP'S CHILD, branched BEFORE anything else runs: it is read
// through a pipe, and a child that also ran the notification section
// would echo that section's verdict into the parent's own output.
if ProcessInfo.processInfo.environment["KAYA_LINK_DROP"] != nil {
    let bare = KayaApp()
    bare.link("task/{key}") { _, _ in }
    bare.linkOpened(9, "dev.kaya.aurora.notes://task/t2", [:])
    bare.linkOpened(0, "dev.kaya.aurora.notes://nope", [:])
    exit(0)
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

// THE APP-LINK ROUTES (docs/app-links-plan.md §4). Four things no lane can
// see: the declaration's BYTES, the ids the counter mints, the dispatch by
// route id, and the two drops — a route that matched and reached no
// handler says so, route 0 says nothing because the CORE already announced
// that miss naming every declared pattern. NOTHING HERE READS A PATTERN:
// the core is the one parser and the one author of every declaration
// refusal, and it faults at apply.
let linkApp = KayaApp()
var linkSeen: [(String, String)] = []
linkApp.link("task/{key}") { _, params in linkSeen.append(("task", params["key"] ?? "")) }
linkApp.link("{section}") { _, params in linkSeen.append(("section", params["section"] ?? "")) }

// CASE 1: the declaration is the generated record, parked, and the ids
// come from the binding's own counter starting at 1.
var wanted = KayaTx()
wanted.declareLinkRoute(1, .str("task/{key}"))
wanted.declareLinkRoute(2, .str("{section}"))
check(linkApp.pendingRoutes.bytes == wanted.bytes,
      "link did not park the generated records, or minted the wrong ids")

// CASE 2: a link on a declared route reaches its handler with the
// captures, and the registration does NOT retire.
linkApp.linkOpened(1, "dev.kaya.aurora.notes://task/t2", ["key": "t2"])
linkApp.linkOpened(1, "dev.kaya.aurora.notes://task/t1", ["key": "t1"])
linkApp.linkOpened(2, "dev.kaya.aurora.notes://today", ["section": "today"])
check(linkSeen.count == 3 && linkSeen[0] == ("task", "t2")
      && linkSeen[1] == ("task", "t1") && linkSeen[2] == ("section", "today"),
      "a link did not reach its route's handler with the captures, or the registration retired: \(linkSeen)")

// CASE 3 and CASE 4: the two drops, read back from the child branch at
// the top of this file, the way the notification drop above is.
let linkChild = Process()
linkChild.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
linkChild.environment = ProcessInfo.processInfo.environment.merging(
    ["KAYA_LINK_DROP": "1"]) { _, new in new }
let linkPipe = Pipe()
linkChild.standardError = linkPipe
try! linkChild.run()
let linkSaid = String(decoding: linkPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
linkChild.waitUntilExit()
let linkWant = "kaya: link dev.kaya.aurora.notes://task/t2 matched route 9 and "
    + "reached no handler — none is registered for it (KayaApp.link)"
check(linkSaid.trimmingCharacters(in: .whitespacesAndNewlines) == linkWant,
      "the link drop was announced as \"\(linkSaid.trimmingCharacters(in: .whitespacesAndNewlines))\", wanted \"\(linkWant)\"")

print("link-route: OK — the declaration parks the generated record, the "
      + "dispatch is by route id and does not retire, an unknown route "
      + "announces its drop, and route 0 is silent")
