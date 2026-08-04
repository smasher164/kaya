// The S cell: can a process launched with `simctl spawn` — not an app,
// no UI, no scene — read the simulator's pasteboard through
// UIPasteboard, and does the paste prompt gate it?
//
// Why it matters: pbsync device->host DROPS app-defined types
// (measured, campaign A), so no stock host tool can confirm the custom
// representation's bytes under their id. The android lane's answer was
// a genuinely-separate reading process (the helper APK); this is the
// iOS spelling of the same question. If the read answers here, this
// binary is the lane's foreign reader for every kind; if it prompts,
// there is no screen to press and the answer is a hang, which the
// bounded runner reads as "no".
import UIKit

let pb = UIPasteboard.general
print("S numberOfItems=\(pb.numberOfItems)")
print("S types=\(pb.types)")
let kind = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
switch kind {
case "":
    break
case "text":
    print("S text=[\(pb.string ?? "<nil>")]")
case "html":
    let d = pb.data(forPasteboardType: "public.html")
    print("S html=[\(d.flatMap { String(data: $0, encoding: .utf8) } ?? "<nil>")]")
case "image":
    print("S png-bytes=\(pb.data(forPasteboardType: "public.png")?.count ?? -1)")
case "files":
    print("S urls=\((pb.urls ?? []).map(\.absoluteString))")
default:
    let d = pb.data(forPasteboardType: kind)
    print("S \(kind)=[\(d.flatMap { String(data: $0, encoding: .utf8) } ?? "<nil>")] bytes=\(d?.count ?? -1)")
}
fflush(stdout)
