// THE iOS LANE'S FOREIGN CLIPBOARD PROCESS: the reader behind
// `expect_clipboard` and the writer behind `clipboard_seed`, run with
// `simctl spawn` so every crossing is a real process boundary.
//
// Why a binary of its own. The clipboard scene's whole design is that
// every assertion crosses a process boundary — a check where kaya
// parses its own writes cannot fail for the reason the design exists —
// and on this platform no stock tool can make that crossing IN EITHER
// DIRECTION: `simctl pbpaste <device>` reads the union clip as EMPTY,
// `simctl pbsync <device> host` DROPS app-defined types and file urls,
// and the host->device direction DELIVERS ASYNCHRONOUSLY after exiting
// rc=0 — the window that intermittently handed the guest an empty
// board (docs/clipboard-plan.md §8 findings 3 and 6). A plain CLI
// under `simctl spawn` crosses cleanly: no app, no UI, no bundle, and
// it still talks to the pasteboard service. Writes are synchronous and
// visible to other processes before this exits (measured, 246ms), and
// its content is attributed to THIS principal — foreign to the app, so
// the app's read prompts, which is the design. Data READS are gated by
// the same per-clip prompt, answered by the host through simdrive
// while this process is parked (tools/ios/run-sim.sh, clip_read); the
// type list answers prompt-free, including the slashed `dev.kaya/note`
// verbatim (§8 findings 1 and 4).
//
// Verbs: `types` | `read <kind>` | `write <kind> <b64>`, where kind is
// text|html|image|files or a custom id (reads only — no stock tool
// writes an app-defined type, and a helper kaya wrote would be foreign
// in name only; the seed grammar refuses custom everywhere).
//
// One fact per line, so the host needs no framing: `S types=[...]`
// always, then `S b64=<base64>` for a read — empty when the board does
// not carry the kind.
import UIKit

let pb = UIPasteboard.general
let arguments = CommandLine.arguments
let verb = arguments.count > 1 ? arguments[1] : "types"

if verb == "write" {
    guard arguments.count >= 4, let bytes = Data(base64Encoded: arguments[3]) else {
        FileHandle.standardError.write(Data("clipctl write needs <kind> <b64>\n".utf8))
        exit(2)
    }
    let kind = arguments[2]
    // ONE item, REPLACING the board — a seed is the whole clipboard,
    // exactly as pbcopy and the other lanes' seeds behave. The value
    // spellings are the measured ones (§8 finding 1: items= preserves
    // each verbatim).
    var item: [String: Any]
    switch kind {
    case "text":
        item = ["public.utf8-plain-text": String(decoding: bytes, as: UTF8.self)]
    case "html":
        item = ["public.html": String(decoding: bytes, as: UTF8.self)]
    case "image":
        item = ["public.png": bytes]
    case "files":
        // The payload is the file's absolute path — the container path
        // is the same string on the host and inside the simulator.
        item = ["public.file-url": URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))]
    default:
        FileHandle.standardError.write(Data("clipctl cannot write \(kind)\n".utf8))
        exit(2)
    }
    // AND KAYA'S STAGE MARKER BESIDE IT. A seed is foreign in its WRITER
    // and this leg's in its INTENT, and the app's witness asks the
    // second question: is this still the clip the leg staged? On this
    // platform the only answer is a private type kaya put there —
    // UIPasteboard's change count is a per-process number that a text
    // field taking focus inflates, and no notification is delivered for
    // another process's write (both measured 2026-08-18, docs/traps.md).
    // So the board this seed leaves has to be markable as kaya's, or the
    // witness has nothing to compare and the scene's widest window — the
    // last seed, with three consuming steps after it — goes unwatched.
    //
    // THE SPELLING IS swift/KayaSwiftUI.swift's `kayaClipMarkerType` and
    // no compiler can hold the two binaries to it. The app does, at
    // runtime: its stage refuses to close on a board it composed without
    // its marker, so a drift between these two strings fails the first
    // iOS clipboard leg with a sentence naming both. Change one, change
    // the other.
    item["dev.kaya/staged"] = "staged"
    pb.items = [item]
    print("W types=\(pb.types)")
    fflush(stdout)
    // HOLD: stay alive until killed. The pasteboard daemon serves an
    // item's DATA by fetching it from the process that set it, and a
    // writer that exits right away intermittently leaves a reader an
    // empty answer — measured 1-in-5 SOLO for a 77-byte png, worse
    // under the matrix (§8 finding 6's coda). There is no API that
    // says "materialized"; a living writer is the only shape with no
    // window at all. The host kills this at the next seed or the
    // leg's end, and every seed replaces the board wholesale, so a
    // dying promise never has a consumer.
    if arguments.count > 4, arguments[4] == "hold" {
        while true { sleep(60) }
    }
    exit(0)
}

print("S types=\(pb.types)")
// FLUSHED HERE, not left to exit. stdout is a pipe, the caller bounds
// this process with `timeout`, and the types line is exactly what tells
// an unanswered prompt from an empty board — so it has to have left the
// buffer before the blocking read starts.
fflush(stdout)

let kind = verb == "read" && arguments.count > 2 ? arguments[2] : ""
var payload: Data? = nil
switch kind {
case "":
    // Types only: the prompt-free look, which is all a caller that
    // names no kind is entitled to.
    payload = nil
case "text":
    payload = pb.string.map { Data($0.utf8) }
case "html":
    payload = pb.data(forPasteboardType: "public.html")
case "image":
    payload = pb.data(forPasteboardType: "public.png")
case "files":
    // The urls, one per line. The host reduces them to basenames: the
    // expected string is compared byte for byte across lanes whose
    // containers are at different paths.
    var urls = (pb.urls ?? []).map(\.absoluteString)
    if urls.isEmpty {
        // MEASURED, and the reason this arm is two reads rather than
        // one: `urls` answers EMPTY from a spawned reader even with
        // `public.file-url` on the board and its bytes reading back
        // byte-exact under that type. The property resolves a file url
        // against a sandbox this process does not have; the raw type is
        // the same answer with no resolution in the way. Several files
        // are several ITEMS, so this walks them.
        urls = pb.items.compactMap { item -> String? in
            guard let value = item["public.file-url"] else { return nil }
            if let data = value as? Data { return String(data: data, encoding: .utf8) }
            if let url = value as? URL { return url.absoluteString }
            if let text = value as? String { return text }
            return nil
        }
    }
    payload = urls.isEmpty ? nil : Data(urls.joined(separator: "\n").utf8)
default:
    // A CUSTOM ID IS ITS OWN TYPE, verbatim. UIPasteboard preserves
    // `dev.kaya/note` exactly as the guest wrote it (§8 finding 1), so
    // no mapping table sits between the guest's id and this read — the
    // macOS two-path dance has no iOS twin.
    payload = pb.data(forPasteboardType: kind)
}
if !kind.isEmpty {
    print("S b64=\(payload?.base64EncodedString() ?? "")")
}
fflush(stdout)
