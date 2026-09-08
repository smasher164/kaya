// THE iOS LANE'S HANDS AND EYES, RESIDENT: one XCUITest per simulator
// that never finishes on its own (docs/xcuidrive-plan.md). It runs as a
// TEST because that is the only process Apple lets drive another app,
// and stays RESIDENT because every xcodebuild start costs ~10s.
//
// THE PROTOCOL: the host writes `<dir>/request` (atomically,
// part-then-rename) holding one verb, this answers in `<dir>/response`
// whose FIRST LINE is ok/err, written the same way. `<dir>/ready`
// appears when the loop starts.
//
//   attach <bundle-id>          attach to a running app (brings it forward)
//   frame | describe            the app's frame; its whole element tree, one snapshot
//   find | value <label|id>     x,y,w,h hittable=… of the first such element; its value
//   tap X Y | press X Y MS      one touch at app-frame points
//   drag X1 Y1 X2 Y2 [HOLD_MS]  press, then a real pan to the end point
//   swipe <label> up|down|…     XCUIElement's own swipe on that element
//   type <text>                 real key events into the focused field
//   THE DOCUMENT PICKER, simdrive's contract verbatim (the interpreter
//   parses these shapes — swift/KayaSwiftUI.swift, KayaSimdrive):
//   state                       <directory> then one row name per line; nothing when no picker
//   choose <name>               tap the row whose stem matches, confirm if asked, require the picker gone
//   enter <name>                tap the FOLDER row whose stem matches, require the breadcrumb to read it; answers like state
//   cancel                      the picker's Cancel (or back until one exists), require it gone
//   savestate                   <directory> then the name field's text; nothing when no save sheet
//   savename <name>             type the name into the field and READ IT BACK
//   savepress | savecancel      the sheet's own Save / Cancel, require it gone
//   navstrip                    what the picker's bar offers (diagnosis)
//   THE ALERT AND THE PASTEBOARD (clipctl's and simdrive's `press`):
//   press <label…>              tap a button so labelled on SpringBoard or in the app
//   sb_find | sb_tap <label> | sb_describe   SpringBoard's tree
//   pb_write <kind> <b64>       one item replacing the board, kaya's stage marker beside it
//   pb_read <kind>              `S types=[…]` then `S b64=…`, the prompt answered by these hands
//   pb_types                    `S types=[…]`, prompt-free
//   THE NOTIFICATION SHADE (docs/tasks-s3-plan.md N5):
//   shade                       pull Notification Center down and say what it holds, cell by cell (diagnosis)
//   sb_drag X1 Y1 X2 Y2 [MS]    a drag in SPRINGBOARD's coordinates (the shade is its window)
//   quit                        the test returns and xcodebuild exits
//
// Coordinates are the app frame's points (its origin is the screen's).
// Built and started by tools/ios/run-sim.py, stopped in its cleanup.
//
// TWO FILES BESIDE THE PROTOCOL'S, both read by the host when this dies:
// `drive.log` holds one line per thing waited for and how long it took,
// `issues.log` the XCTest issue that ended the resident loop. Every wait
// is bounded by KAYA_DRIVE_WAIT_SECONDS, never by a fixed poll count
// (docs/deferred.md, the save-dialog driver WATCH).
import UIKit
import XCTest

final class KayaDrive: XCTestCase {
    // One snapshot per property read: keep helpers cheap and bounded.
    let pickerBar = "FullDocumentManagerViewControllerNavigationBar"
    let fileView = "File View"
    let nameFieldId = "DOCPicker.filenameTextField"
    var app: XCUIApplication?
    var driveDir = ""
    /// How long a wait for the app's own signal may run. The host sets it
    /// (run-sim.py's XCUIDRIVE_WAIT_SECONDS) under the GUEST's own simdrive
    /// deadline, so this answers with a sentence while someone is still
    /// reading. The fallback is only for a driver started by hand.
    var budget: TimeInterval = 45

    override func setUp() {
        super.setUp()
        // A recorded issue must not end the resident loop, and the loop is
        // the whole lane's hands (docs/deferred.md, the save-dialog driver
        // WATCH).
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        driveDir = env["KAYA_DRIVE_DIR"] ?? ""
        if let raw = env["KAYA_DRIVE_WAIT_SECONDS"], let seconds = TimeInterval(raw), seconds > 0 {
            budget = seconds
        }
    }

    /// THE ONE THING THAT CAN END THIS TEST leaves its reason where the host
    /// can read it. Without this the resident driver dies, xcodebuild answers
    /// 65, and the exit code is every word anyone gets — which sent two
    /// sightings of the save-dialog WATCH after the sheet instead.
    override func record(_ issue: XCTIssue) {
        append("issues.log", "\(stamp()) \(issue.compactDescription)\n")
        note("XCTest issue: \(issue.compactDescription)")
        super.record(issue)
    }

    func stamp() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }
    func append(_ name: String, _ text: String) {
        guard !driveDir.isEmpty else { return }
        let path = (driveDir as NSString).appendingPathComponent(name)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        }
    }
    /// One line per thing this driver waited for, and how long it took. The
    /// host tails it into a failed leg's log and into the sentence a dead
    /// driver answers with.
    func note(_ what: String) { append("drive.log", "\(stamp()) \(what)\n") }

    func rect(_ r: CGRect) -> String {
        "\(Int(r.origin.x.rounded())),\(Int(r.origin.y.rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded()))"
    }
    func pause(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    func tapCentre(_ a: XCUIApplication, _ r: CGRect) {
        a.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: r.midX, dy: r.midY)).tap()
    }
    /// A tap that cannot END THIS TEST: XCUIElement.tap() on an element that
    /// exists but is not hittable raises, and a raise out of the resident
    /// loop is the lane losing its hands. The frame is the app's own
    /// coordinate space, which `choose` has always tapped confirm buttons in.
    @discardableResult
    func tapSafely(_ a: XCUIApplication, _ el: XCUIElement, _ what: String) -> Bool {
        guard el.exists else {
            note("nothing to tap for \(what)")
            return false
        }
        if el.isHittable {
            el.tap()
        } else {
            tapCentre(a, el.frame)
        }
        return true
    }
    func byName(_ a: XCUIApplication, _ name: String) -> XCUIElement {
        a.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR identifier == %@ OR title == %@", name, name, name))
            .firstMatch
    }

    /// THE LANE'S OWN CEILING, not this driver's: the host writes the
    /// running leg's deadline into `<dir>/deadline` (its `timeout 120` less
    /// the room the harness needs to publish a verdict), and every wait is
    /// clamped to what is left of it. So a sheet that never comes cannot
    /// spend a leg's whole life one verb at a time, and a leg still ends
    /// with a sentence instead of being killed with its log.
    func budgetNow(_ seconds: TimeInterval? = nil) -> TimeInterval {
        var limit = seconds ?? budget
        let path = (driveDir as NSString).appendingPathComponent("deadline")
        if let text = try? String(contentsOfFile: path, encoding: .utf8),
            let at = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            limit = min(limit, max(1, at - Date().timeIntervalSince1970))
        }
        return limit
    }

    /// WAIT FOR THE APP'S OWN SIGNAL, bounded by the budget above rather
    /// than a fixed number of polls, and say what was waited for and how
    /// long. A fixed schedule is the shape both dialog WATCHes wear: six
    /// seconds of polls is a whole answer on a quiet host and a coin toss
    /// under a matrix.
    @discardableResult
    func waitFor(_ what: String, _ seconds: TimeInterval? = nil, _ ready: () -> Bool) -> Bool {
        let limit = budgetNow(seconds)
        let started = Date()
        var arrived = ready()
        while !arrived, Date().timeIntervalSince(started) < limit {
            pause(0.15)
            arrived = ready()
        }
        note(String(format: "%@ %@ after %.2fs of %.0fs",
                    arrived ? "got" : "GAVE UP on", what,
                    Date().timeIntervalSince(started), limit))
        return arrived
    }

    // MARK: - the picker
    func bar(_ a: XCUIApplication) -> XCUIElement { a.navigationBars[pickerBar] }
    /// Any of the picker's three surfaces. A presented MENU takes the
    /// whole picker out of the snapshot (measured 2026-09-02: the More
    /// menu hid the bar and the file view alike), so "gone" is never
    /// one read — see waitForPickerGone.
    func pickerUp(_ a: XCUIApplication) -> Bool {
        bar(a).exists || a.collectionViews[fileView].exists || nameField(a).exists
    }
    func waitForPicker(_ a: XCUIApplication) -> Bool {
        waitFor("the picker") { pickerUp(a) }
    }
    /// Gone means THREE consecutive absent reads, 0.3s apart: one read
    /// answers "absent" for a picker under a menu, and a tap that opened
    /// one instead of dismissing the sheet then reads as success.
    func waitForPickerGone(_ a: XCUIApplication, _ seconds: TimeInterval? = nil) -> Bool {
        var absent = 0
        let started = Date()
        let limit = budgetNow(seconds)
        repeat {
            absent = pickerUp(a) ? 0 : absent + 1
            if absent >= 3 {
                note(String(format: "got the picker gone after %.2fs of %.0fs",
                            Date().timeIntervalSince(started), limit))
                return true
            }
            pause(0.3)
        } while Date().timeIntervalSince(started) < limit
        note(String(format: "GAVE UP on the picker being gone after %.2fs of %.0fs",
                    Date().timeIntervalSince(started), limit))
        return false
    }
    /// ONE SNAPSHOT OF A SUBTREE, never attribute reads on elements bound by
    /// index: `snapshot()` throws when the element is gone, where `.label` on
    /// a stale bound element records an UNRECOVERABLE XCTest issue that ends
    /// the resident loop whatever continueAfterFailure says (measured
    /// 2026-09-07: `enter`'s wait read the bar mid-push and the driver died
    /// with "No matches found for Element at index 3").
    func descendants(_ el: XCUIElement, _ type: XCUIElement.ElementType) -> [XCUIElementSnapshot] {
        guard let root = try? el.snapshot() else { return [] }
        var out: [XCUIElementSnapshot] = []
        func walk(_ s: XCUIElementSnapshot) {
            if s.elementType == type { out.append(s) }
            s.children.forEach(walk)
        }
        walk(root)
        return out
    }
    func strip(_ a: XCUIApplication) -> [(String, CGRect)] {
        descendants(bar(a), .button).map { ($0.label, $0.frame) }
    }
    /// simdrive's currentDirectory: the bar's `<dir>, Actions Menu` button.
    func currentDirectory(_ a: XCUIApplication) -> String {
        for (label, _) in strip(a) {
            let parts = label.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2, parts[1].hasPrefix("Actions Menu") { return parts[0] }
        }
        return ""
    }
    /// The rows, by name. A cell's identifier splits the extension with a
    /// comma (`picked, txt`, measured 2026-09-02), and a name with no
    /// extension stands alone (`draft`); the stem is its static text.
    func rowName(_ identifier: String) -> String {
        let parts = identifier.components(separatedBy: ", ")
        if parts.count == 2, !parts[1].contains(" "), parts[1].count <= 12 { return parts[0] + "." + parts[1] }
        return identifier
    }
    func rows(_ a: XCUIApplication) -> [(String, CGRect)] {
        descendants(a.collectionViews[fileView], .cell).map { (rowName($0.identifier), $0.frame) }
    }
    /// simdrive's waitForRows: the chrome comes before the rows, so a
    /// read that lands between them reports the directory and no rows.
    func waitForRows(_ a: XCUIApplication) -> [(String, CGRect)]? {
        var last: [(String, CGRect)]? = nil
        waitFor("the picker's rows") {
            guard pickerUp(a) else { return false }
            let r = rows(a)
            last = r
            return !r.isEmpty
        }
        return last
    }
    func stem(_ name: String) -> String { (name as NSString).deletingPathExtension }
    func nameField(_ a: XCUIApplication) -> XCUIElement { a.textFields[nameFieldId] }
    func waitForSaveSheet(_ a: XCUIApplication, _ seconds: TimeInterval? = nil) -> Bool {
        waitFor("the save sheet", seconds) { pickerUp(a) && nameField(a).exists }
    }
    /// A whole verb's budget, shared out among its rounds: an inner wait
    /// given the FULL budget on every round of a retry can outlive the
    /// request the host is waiting on.
    func left(_ deadline: Date) -> TimeInterval { max(0.5, deadline.timeIntervalSinceNow) }
    /// One round of a retry loop's share of it: savepress presses again
    /// after this long with the sheet still up (tools/check-steps.py holds
    /// the loop to it).
    let savePressWindow: TimeInterval = 6

    /// TYPING IS THE ONE VERB THAT CAN KILL THIS DRIVER: `typeText` raises
    /// "Neither element nor any descendant has keyboard focus" when the tap
    /// that should have focused the field has not landed yet, the raise ends
    /// the resident test, and xcodebuild answers 65 for the whole lane. So
    /// the keyboard is WAITED FOR — the app's own signal that a keystroke
    /// has somewhere to go — and a refusal is a sentence naming both
    /// readings rather than a dead driver. Nil means go ahead.
    /// THE KEYBOARD IS THE HALF THAT ANSWERS for the save sheet: measured
    /// 2026-09-06 on iOS 26.5, the picker's own field reads
    /// `hasFocus=false keyboards=1` while typing into it works, since
    /// DOCPicker is a remote view controller. Both are read, either
    /// admits, and the sentence prints the pair so a future reading that
    /// changes is visible rather than assumed.
    func typingRefusal(_ a: XCUIApplication, _ what: String, _ seconds: TimeInterval? = nil,
                       focused: (() -> Bool)? = nil) -> String? {
        let ready = waitFor("a keyboard for \(what)", seconds, {
            (focused?() ?? false) || a.keyboards.count > 0
        })
        // WHICH OF THE TWO SIGNALS ARRIVED, always: the wait is satisfied by
        // either, and a line that cannot tell them apart is a line the next
        // reader will believe for the wrong one (CLAUDE.md invariant 3).
        let reading = "focused=" + (focused == nil ? "<not asked>" : "\(focused!())")
            + " keyboards=\(a.keyboards.count)"
        note("typing into \(what): \(ready ? "safe" : "REFUSED"), \(reading)")
        if ready { return nil }
        return "nothing in \(what) can take a keystroke (\(reading)), so nothing "
            + "was typed — typing here would end this driver and the lane "
            + "would lose its hands"
    }
    func cancelSheet(_ a: XCUIApplication, _ what: String) -> (Bool, String) {
        // A hittable Cancel BUTTON when the picker offers one; otherwise
        // WALK BACK, since there is no Cancel while the browser is aimed
        // into a subdirectory and one appears at the root (measured
        // 2026-09-02). The `Other` labelled Cancel under More is never
        // tapped: it opens a MENU.
        let deadline = Date().addingTimeInterval(budgetNow())
        var rounds = 0
        var offers: [String] = []
        var how = ""
        for _ in 0..<6 where Date() < deadline {
            rounds += 1
            let cancel = a.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Cancel'")).firstMatch
            if cancel.exists {
                tapSafely(a, cancel, "the \(what)'s Cancel")
                how = "its Cancel button in round \(rounds)"
                break
            }
            let bar = strip(a)
            offers = bar.map { $0.0 }
            guard let back = bar.filter({ $0.1.minY < 120 }).min(by: { $0.1.minX < $1.1.minX }) else { break }
            tapCentre(a, back.1)
            pause(0.6)
        }
        if how.isEmpty {
            let list = a.collectionViews[fileView]
            let from = list.exists
                ? a.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: list.frame.midX, dy: list.frame.midY))
                : a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let to = a.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
            from.press(forDuration: 0.1, thenDragTo: to)
            how = "a pull-down from its list after \(rounds) round(s) of walking back (the bar offered \(offers))"
        }
        if !waitForPickerGone(a, left(deadline)) {
            return (false, "the \(what) was still up after \(how); its bar offers \(strip(a).map { $0.0 })")
        }
        return (true, "cancelled by \(how)")
    }

    // MARK: - the notification shade (docs/tasks-s3-plan.md N5)
    /// SPRINGBOARD'S NOTIFICATION CELL, by identifier. MEASURED 2026-09-07 on
    /// iOS 26: the cell in the shade is a Button with this identifier and an
    /// EMPTY label, and its whole subtree is unlabelled — so a match on the
    /// notification's title alone finds nothing.
    let notifyCellId = "ListCell"
    /// The notification's own view, which a BANNER publishes with no ListCell
    /// around it (measured 2026-09-07): the shade and the banner are one match.
    let notifyLookId = "NotificationShortLookView"
    /// What SpringBoard is showing that could be a notification: every cell
    /// with its frame and label, and each cell's own subtree, for a refusal's
    /// sentence and for the `shade` verb.
    func shadeSummary(_ sb: XCUIApplication) -> String {
        guard let root = try? sb.snapshot() else { return "SpringBoard published no snapshot" }
        var cells: [String] = []
        var texts: [String] = []
        func inside(_ s: XCUIElementSnapshot, _ depth: Int) -> [String] {
            var out = ["  " + String(repeating: " ", count: depth)
                + "type=\(s.elementType.rawValue) id=\"\(s.identifier)\" label=\"\(s.label)\" \(rect(s.frame))"]
            for child in s.children { out += inside(child, depth + 1) }
            return out
        }
        func walk(_ s: XCUIElementSnapshot) {
            if s.identifier == notifyCellId || s.identifier == notifyLookId {
                cells.append("cell \(rect(s.frame)) label=\"\(s.label)\"\n"
                    + inside(s, 0).prefix(24).joined(separator: "\n"))
            }
            if s.elementType == .staticText, !s.label.isEmpty { texts.append(s.label) }
            s.children.forEach(walk)
        }
        walk(root)
        return "SpringBoard shows \(cells.count) notification cell(s) and texts "
            + "\(Array(texts.prefix(12)))" + (cells.isEmpty ? "" : "\n" + cells.joined(separator: "\n"))
    }

    /// THE PULL: a press-drag from the top edge down. The x is the screen's
    /// LEFT quarter because the right of a notched device's top edge opens
    /// Control Center instead.
    func pullShade(_ sb: XCUIApplication) {
        let w = sb.frame.width, h = sb.frame.height
        sb.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: w * 0.25, dy: 0))
            .press(forDuration: 0.2,
                   thenDragTo: sb.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: w * 0.25, dy: h * 0.75)))
    }

    /// THE COVER SHEET'S SECOND PAGE, where the notifications are. MEASURED
    /// 2026-09-07 on iOS 26: the pull lands on the CLOCK page and SpringBoard's
    /// tree then carries no notification cell at all — the pull alone finds
    /// nothing, however long it waits — so the list is swiped up into view. The
    /// swipe starts well above the home indicator, which would take the whole
    /// sheet down instead.
    func revealShadeList(_ sb: XCUIApplication) {
        let w = sb.frame.width, h = sb.frame.height
        sb.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: w * 0.5, dy: h * 0.86))
            .press(forDuration: 0.2,
                   thenDragTo: sb.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: w * 0.5, dy: h * 0.31)))
    }

    // MARK: - the pasteboard
    func pbTypes() -> String { "S types=[" + UIPasteboard.general.types.map { "\"\($0)\"" }.joined(separator: ", ") + "]" }
    /// A content read of another principal's clip raises the paste alert
    /// FOR THIS PROCESS and blocks the reading thread; the reply rides
    /// the main runloop. So: a queue, the runloop pumped, the alert
    /// pressed on SpringBoard from here (docs/traps.md).
    func pbRead(_ kind: String) -> (Bool, String) {
        let pb = UIPasteboard.general
        final class Box { var data: Data? = nil; var done = false }
        let box = Box()
        DispatchQueue.global().async {
            var d: Data? = nil
            switch kind {
            case "text": d = pb.string.map { Data($0.utf8) }
            case "html": d = pb.data(forPasteboardType: "public.html")
            case "image": d = pb.data(forPasteboardType: "public.png")
            case "files":
                var urls = (pb.urls ?? []).map(\.absoluteString)
                if urls.isEmpty {
                    urls = pb.items.compactMap { item -> String? in
                        guard let v = item["public.file-url"] else { return nil }
                        if let data = v as? Data { return String(data: data, encoding: .utf8) }
                        if let url = v as? URL { return url.absoluteString }
                        if let s = v as? String { return s }
                        return nil
                    }
                }
                d = urls.isEmpty ? nil : Data(urls.joined(separator: "\n").utf8)
            default: d = pb.data(forPasteboardType: kind)
            }
            DispatchQueue.main.async { box.data = d; box.done = true }
        }
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var presses = 0
        let deadline = Date().addingTimeInterval(25)
        while !box.done && Date() < deadline {
            pause(0.2)
            let allow = sb.buttons["Allow Paste"]
            if allow.exists {
                allow.tap()
                presses += 1
            }
        }
        if !box.done {
            return (false, "the \(kind) read never returned after \(presses) presses — the paste prompt went unanswered; the board offered \(pbTypes())")
        }
        return (true, pbTypes() + "\nS b64=" + (box.data?.base64EncodedString() ?? ""))
    }
    func pbWrite(_ kind: String, _ b64: String) -> (Bool, String) {
        guard let bytes = Data(base64Encoded: b64) else { return (false, "pb_write needs base64") }
        var item: [String: Any]
        switch kind {
        case "text": item = ["public.utf8-plain-text": String(decoding: bytes, as: UTF8.self)]
        case "html": item = ["public.html": String(decoding: bytes, as: UTF8.self)]
        case "image": item = ["public.png": bytes]
        case "files": item = ["public.file-url": URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))]
        default: return (false, "cannot write \(kind) from outside the app")
        }
        // kaya's stage marker beside it: the app's witness asks whether the
        // board is still the clip the leg staged (swift/KayaSwiftUI.swift's
        // kayaClipMarkerType; the two spellings are held by the app at run time).
        item["dev.kaya/staged"] = "staged"
        UIPasteboard.general.items = [item]
        return (true, "W " + pbTypes().dropFirst(2))
    }

    // MARK: - the loop
    func testResident() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["KAYA_DRIVE_DIR"], !dir.isEmpty else {
            XCTFail("KAYA_DRIVE_DIR is unset: nothing to serve")
            return
        }
        let fm = FileManager.default
        let requestPath = dir + "/request", responsePath = dir + "/response", partPath = dir + "/response.part"
        func answer(_ ok: Bool, _ body: String) {
            try? fm.removeItem(atPath: partPath)
            fm.createFile(atPath: partPath, contents: Data(((ok ? "ok\n" : "err\n") + body + (body.isEmpty ? "" : "\n")).utf8))
            try? fm.removeItem(atPath: responsePath)
            try? fm.moveItem(atPath: partPath, toPath: responsePath)
        }
        func coordinate(_ a: XCUIApplication, _ words: [String], _ i: Int) -> XCUICoordinate? {
            guard words.count > i + 1, let x = Double(words[i]), let y = Double(words[i + 1]) else { return nil }
            return a.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        }
        fm.createFile(atPath: dir + "/ready", contents: Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
        note("serving pid \(ProcessInfo.processInfo.processIdentifier), waits bounded at \(Int(budget))s")
        let deadline = Date().addingTimeInterval(6 * 3600)
        while Date() < deadline {
            guard let data = fm.contents(atPath: requestPath), let text = String(data: data, encoding: .utf8) else {
                pause(0.02)
                continue
            }
            try? fm.removeItem(atPath: requestPath)
            let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            guard let verb = words.first else { answer(false, "empty request"); continue }
            let rest = words.dropFirst().joined(separator: " ")
            note("verb `\(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))`")
            let started = Date()
            let (ok, body) = handle(verb, words, rest, coordinate)
            let why = ok ? "" : ": " + String((body.split(separator: "\n").first ?? "").prefix(160))
            note(String(format: "verb `%@` -> %@ in %.2fs%@", verb, ok ? "ok" : "err",
                        Date().timeIntervalSince(started), why))
            answer(ok, body)
            if verb == "quit" { return }
        }
        answer(false, "the resident deadline passed")
    }

    func handle(_ verb: String, _ words: [String], _ rest: String,
                _ coordinate: (XCUIApplication, [String], Int) -> XCUICoordinate?) -> (Bool, String) {
        switch verb {
        case "quit": return (true, "bye")
        case "attach":
            guard words.count == 2 else { return (false, "attach <bundle-id>") }
            let a = XCUIApplication(bundleIdentifier: words[1])
            a.activate()
            let started = Date()
            let wait = budgetNow()
            let ok = a.wait(for: .runningForeground, timeout: wait)
            note(String(format: "%@ %@ in the foreground after %.2fs of %.0fs",
                        ok ? "got" : "GAVE UP on", words[1],
                        Date().timeIntervalSince(started), wait))
            app = ok ? a : nil
            return (ok, "state=\(a.state.rawValue) frame=\(rect(a.frame))")
        case "sb_describe":
            return (true, XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)
        case "shade":
            // Pull Notification Center down, bring its list up, and say what it
            // holds. DIAGNOSIS ONLY: a notification found this way cannot be
            // activated on the simulator (docs/tasks-s3-plan.md N5's iOS
            // carve-out; the measurement is in tools/ios/notifyprobe).
            let sbs = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            pullShade(sbs)
            revealShadeList(sbs)
            pause(0.5)
            return (true, shadeSummary(sbs))
        case "sb_drag":
            // SpringBoard's own coordinate space, which the app-frame `drag`
            // cannot reach: the shade belongs to SpringBoard.
            let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            guard words.count > 4, let x1 = Double(words[1]), let y1 = Double(words[2]),
                  let x2 = Double(words[3]), let y2 = Double(words[4])
            else { return (false, "sb_drag X1 Y1 X2 Y2 [HOLD_MS]") }
            let hold = words.count > 5 ? (Double(words[5]) ?? 200) / 1000 : 0.2
            sb.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x1, dy: y1))
                .press(forDuration: hold,
                       thenDragTo: sb.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: x2, dy: y2)))
            return (true, "dragged \(x1),\(y1) -> \(x2),\(y2)")
        case "sb_find", "sb_tap", "press":
            // SpringBoard's tree is the one that is ALWAYS readable while
            // the foreground app's own blocked read holds the alert
            // (docs/clipboard-plan.md §8 finding 2); the app's is second.
            let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            var hit = sb.buttons[rest]
            if !hit.exists, verb == "press", let a = app { hit = byName(a, rest) }
            guard hit.exists else { return (false, "nothing carries the label \(rest)") }
            if verb == "sb_find" { return (true, "\(rect(hit.frame)) hittable=\(hit.isHittable)") }
            let host = (verb == "press" && !sb.buttons[rest].exists) ? (app ?? sb) : sb
            guard tapSafely(host, hit, "the button labelled \(rest)") else {
                return (false, "\(rest) went away between the read and the tap")
            }
            return (true, "pressed \(rest)")
        case "pb_types": return (true, pbTypes())
        case "pb_read":
            guard words.count == 2 else { return (false, "pb_read <kind>") }
            return pbRead(words[1])
        case "pb_write":
            guard words.count == 3 else { return (false, "pb_write <kind> <b64>") }
            return pbWrite(words[1], words[2])
        default: break
        }
        guard let a = app else { return (false, "no app attached (attach <bundle-id> first)") }
        switch verb {
        case "frame": return (true, rect(a.frame))
        case "describe": return (true, a.debugDescription)
        case "navstrip": return (true, strip(a).map { "\($0.0)\t\(rect($0.1))" }.joined(separator: "\n"))
        case "find":
            let hit = byName(a, rest)
            return hit.exists ? (true, "\(rect(hit.frame)) hittable=\(hit.isHittable) type=\(hit.elementType.rawValue)")
                              : (false, "no element labelled \(rest)")
        case "value":
            let hit = byName(a, rest)
            return hit.exists ? (true, hit.value.map { "\($0)" } ?? "") : (false, "no element labelled \(rest)")
        case "type":
            if let why = typingRefusal(a, "the app") { return (false, why) }
            a.typeText(rest)
            return (true, "typed \(rest.count) character(s)")
        case "type_b64":
            // The harness's `type` verb on iOS: the text base64-framed, since
            // the request line is word-split on the host.
            guard words.count == 2, let data = Data(base64Encoded: words[1]),
                  let text = String(data: data, encoding: .utf8) else { return (false, "type_b64 <base64>") }
            if let why = typingRefusal(a, "the app") { return (false, why) }
            a.typeText(text)
            return (true, "typed \(text.count) character(s)")
        case "tap":
            guard let p = coordinate(a, words, 1) else { return (false, "tap X Y") }
            p.tap()
            return (true, "tapped")
        case "press_at":
            guard let p = coordinate(a, words, 1), words.count > 3, let ms = Double(words[3]) else { return (false, "press_at X Y MS") }
            p.press(forDuration: ms / 1000)
            return (true, "pressed")
        case "drag", "swipe_points":
            guard let p1 = coordinate(a, words, 1), let p2 = coordinate(a, words, 3) else { return (false, "drag X1 Y1 X2 Y2 [HOLD_MS]") }
            let hold = words.count > 5 ? (Double(words[5]) ?? 100) / 1000 : 0.1
            p1.press(forDuration: hold, thenDragTo: p2)
            return (true, "dragged")
        case "flick":
            // press-drag with XCUITest's fast velocity: a scroll flick
            guard let p1 = coordinate(a, words, 1), let p2 = coordinate(a, words, 3) else { return (false, "flick X1 Y1 X2 Y2") }
            p1.press(forDuration: 0.02, thenDragTo: p2, withVelocity: .fast, thenHoldForDuration: 0.05)
            return (true, "flicked")
        case "swipe_win":
            // XCUIElement's own swipe on the main window
            guard words.count == 2 else { return (false, "swipe_win up|down|left|right") }
            let w = a.windows.firstMatch
            switch words[1] {
            case "up": w.swipeUp()
            case "down": w.swipeDown()
            case "left": w.swipeLeft()
            case "right": w.swipeRight()
            default: return (false, "direction up|down|left|right")
            }
            return (true, "swiped window \(words[1])")
        case "swipe":
            guard words.count > 2 else { return (false, "swipe <label> up|down|left|right") }
            let dir = words[words.count - 1]
            let el = byName(a, words[1..<(words.count - 1)].joined(separator: " "))
            guard el.exists else { return (false, "no element to swipe") }
            guard el.isHittable else {
                return (false, "the element to swipe is not hittable, and swiping it would end this driver")
            }
            switch dir {
            case "up": el.swipeUp()
            case "down": el.swipeDown()
            case "left": el.swipeLeft()
            case "right": el.swipeRight()
            default: return (false, "direction up|down|left|right")
            }
            return (true, "swiped \(dir)")

        // ---- the picker, simdrive's contract
        case "state":
            guard let r = waitForRows(a) else { return (true, "") }
            return (true, ([currentDirectory(a)] + r.map { $0.0 }).joined(separator: "\n"))
        case "choose":
            guard !rest.isEmpty else { return (false, "choose needs a name") }
            let wanted = stem(rest)
            guard let r = waitForRows(a) else { return (false, "no picker is up to choose \(wanted) from") }
            guard r.contains(where: { stem($0.0) == wanted }) else {
                return (false, "no row named \(wanted); the picker lists \(r.map { $0.0 })")
            }
            // The picker being gone is the proof a tap landed; a tap that
            // arrives before the list is interactive is swallowed with no
            // error, so the whole select-confirm round retries and the rows
            // are re-walked each round (simdrive's rule, kept as a guard).
            let deadline = Date().addingTimeInterval(budgetNow())
            var rounds = 0, offered = 0
            var gone = false
            while rounds < 6 && !gone && Date() < deadline {
                rounds += 1
                if let row = rows(a).first(where: { stem($0.0) == wanted }) {
                    offered += 1
                    tapCentre(a, row.1)
                }
                if !waitForPickerGone(a, min(2, left(deadline))) {
                    if let (_, confirm) = strip(a).first(where: { $0.0.hasPrefix("Open") || $0.0.hasPrefix("Done") }) {
                        tapCentre(a, confirm)
                    }
                }
                gone = waitForPickerGone(a, left(deadline) / 2)
            }
            if !gone {
                return (false, "the picker was still up after \(rounds) rounds of choosing \(wanted): the row was offered in \(offered) of them; it now lists \(rows(a).map { $0.0 }) and offers \(strip(a).map { $0.0 })")
            }
            return (true, "chose \(wanted) in \(rounds) round(s)")
        case "enter":
            // The reveal race's remedy (docs/traps.md, "The first picker a
            // device shows after a boot ignores where you aimed it"): the
            // picker opened at the PARENT with the aimed folder as a row.
            // The proof a tap landed is the breadcrumb reading the folder.
            guard !rest.isEmpty else { return (false, "enter needs a folder name") }
            let wanted = stem(rest)
            guard let r = waitForRows(a) else { return (false, "no picker is up to enter \(wanted) from") }
            guard r.contains(where: { stem($0.0) == wanted }) else {
                return (false, "no folder row named \(wanted); the picker lists \(r.map { $0.0 })")
            }
            let before = currentDirectory(a)
            let deadline = Date().addingTimeInterval(budgetNow())
            var rounds = 0
            var inside = false
            while rounds < 6 && !inside && Date() < deadline {
                rounds += 1
                if let row = rows(a).first(where: { stem($0.0) == wanted }) {
                    tapCentre(a, row.1)
                }
                inside = waitFor("the picker inside \(wanted)", min(3, left(deadline))) {
                    pickerUp(a) && currentDirectory(a) == wanted
                }
            }
            guard inside else {
                return (false, "the picker stayed at \(currentDirectory(a)) after \(rounds) round(s) of entering \(wanted) from \(before)")
            }
            guard let now = waitForRows(a) else { return (true, wanted) }
            return (true, ([currentDirectory(a)] + now.map { $0.0 }).joined(separator: "\n"))
        case "cancel":
            guard waitForPicker(a) else { return (false, "no picker is up to cancel") }
            return cancelSheet(a, "picker")
        case "savestate":
            guard waitForSaveSheet(a) else { return (true, "") }
            return (true, currentDirectory(a) + "\n" + (nameField(a).value.map { "\($0)" } ?? ""))
        case "savename":
            guard !rest.isEmpty else { return (false, "savename needs a name") }
            let deadline = Date().addingTimeInterval(budgetNow())
            var settled = ""
            var attempts = 0
            while attempts < 5 && settled != rest && Date() < deadline {
                attempts += 1
                guard waitForSaveSheet(a, left(deadline)) else {
                    return (false, "no save dialog is up to name \(rest)")
                }
                let field = nameField(a)
                // The first tap on the sheet's field selects its whole
                // suggested name (measured: typing replaced it); a later
                // tap places a caret, so the caret is put at the end and
                // the text deleted before typing again.
                tapSafely(a, field, "the save sheet's name field")
                // THE FIELD'S OWN SIGNAL, not a fixed 0.3s: under a matrix
                // the tap takes longer to focus than the sleep it was given,
                // and typing unfocused ends this driver.
                if let why = typingRefusal(a, "the save sheet's name field", left(deadline),
                                           focused: { [self] in nameField(a).hasFocus }) {
                    return (false, why)
                }
                if attempts > 1 {
                    field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
                    pause(0.2)
                    let count = (field.value as? String)?.count ?? 0
                    if count > 0 { a.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count)) }
                }
                a.typeText(rest)
                waitFor("the name field to read back \"\(rest)\"", left(deadline)) {
                    settled = (nameField(a).value as? String) ?? ""
                    return settled == rest
                }
            }
            guard settled == rest else {
                return (false, "the save dialog's name field reads \"\(settled)\" after \(attempts) attempts to set it to \"\(rest)\"")
            }
            return (true, "named in \(attempts) attempt(s)")
        case "savepress":
            let deadline = Date().addingTimeInterval(budgetNow())
            guard waitForSaveSheet(a, left(deadline)) else {
                return (false, "no save dialog is up to save")
            }
            var presses = 0, offered = 0
            var gone = false
            var readings: [String] = []
            while presses < 6 && !gone && Date() < deadline {
                presses += 1
                let save = bar(a).buttons["Save"]
                let keyboardsBefore = a.keyboards.count
                let offeredNow = save.exists
                if offeredNow {
                    offered += 1
                    tapSafely(a, save, "the save sheet's Save")
                } else if presses == 1 {
                    return (false, "no Save in the navigation strip; it offers \(strip(a).map { $0.0 })")
                }
                // ONE PRESS GETS ONE WINDOW, never the verb's whole budget:
                // matrix #18 (2026-09-06) spent all 44s on a single press
                // the sheet did not take, and the five presses that would
                // have followed never came (docs/deferred.md, the
                // save-press WATCH). The window covers a dismissal measured
                // at 0.7-1.4s under a matrix several times over.
                gone = waitForPickerGone(a, min(savePressWindow, left(deadline)))
                let field = nameField(a)
                let reading = "press \(presses): Save \(offeredNow ? "offered" : "absent")"
                    + " keyboards \(keyboardsBefore)->\(a.keyboards.count)"
                    + " sheet \(gone ? "gone" : "still up")"
                    + (gone ? "" : " field \(field.exists ? "\"\((field.value as? String) ?? "")\"" : "absent")")
                note(reading)
                readings.append(reading)
            }
            if !gone {
                return (false, "the save dialog was still up after \(presses) presses of Save: Save was in the strip for \(offered) of them; it now offers \(strip(a).map { $0.0 }); \(readings.joined(separator: "; "))")
            }
            return (true, "saved in \(presses) press(es)")
        case "savecancel":
            guard waitForSaveSheet(a) else { return (false, "no save dialog is up to cancel") }
            return cancelSheet(a, "save dialog")


        default:
            return (false, "unknown verb \(verb)")
        }
    }
}
