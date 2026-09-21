import Foundation

final class TypingPhase { var waiting = false }
struct KeyboardReading { let count: Int }
final class XCUIApplication {
    let phase: TypingPhase
    let before: Int
    let after: Int
    init(_ phase: TypingPhase, _ before: Int, _ after: Int) {
        self.phase = phase
        self.before = before
        self.after = after
    }
    var keyboards: KeyboardReading { KeyboardReading(count: phase.waiting ? before : after) }
}
final class TypingProbe {
    let phase = TypingPhase()
    var notes: [String] = []
    func note(_ value: String) { notes.append(value) }
    func waitFor(_ label: String, _ seconds: TimeInterval?, _ body: () -> Bool) -> Bool {
        phase.waiting = true
        defer { phase.waiting = false }
        return body()
    }
}

@main struct TypingReadinessCheck {
    static func main() {
        var checked = 0, failed = 0
        for beforeFocus in [nil, false, true] as [Bool?] {
            for afterFocus in (beforeFocus == nil ? [nil] : [false, true]) as [Bool?] {
                for beforeKeyboard in [0, 1] {
                    for afterKeyboard in [0, 1] {
                        checked += 1
                        let probe = TypingProbe()
                        let app = XCUIApplication(probe.phase, beforeKeyboard, afterKeyboard)
                        let focus: (() -> Bool)? = beforeFocus == nil ? nil : {
                            (probe.phase.waiting ? beforeFocus : afterFocus)!
                        }
                        let waited = beforeFocus == true || beforeKeyboard > 0
                        let current = afterFocus == true || afterKeyboard > 0
                        let want = waited && current
                        let result = probe.typingRefusal(app, "save name", focused: focus)
                        let reading = "waited=\(waited) focused="
                            + (afterFocus.map { "\($0)" } ?? "<not asked>")
                            + " keyboards=\(afterKeyboard)"
                        let diagnostic = "typing into save name: \(want ? "ready" : "REFUSED"), \(reading)"
                        let reason = waited ? "readiness disappeared after waiting" : "the readiness wait expired"
                        let refusal = "typing refused for save name: \(reason) (\(reading)); nothing was typed"
                        let good = (result == nil) == want && probe.notes == [diagnostic]
                            && (want || result == refusal)
                        if !good { failed += 1 }
                        print("\(good ? "PASS" : "FAIL") typing case \(checked): \(diagnostic); answer=\(result ?? "admitted")")
                    }
                }
            }
        }
        guard checked == 20 && failed == 0 else {
            print("typing-readiness: \(failed) failures in \(checked) cases")
            exit(1)
        }
        print("typing-readiness: 20 cases passed")
    }
}
