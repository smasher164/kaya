// THE iOS LANE'S HANDS AND EYES, RESIDENT: one XCUITest per simulator
// that never finishes on its own, serving every verb the lane once
// split across simdrive (a host-side walker of SimulatorKit's private
// accessibility bridge) and clipctl (a spawned pasteboard process) —
// docs/xcuidrive-plan.md records the measurements that let one public
// API replace both. It runs as a test because that is the only process
// Apple lets drive another app — XCUIApplication(bundleIdentifier:)
// attaches to whatever the lane launched — and it stays resident
// because every xcodebuild start costs ~10s.
//
// THE PROTOCOL IS simdrive's, unchanged for the guest: the host writes
// `<dir>/request` (atomically, part-then-rename) holding one verb, this
// answers in `<dir>/response` whose FIRST LINE is ok/err, written aside
// and renamed the same way. `<dir>/ready` appears when the loop starts.
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
//   quit                        the test returns and xcodebuild exits
//
// Coordinates are the app frame's points (its origin is the screen's).
// Built and started by tools/ios/run-sim.py (xcuidrive_build/_start),
// used by admission's export probe before any leg, and stopped in its
// cleanup with the process list shown empty.
import UIKit
import XCTest

final class KayaDrive: XCTestCase {
    // One snapshot per property read: keep helpers cheap and bounded.
    let pickerBar = "FullDocumentManagerViewControllerNavigationBar"
    let fileView = "File View"
    let nameFieldId = "DOCPicker.filenameTextField"
    var app: XCUIApplication?

    func rect(_ r: CGRect) -> String {
        "\(Int(r.origin.x.rounded())),\(Int(r.origin.y.rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded()))"
    }
    func pause(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
    func tapCentre(_ a: XCUIApplication, _ r: CGRect) {
        a.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: r.midX, dy: r.midY)).tap()
    }
    func byName(_ a: XCUIApplication, _ name: String) -> XCUIElement {
        a.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR identifier == %@ OR title == %@", name, name, name))
            .firstMatch
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
    func waitForPicker(_ a: XCUIApplication, _ tries: Int = 20) -> Bool {
        for _ in 0..<tries {
            if pickerUp(a) { return true }
            pause(0.3)
        }
        return false
    }
    /// Gone means THREE consecutive absent reads, 0.3s apart: one read
    /// answers "absent" for a picker under a menu, and a tap that opened
    /// one instead of dismissing the sheet then reads as success.
    func waitForPickerGone(_ a: XCUIApplication, _ tries: Int = 20) -> Bool {
        var absent = 0
        for _ in 0..<(tries + 2) {
            absent = pickerUp(a) ? 0 : absent + 1
            if absent >= 3 { return true }
            pause(0.3)
        }
        return false
    }
    func strip(_ a: XCUIApplication) -> [(String, CGRect)] {
        bar(a).buttons.allElementsBoundByIndex.map { ($0.label, $0.frame) }
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
        a.collectionViews[fileView].cells.allElementsBoundByIndex.map { (rowName($0.identifier), $0.frame) }
    }
    /// simdrive's waitForRows: the chrome comes before the rows, so a
    /// read that lands between them reports the directory and no rows.
    func waitForRows(_ a: XCUIApplication, _ tries: Int = 20) -> [(String, CGRect)]? {
        var last: [(String, CGRect)]? = nil
        for _ in 0..<tries {
            guard waitForPicker(a) else { return last }
            let r = rows(a)
            last = r
            if !r.isEmpty { return r }
            pause(0.3)
        }
        return last
    }
    func stem(_ name: String) -> String { (name as NSString).deletingPathExtension }
    func nameField(_ a: XCUIApplication) -> XCUIElement { a.textFields[nameFieldId] }
    func waitForSaveSheet(_ a: XCUIApplication, _ tries: Int = 20) -> Bool {
        for _ in 0..<tries {
            if pickerUp(a), nameField(a).exists { return true }
            pause(0.3)
        }
        return false
    }
    func cancelSheet(_ a: XCUIApplication, _ what: String) -> (Bool, String) {
        // simdrive's rule, kept: a hittable Cancel BUTTON when the picker
        // offers one; otherwise WALK BACK, since there is no Cancel while
        // the browser is aimed into a subdirectory (kaya's picker at depth
        // offers only the back button — labelled with the presenting app's
        // name — the Actions Menu and More; measured 2026-09-02), and one
        // appears at the root. The `Other` labelled Cancel under the More
        // button is never tapped: it opens a MENU. As a last resort the
        // sheet's pull-down from its list, which dismissed the export
        // probe's sheet but not kaya's.
        var rounds = 0
        var offers: [String] = []
        var how = ""
        for _ in 0..<6 {
            rounds += 1
            let cancel = a.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Cancel'")).firstMatch
            if cancel.exists && cancel.isHittable {
                cancel.tap()
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
        if !waitForPickerGone(a) {
            return (false, "the \(what) was still up after \(how); its bar offers \(strip(a).map { $0.0 })")
        }
        return (true, "cancelled by \(how)")
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
            let (ok, body) = handle(verb, words, rest, coordinate)
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
            let ok = a.wait(for: .runningForeground, timeout: 20)
            app = ok ? a : nil
            return (ok, "state=\(a.state.rawValue) frame=\(rect(a.frame))")
        case "sb_describe":
            return (true, XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)
        case "sb_find", "sb_tap", "press":
            // SpringBoard's tree is the one that is ALWAYS readable while
            // the foreground app's own blocked read holds the alert
            // (docs/clipboard-plan.md §8 finding 2); the app's is second.
            let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            var hit = sb.buttons[rest]
            if !hit.exists, verb == "press", let a = app { hit = byName(a, rest) }
            guard hit.exists else { return (false, "nothing carries the label \(rest)") }
            if verb == "sb_find" { return (true, "\(rect(hit.frame)) hittable=\(hit.isHittable)") }
            hit.tap()
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
            a.typeText(rest)
            return (true, "typed \(rest.count) character(s)")
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
        case "swipe":
            guard words.count > 2 else { return (false, "swipe <label> up|down|left|right") }
            let dir = words[words.count - 1]
            let el = byName(a, words[1..<(words.count - 1)].joined(separator: " "))
            guard el.exists else { return (false, "no element to swipe") }
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
            var rounds = 0, offered = 0
            var gone = false
            while rounds < 6 && !gone {
                rounds += 1
                if let row = rows(a).first(where: { stem($0.0) == wanted }) {
                    offered += 1
                    tapCentre(a, row.1)
                }
                if !waitForPickerGone(a, 6) {
                    if let (_, confirm) = strip(a).first(where: { $0.0.hasPrefix("Open") || $0.0.hasPrefix("Done") }) {
                        tapCentre(a, confirm)
                    }
                }
                gone = waitForPickerGone(a)
            }
            if !gone {
                return (false, "the picker was still up after \(rounds) rounds of choosing \(wanted): the row was offered in \(offered) of them; it now lists \(rows(a).map { $0.0 }) and offers \(strip(a).map { $0.0 })")
            }
            return (true, "chose \(wanted) in \(rounds) round(s)")
        case "cancel":
            guard waitForPicker(a) else { return (false, "no picker is up to cancel") }
            return cancelSheet(a, "picker")
        case "savestate":
            guard waitForSaveSheet(a) else { return (true, "") }
            return (true, currentDirectory(a) + "\n" + (nameField(a).value.map { "\($0)" } ?? ""))
        case "savename":
            guard !rest.isEmpty else { return (false, "savename needs a name") }
            var settled = ""
            var attempts = 0
            while attempts < 5 && settled != rest {
                attempts += 1
                guard waitForSaveSheet(a) else { return (false, "no save dialog is up to name \(rest)") }
                let field = nameField(a)
                // The first tap on the sheet's field selects its whole
                // suggested name (measured: typing replaced it); a later
                // tap places a caret, so the caret is put at the end and
                // the text deleted before typing again.
                field.tap()
                pause(0.3)
                if attempts > 1 {
                    field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
                    pause(0.2)
                    let count = (field.value as? String)?.count ?? 0
                    if count > 0 { a.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count)) }
                }
                a.typeText(rest)
                for _ in 0..<20 {
                    settled = (nameField(a).value as? String) ?? ""
                    if settled == rest { break }
                    pause(0.15)
                }
            }
            guard settled == rest else {
                return (false, "the save dialog's name field reads \"\(settled)\" after \(attempts) attempts to set it to \"\(rest)\"")
            }
            return (true, "named in \(attempts) attempt(s)")
        case "savepress":
            guard waitForSaveSheet(a) else { return (false, "no save dialog is up to save") }
            var presses = 0, offered = 0
            var gone = false
            while presses < 6 && !gone {
                presses += 1
                let save = bar(a).buttons["Save"]
                if save.exists {
                    offered += 1
                    save.tap()
                } else if presses == 1 {
                    return (false, "no Save in the navigation strip; it offers \(strip(a).map { $0.0 })")
                }
                gone = waitForPickerGone(a)
            }
            if !gone {
                return (false, "the save dialog was still up after \(presses) presses of Save: Save was in the strip for \(offered) of them; it now offers \(strip(a).map { $0.0 })")
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
