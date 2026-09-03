// A PROBE-LOCAL XCUITest driver, serving the same request/response file
// protocol as tools/ios/xcuidrive/KayaDrive.swift, added for ONE reason
// the lane's driver cannot serve today:
//
//   the lane's `drag` is `press(forDuration:thenDragTo:)`, and on a
//   stock app whose cells carry a long-press CONTEXT MENU (the Files
//   app), that gesture loses the race — the menu opens and no drag
//   session is ever lifted. Measured 2026-09-03 at holds of 250, 350,
//   400, 500, 700, 1200 and 1500ms: the menu every time.
//
// `xdrag` is the four-argument form UIKit documents for this —
// press(forDuration:thenDragTo:withVelocity:thenHoldForDuration:) — a
// SLOW pull away from the press point and a HOLD over the destination
// before the lift, which is what a person's drag looks like.
//
// Nothing but tools/ios/dragprobe/drive.py builds this.
import XCTest

final class DragDrive: XCTestCase {
    var app: XCUIApplication?

    func rect(_ r: CGRect) -> String {
        "\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.size.width)),\(Int(r.size.height))"
    }
    func pause(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    func byName(_ a: XCUIApplication, _ name: String) -> XCUIElement {
        for q in [a.buttons[name], a.staticTexts[name], a.cells[name],
                  a.otherElements[name], a.images[name], a.descendants(matching: .any)[name]] {
            if q.exists { return q }
        }
        return a.descendants(matching: .any)[name]
    }

    func testDragDrive() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["KAYA_DRIVE_DIR"], !dir.isEmpty else {
            XCTFail("KAYA_DRIVE_DIR is unset")
            return
        }
        let fm = FileManager.default
        let requestPath = dir + "/request", responsePath = dir + "/response"
        let partPath = dir + "/response.part"
        func answer(_ ok: Bool, _ body: String) {
            try? fm.removeItem(atPath: partPath)
            fm.createFile(atPath: partPath,
                          contents: Data(((ok ? "ok\n" : "err\n") + body + (body.isEmpty ? "" : "\n")).utf8))
            try? fm.removeItem(atPath: responsePath)
            try? fm.moveItem(atPath: partPath, toPath: responsePath)
        }
        func coord(_ a: XCUIApplication, _ w: [String], _ i: Int) -> XCUICoordinate? {
            guard w.count > i + 1, let x = Double(w[i]), let y = Double(w[i + 1]) else { return nil }
            return a.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
        }
        fm.createFile(atPath: dir + "/ready",
                      contents: Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
        let deadline = Date().addingTimeInterval(3 * 3600)
        while Date() < deadline {
            guard let data = fm.contents(atPath: requestPath),
                  let text = String(data: data, encoding: .utf8) else {
                pause(0.02)
                continue
            }
            try? fm.removeItem(atPath: requestPath)
            let w = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            guard let verb = w.first else { answer(false, "empty request"); continue }
            let rest = w.dropFirst().joined(separator: " ")
            let (ok, body) = handle(verb, w, rest, coord)
            answer(ok, body)
            if verb == "quit" { return }
        }
        answer(false, "the resident deadline passed")
    }

    func handle(_ verb: String, _ w: [String], _ rest: String,
                _ coord: (XCUIApplication, [String], Int) -> XCUICoordinate?) -> (Bool, String) {
        switch verb {
        case "quit": return (true, "bye")
        case "attach":
            guard w.count == 2 else { return (false, "attach <bundle-id>") }
            let a = XCUIApplication(bundleIdentifier: w[1])
            a.activate()
            let ok = a.wait(for: .runningForeground, timeout: 20)
            app = ok ? a : nil
            return (ok, "state=\(a.state.rawValue) frame=\(rect(a.frame))")
        case "sb_describe":
            return (true, XCUIApplication(bundleIdentifier: "com.apple.springboard").debugDescription)
        case "press", "sb_tap":
            let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            var hit = sb.buttons[rest]
            if !hit.exists, let a = app { hit = byName(a, rest) }
            guard hit.exists else { return (false, "nothing carries the label \(rest)") }
            hit.tap()
            return (true, "pressed \(rest)")
        default: break
        }
        guard let a = app else { return (false, "no app attached") }
        switch verb {
        case "frame": return (true, rect(a.frame))
        case "describe": return (true, a.debugDescription)
        case "find":
            let hit = byName(a, rest)
            return hit.exists ? (true, "\(rect(hit.frame)) hittable=\(hit.isHittable)")
                              : (false, "no element labelled \(rest)")
        case "tap":
            guard let p = coord(a, w, 1) else { return (false, "tap X Y") }
            p.tap()
            return (true, "tapped")
        case "drag":
            guard let p1 = coord(a, w, 1), let p2 = coord(a, w, 3) else {
                return (false, "drag X1 Y1 X2 Y2 [HOLD_MS]")
            }
            let hold = w.count > 5 ? (Double(w[5]) ?? 100) / 1000 : 0.1
            p1.press(forDuration: hold, thenDragTo: p2)
            return (true, "dragged")
        case "xdrag":
            // xdrag X1 Y1 X2 Y2 LIFT_MS VELOCITY HOLD_MS
            guard let p1 = coord(a, w, 1), let p2 = coord(a, w, 3), w.count > 7,
                  let lift = Double(w[5]), let vel = Double(w[6]), let hold = Double(w[7]) else {
                return (false, "xdrag X1 Y1 X2 Y2 LIFT_MS VELOCITY HOLD_MS")
            }
            p1.press(forDuration: lift / 1000, thenDragTo: p2,
                     withVelocity: XCUIGestureVelocity(rawValue: vel),
                     thenHoldForDuration: hold / 1000)
            return (true, "xdragged lift=\(lift)ms v=\(vel) hold=\(hold)ms")
        case "xdrag_el":
            // xdrag_el <src-label> -> <dst-label> LIFT_MS VELOCITY HOLD_MS
            // XCUIElement's own press-drag, which is what Apple's iPad
            // drag-and-drop guidance uses.
            let parts = rest.components(separatedBy: " -> ")
            guard parts.count == 2 else { return (false, "xdrag_el <src> -> <dst> LIFT VEL HOLD") }
            let tail = parts[1].split(separator: " ").map(String.init)
            guard tail.count >= 4, let lift = Double(tail[tail.count - 3]),
                  let vel = Double(tail[tail.count - 2]), let hold = Double(tail[tail.count - 1])
            else { return (false, "xdrag_el <src> -> <dst> LIFT VEL HOLD") }
            let dstName = tail[0..<(tail.count - 3)].joined(separator: " ")
            let src = byName(a, parts[0])
            guard src.exists else { return (false, "no source labelled \(parts[0])") }
            guard let target = app2, case let dst = byName(target, dstName), dst.exists else {
                return (false, "no destination labelled \(dstName) in the second app")
            }
            src.press(forDuration: lift / 1000, thenDragTo: dst,
                      withVelocity: XCUIGestureVelocity(rawValue: vel),
                      thenHoldForDuration: hold / 1000)
            return (true, "xdrag_el done")
        case "attach2":
            guard w.count == 2 else { return (false, "attach2 <bundle-id>") }
            app2 = XCUIApplication(bundleIdentifier: w[1])
            return (true, "second app \(w[1]) state=\(app2!.state.rawValue) frame=\(rect(app2!.frame))")
        case "describe2":
            guard let b = app2 else { return (false, "attach2 first") }
            return (true, b.debugDescription)
        default:
            return (false, "unknown verb \(verb)")
        }
    }

    var app2: XCUIApplication?
}
