// THE iOS LANE'S HANDS, RESIDENT: one XCUITest per simulator that never
// finishes on its own, serving gestures over two files. XCUITest is the
// one route that reaches the simulator's content with real touches
// (docs/deferred.md's pan chore, 2026-08-30: SimulatorKit's legacy HID
// client lands taps but this runtime reads none of its move streams as
// a pan; CGEvents stop at the Simulator's mac chrome). It runs as a test
// because that is the only process Apple lets drive another app —
// XCUIApplication(bundleIdentifier:) attaches to whatever the lane
// launched — and it stays resident because every xcodebuild start costs
// ~10s, which per gesture would be the whole lane's budget.
//
// THE PROTOCOL IS simdrive's, one directory over: the host writes
// `<dir>/request` (atomically, part-then-rename) holding one verb, this
// answers in `<dir>/response` whose FIRST LINE is ok/err, written aside
// and renamed the same way. `<dir>/ready` appears when the loop starts.
//
//   attach <bundle-id>          attach to a running app (brings it forward)
//   frame                       the app's frame, x,y,w,h in points
//   describe                    the app's whole element tree, one snapshot
//   find <label or identifier>  x,y,w,h hittable=… of the first element so named
//   value <label or identifier> the element's value (a field's text)
//   tap X Y | press X Y MS      one touch at app-frame points
//   drag X1 Y1 X2 Y2 [HOLD_MS]  press, then a real pan to the end point
//   swipe <label> up|down|…     XCUIElement's own swipe on that element
//   type <text>                 real key events into the focused field
//   sb_find | sb_tap <label>    SpringBoard's tree (the paste prompt)
//   sb_describe                 SpringBoard's whole tree
//   pb_write <text> | pb_read   the device pasteboard from inside the sim
//   quit                        the test returns and xcodebuild exits
//
// The sb_* and pb_* verbs are what let this one process take over
// simdrive's and clipctl's work (docs/xcuidrive-plan.md).
//
// Coordinates are the app frame's points (its origin is the screen's).
// Built and started by tools/ios/run-sim.py (xcuidrive_build/_start),
// proven there on every lane run by a pan and a tap on the scroll
// guest before the first leg, and stopped in its cleanup with the
// process list shown empty.
import UIKit
import XCTest

final class KayaDrive: XCTestCase {
    func testResident() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["KAYA_DRIVE_DIR"], !dir.isEmpty else {
            XCTFail("KAYA_DRIVE_DIR is unset: nothing to serve")
            return
        }
        let fm = FileManager.default
        let requestPath = dir + "/request"
        let responsePath = dir + "/response"
        let partPath = dir + "/response.part"
        var app: XCUIApplication?

        func answer(_ ok: Bool, _ body: String) {
            try? fm.removeItem(atPath: partPath)
            fm.createFile(atPath: partPath, contents: Data(((ok ? "ok\n" : "err\n") + body + "\n").utf8))
            try? fm.removeItem(atPath: responsePath)
            try? fm.moveItem(atPath: partPath, toPath: responsePath)
        }
        func rect(_ r: CGRect) -> String {
            "\(Int(r.origin.x.rounded())),\(Int(r.origin.y.rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded()))"
        }
        func coordinate(_ a: XCUIApplication, _ words: [String], _ i: Int) -> XCUICoordinate? {
            guard words.count > i + 1, let x = Double(words[i]), let y = Double(words[i + 1]) else { return nil }
            return a.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        }

        fm.createFile(atPath: dir + "/ready",
                      contents: Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
        let deadline = Date().addingTimeInterval(4 * 3600)
        while Date() < deadline {
            guard let data = fm.contents(atPath: requestPath),
                  let text = String(data: data, encoding: .utf8) else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                continue
            }
            try? fm.removeItem(atPath: requestPath)
            let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            guard let verb = words.first else {
                answer(false, "empty request")
                continue
            }
            if verb == "quit" {
                answer(true, "bye")
                return
            }
            if verb == "attach" {
                guard words.count == 2 else {
                    answer(false, "attach <bundle-id>")
                    continue
                }
                let a = XCUIApplication(bundleIdentifier: words[1])
                a.activate()
                let ok = a.wait(for: .runningForeground, timeout: 20)
                app = ok ? a : nil
                answer(ok, "state=\(a.state.rawValue) frame=\(rect(a.frame))")
                continue
            }
            // SpringBoard's own tree, for what no app hosts: the paste-
            // permission alert, notifications, the home screen. Needs no
            // attach.
            if verb == "sb_find" || verb == "sb_tap" || verb == "sb_describe" {
                let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                if verb == "sb_describe" {
                    answer(true, sb.debugDescription)
                    continue
                }
                let name = words.dropFirst().joined(separator: " ")
                let hit = sb.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@ OR identifier == %@", name, name))
                    .firstMatch
                guard hit.waitForExistence(timeout: 5) else {
                    answer(false, "springboard has no element labelled \(name)")
                    continue
                }
                if verb == "sb_tap" {
                    hit.tap()
                    answer(true, "tapped \(name) on springboard")
                } else {
                    answer(true, "\(rect(hit.frame)) hittable=\(hit.isHittable)")
                }
                continue
            }
            if verb == "pb_read" {
                // The pasteboard, from INSIDE the simulator: this process is
                // a simulator process, so UIPasteboard.general is the
                // device's board. Types never prompt; CONTENT of another
                // principal's clip raises the paste-permission alert FOR THIS
                // PROCESS and blocks the reading thread (measured 2026-09-02:
                // a read on the test thread wedged the driver). So the read
                // runs on a background queue while this thread answers the
                // alert on SpringBoard — the foreign crossing clipctl exists
                // for, with the prompt answered by the same hands.
                // AND THE MAIN RUNLOOP MUST KEEP TURNING while the read is
                // out: the pasteboard's reply is delivered through it, so a
                // semaphore wait here deadlocked even an own-content read.
                let pb = UIPasteboard.general
                let types = pb.types.joined(separator: ",")
                final class Box { var got: String? = nil; var done = false }
                let box = Box()
                DispatchQueue.global().async {
                    let s = pb.string
                    DispatchQueue.main.async { box.got = s; box.done = true }
                }
                let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                var pressed = false
                let deadline = Date().addingTimeInterval(15)
                while !box.done && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    if !pressed {
                        let allow = sb.buttons["Allow Paste"]
                        if allow.exists {
                            allow.tap()
                            pressed = true
                        }
                    }
                }
                if !box.done {
                    answer(false, "the pasteboard read did not return within 15s (prompt pressed: \(pressed))")
                } else {
                    answer(true, "types=[\(types)] string=\(box.got ?? "") prompt=\(pressed ? "pressed" : "none")")
                }
                continue
            }
            if verb == "pb_write" {
                UIPasteboard.general.string = words.dropFirst().joined(separator: " ")
                answer(true, "written")
                continue
            }
            guard let a = app else {
                answer(false, "no app attached (attach <bundle-id> first)")
                continue
            }
            switch verb {
            case "frame":
                answer(true, rect(a.frame))
            case "describe":
                // The whole tree XCUITest can see through this app — the
                // remote picker's included — in ONE snapshot: debugDescription
                // is the element tree as text (type, frame, label,
                // identifier, value per line). A per-element walk asking
                // isHittable was a snapshot per element and wedged the
                // driver (measured 2026-09-02).
                answer(true, a.debugDescription)
            case "value":
                let name = words.dropFirst().joined(separator: " ")
                let hit = a.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@ OR identifier == %@ OR title == %@",
                                          name, name, name))
                    .firstMatch
                if hit.exists {
                    answer(true, hit.value.map { "\($0)" } ?? "")
                } else {
                    answer(false, "no element labelled \(name)")
                }
            case "type":
                // Real key events into whatever has keyboard focus.
                let text = words.dropFirst().joined(separator: " ")
                a.typeText(text)
                answer(true, "typed \(text.count) character(s)")
            case "find":
                let name = words.dropFirst().joined(separator: " ")
                let hit = a.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@ OR identifier == %@ OR title == %@",
                                          name, name, name))
                    .firstMatch
                if hit.exists {
                    answer(true, "\(rect(hit.frame)) hittable=\(hit.isHittable) type=\(hit.elementType.rawValue)")
                } else {
                    answer(false, "no element labelled \(name)")
                }
            case "tap":
                guard let p = coordinate(a, words, 1) else {
                    answer(false, "tap X Y")
                    continue
                }
                p.tap()
                answer(true, "tapped")
            case "press":
                guard let p = coordinate(a, words, 1), words.count > 3, let ms = Double(words[3]) else {
                    answer(false, "press X Y MS")
                    continue
                }
                p.press(forDuration: ms / 1000)
                answer(true, "pressed")
            case "swipe":
                guard words.count > 2 else {
                    answer(false, "swipe <label> up|down|left|right")
                    continue
                }
                let dir = words[words.count - 1]
                let name = words[1..<(words.count - 1)].joined(separator: " ")
                let el = a.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == %@ OR identifier == %@", name, name))
                    .firstMatch
                guard el.exists else {
                    answer(false, "no element \(name) to swipe")
                    continue
                }
                switch dir {
                case "up": el.swipeUp()
                case "down": el.swipeDown()
                case "left": el.swipeLeft()
                case "right": el.swipeRight()
                default:
                    answer(false, "direction up|down|left|right")
                    continue
                }
                answer(true, "swiped \(dir)")
            case "drag":
                guard let p1 = coordinate(a, words, 1), let p2 = coordinate(a, words, 3) else {
                    answer(false, "drag X1 Y1 X2 Y2 [HOLD_MS]")
                    continue
                }
                let hold = words.count > 5 ? (Double(words[5]) ?? 100) / 1000 : 0.1
                p1.press(forDuration: hold, thenDragTo: p2)
                answer(true, "dragged")
            default:
                answer(false, "unknown verb \(verb)")
            }
        }
        answer(false, "the resident deadline passed")
    }
}
