// The flight recorder's macOS window list: every on-screen window with
// its id, owner pid, layer, bounds and app, one per line; the title only
// for a window of the `--own` pid (docs/traps.md, foreign window titles).
//
// The window ID is the point: a shot is taken of ONE WINDOW BY ID
// (`screencapture -l<id>`) and never full-screen, which would photograph
// whatever the human had frontmost (docs/traps.md). Built on demand to a
// content-hashed path by tools/lib/flightrec.sh.
//
//   flightrec-winlist [--own <pid>] [<pid>]   all windows, or only that pid's

import CoreGraphics
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
var own: Int? = nil
if let at = args.firstIndex(of: "--own") {
    guard at + 1 < args.count, let pid = Int(args[at + 1]), pid > 0 else {
        print("flightrec-winlist: --own needs a pid")
        exit(2)
    }
    own = pid
    args.removeSubrange(at...(at + 1))
}

// AN ARGUMENT THAT IS NOT A PID IS REFUSED, never read as "no filter": a
// caller passing a missing pid ("None") once got every window and shot the
// frontmost one, which was the human's (docs/traps.md, 2026-09-28).
var wanted: Int? = nil
if let first = args.first {
    guard let pid = Int(first), pid > 0 else {
        print("flightrec-winlist: \"\(first)\" is not a pid")
        exit(2)
    }
    wanted = pid
}

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
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    var box = "?"
    if let b = w[kCGWindowBounds as String] as? [String: Any],
        let x = b["X"] as? Double, let y = b["Y"] as? Double,
        let width = b["Width"] as? Double, let height = b["Height"] as? Double
    {
        box = "\(Int(x)),\(Int(y)),\(Int(width)),\(Int(height))"
    }
    var line = "win=\(id) pid=\(pid) layer=\(layer) bounds=\(box) app=\(app.debugDescription)"
    if let own, pid == own {
        line += " title=\((w[kCGWindowName as String] as? String ?? "").debugDescription)"
    }
    print(line)
    printed += 1
}
print("flightrec-winlist: \(printed) window(s)\(wanted.map { " for pid \($0)" } ?? "")")
