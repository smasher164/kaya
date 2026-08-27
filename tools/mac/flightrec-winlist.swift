// The flight recorder's macOS window list: every on-screen window with its
// id, owner pid, title and bounds, one per line.
//
// The window ID is the point of it. docs/traps.md's capture rule is that a
// shot is taken of ONE WINDOW BY ID (`screencapture -l<id>`) and never
// full-screen, because a full-screen grab photographs whatever the human
// had frontmost — their browser, their editor — which is a privacy leak on
// a shared machine. So the at-fail screenshot needs this list first, and
// the list is worth keeping on its own: "which windows existed when the leg
// failed" is the question a bare verdict cannot answer.
//
// Built on demand to a content-hashed path under target/ by
// tools/lib/flightrec.sh, and honestly skipped when no swiftc is present.
//
//   flightrec-winlist [<pid>]   all windows, or only that pid's

import CoreGraphics
import Foundation

let wanted: Int? = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) : nil

guard
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
else {
    // A DIAGNOSTIC MAY ONLY PRINT WHAT IT MEASURED (invariant 3): the call
    // answering nil and there being no windows are different states, and
    // this says which one it saw.
    print("flightrec-winlist: CGWindowListCopyWindowInfo answered nil")
    exit(1)
}

var printed = 0
for w in windows {
    let pid = w[kCGWindowOwnerPID as String] as? Int ?? -1
    if let wanted, pid != wanted { continue }
    let id = w[kCGWindowNumber as String] as? Int ?? -1
    let app = w[kCGWindowOwnerName as String] as? String ?? "?"
    let title = w[kCGWindowName as String] as? String ?? ""
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    var box = "?"
    if let b = w[kCGWindowBounds as String] as? [String: Any],
        let x = b["X"] as? Double, let y = b["Y"] as? Double,
        let width = b["Width"] as? Double, let height = b["Height"] as? Double
    {
        box = "\(Int(x)),\(Int(y)),\(Int(width)),\(Int(height))"
    }
    print(
        "win=\(id) pid=\(pid) layer=\(layer) bounds=\(box) "
            + "app=\(app.debugDescription) title=\(title.debugDescription)")
    printed += 1
}
print("flightrec-winlist: \(printed) window(s)\(wanted.map { " for pid \($0)" } ?? "")")
