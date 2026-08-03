// ClipProbe (macOS) — what does this host charge for a clipboard read,
// and what does a foreign reader see of a multi-representation clip?
//
// THE QUESTION THAT DECIDES THE MAC ARM. macOS 15 grew the same
// restriction iOS 16 has: an app that programmatically reads pasteboard
// content written by ANOTHER app gets a permission alert, unless the
// read is a user paste gesture. This host is macOS 26. If it prompts,
// `read_clipboard`'s mac leg has to drive an alert exactly as the file
// dialog leg drives a panel, and the scene's shape changes with it.
//
//  Q1 Do the cheap queries — changeCount, types, canReadObject — report
//     FOREIGN content without a prompt? The offers signal depends on
//     it, and so does every "is Paste enabled" answer.
//  Q2 Does reading foreign content prompt, block, or answer? A prompt
//     shows up as a read that takes human time, or as an alert on
//     screen while the read returns immediately from a cache.
//  Q3 Does reading our OWN content prompt? The plan assumes not.
//  Q4 What survives a round trip through a FOREIGN READER? kaya writes
//     custom, files, image, html, text in one declareTypes; `pbpaste
//     -Prefer` reads back what a plain consumer would get. A test
//     where kaya reads what kaya wrote cannot catch a malformed
//     lowering, so this is the one that matters.
//  Q5 Do the writes need the main thread? The apply pump is not on it.
//  Q7 What does an IMAGE cost? kaya's image representation is encoded
//     bytes, the same currency the image prop uses. Three ways to put
//     them on: raw data under public.png, raw data under public.tiff,
//     and writeObjects(NSImage). Which types does each declare, and
//     what comes back — the same bytes, or a re-encode?
//  Q6 Does an UNBUNDLED binary behave like a bundled app? The lane's
//     foreign writer is `pbcopy`, and if the prompt keys off a bundle
//     identity then a bare CLI probe would measure the wrong thing.
//     build.sh runs this file both ways and diffs the answers.
//
// Answers land on stdout under "PROBE". Not a lane; nothing builds it
// but build.sh beside it.
import AppKit
import UniformTypeIdentifiers

func say(_ s: String) {
    print("PROBE \(s)")
    fflush(stdout)
}

/// Wall time around a call, because "prompted" shows up as a read that
/// takes human time, not as an error.
@discardableResult
func timed<T>(_ label: String, _ body: () -> T) -> T {
    let t0 = Date()
    let out = body()
    say("\(label) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    return out
}

/// Run a command and hand back its stdout — the foreign app in every
/// question here. pbcopy and pbpaste are separate processes with their
/// own pasteboard identity, which is exactly the point.
@discardableResult
func shell(_ args: [String], stdin: String? = nil) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    if let stdin {
        let input = Pipe()
        p.standardInput = input
        try? p.run()
        input.fileHandleForWriting.write(stdin.data(using: .utf8)!)
        input.fileHandleForWriting.closeFile()
    } else {
        try? p.run()
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

let bundled = Bundle.main.bundleIdentifier ?? "<none>"
say("==== begin, macOS \(ProcessInfo.processInfo.operatingSystemVersionString), bundle \(bundled)")

let pb = NSPasteboard.general

// ---- foreign content, written by a process that is not us ----------
shell(["pbcopy"], stdin: "foreign text from pbcopy")
say("Q1 changeCount=\(pb.changeCount)")
say("Q1 types=\(pb.types?.map(\.rawValue) ?? [])")
say("Q1 canReadString=\(pb.canReadObject(forClasses: [NSString.self]))")
say("Q1 canReadURL=\(pb.canReadObject(forClasses: [NSURL.self]))")

// Q2: the read itself. Two shapes — the typed accessor and the object
// reader — because the restriction is documented per-read, not
// per-pasteboard, and they may not agree.
let foreign = timed("Q2 string(forType:.string)") { pb.string(forType: .string) }
say("Q2 string=\(foreign ?? "<nil>")")
let objects = timed("Q2 readObjects(NSString)") {
    pb.readObjects(forClasses: [NSString.self], options: nil) as? [String] ?? []
}
say("Q2 readObjects=\(objects)")

// ---- our own content, in every representation kaya has -------------
//
// ONE declareTypes AND ONE ITEM: kaya's clip is one item offered in
// several types, which is what every host models and what the record
// shape in the plan mirrors. The order here is kaya's canonical order —
// descending clip value, which is descending richness — and on this
// host that IS the preference order a consumer walks.
let customType = NSPasteboard.PasteboardType("dev.kaya.probe.note")
let png = NSImage(size: NSSize(width: 4, height: 4))
png.lockFocus()
NSColor.systemPink.drawSwatch(in: NSRect(x: 0, y: 0, width: 4, height: 4))
png.unlockFocus()
let tiff = png.tiffRepresentation ?? Data()
let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kaya-clipprobe.txt")
try? "picked file body".write(to: fileURL, atomically: true, encoding: .utf8)

func writeClip(on queue: String) -> Bool {
    pb.clearContents()
    // declareTypes answers the new change count, not a success flag —
    // the setters are the ones that report.
    let stamp = pb.declareTypes([customType, .fileURL, .tiff, .html, .string], owner: nil)
    var ok = pb.setData("{\"note\":1}".data(using: .utf8)!, forType: customType)
    ok = pb.setString(fileURL.absoluteString, forType: .fileURL) && ok
    ok = pb.setData(tiff, forType: .tiff) && ok
    ok = pb.setString("<b>rich</b> text", forType: .html) && ok
    ok = pb.setString("rich text", forType: .string) && ok
    say("Q5 wrote from \(queue): ok=\(ok) declared=\(stamp) changeCount=\(pb.changeCount)")
    return ok
}

_ = writeClip(on: "main")

// Q3: read back what we just wrote. The plan assumes this is free.
let own = timed("Q3 own string(forType:.string)") { pb.string(forType: .string) }
say("Q3 own string=\(own ?? "<nil>")")
say("Q3 own types=\(pb.types?.map(\.rawValue) ?? [])")

// Q4: THE ONE THAT CANNOT BE FAKED — a foreign process reading our clip.
for flavor in ["public.utf8-plain-text", "public.html", "public.file-url", "dev.kaya.probe.note"] {
    let got = shell(["pbpaste", "-Prefer", flavor])
    say("Q4 pbpaste -Prefer \(flavor) -> \(got.prefix(60).replacingOccurrences(of: "\n", with: "\\n"))")
}
say("Q4 pbpaste plain -> \(shell(["pbpaste"]).prefix(60))")

// Q5: off the main thread, which is where the apply pump lives.
let done = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    _ = writeClip(on: "background queue")
    let back = pb.string(forType: .string)
    say("Q5 background read back=\(back ?? "<nil>")")
    done.signal()
}
_ = done.wait(timeout: .now() + 5)

// And once more from the foreign side, to see whether a prompt (if any)
// is one-per-launch or one-per-read.
shell(["pbcopy"], stdin: "second foreign text")
let again = timed("Q2b second foreign read") { pb.string(forType: .string) }
say("Q2b string=\(again ?? "<nil>")")

// ---- Q7: the image, three ways -------------------------------------
//
// The guest hands kaya ENCODED BYTES and expects an image on the
// clipboard; what it gets BACK may not be the same bytes, and the scene
// has to assert something that survives a re-encode if so.
let pngData = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) ?? Data()
say("Q7 png bytes=\(pngData.count) tiff bytes=\(tiff.count)")

pb.clearContents()
_ = pb.declareTypes([.png], owner: nil)
_ = pb.setData(pngData, forType: .png)
say("Q7 raw-png declares=\(pb.types?.map(\.rawValue) ?? [])")
say("Q7 raw-png readback png=\(pb.data(forType: .png)?.count ?? -1) tiff=\(pb.data(forType: .tiff)?.count ?? -1)")
say("Q7 raw-png foreign sees=\(shell(["pbpaste", "-Prefer", "public.png"]).count) bytes")

pb.clearContents()
let ok7 = pb.writeObjects([NSImage(data: pngData) ?? NSImage()])
say("Q7 writeObjects(NSImage) ok=\(ok7) declares=\(pb.types?.map(\.rawValue) ?? [])")
say("Q7 writeObjects readback png=\(pb.data(forType: .png)?.count ?? -1) tiff=\(pb.data(forType: .tiff)?.count ?? -1)")

// ---- Q8: what foreign reader can the LANE use? ---------------------
//
// pbpaste is a TEXT tool: it answered nothing at all for public.png
// above. The harness needs one foreign reader that can see every
// representation, or the image leg cannot be verified from outside —
// and "kaya reads what kaya wrote" is exactly the check that cannot
// fail for the reason the design exists.
_ = writeClip(on: "main (for Q8)")
say("Q8 clipboard info -> \(shell(["osascript", "-e", "clipboard info"]).trimmingCharacters(in: .whitespacesAndNewlines))")
pb.clearContents()
_ = pb.declareTypes([.png], owner: nil)
_ = pb.setData(pngData, forType: .png)
say("Q8 image-only clipboard info -> \(shell(["osascript", "-e", "clipboard info"]).trimmingCharacters(in: .whitespacesAndNewlines))")

// ---- Q9: SEVERAL FILES, and the one-item model ---------------------
//
// kaya's clip is ONE item in several types, but macOS represents
// several files as several ITEMS. So a clip with two files and a text
// rendition has to be expressed somehow, and the choice decides the
// arm: does Finder see two files, and does a text field still see the
// text?
let f2 = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kaya-clipprobe-2.txt")
try? "second file body".write(to: f2, atomically: true, encoding: .utf8)

pb.clearContents()
let okUrls = pb.writeObjects([fileURL as NSURL, f2 as NSURL])
say("Q9 writeObjects(2 urls) ok=\(okUrls) items=\(pb.pasteboardItems?.count ?? -1)")
say("Q9 types=\(pb.types?.map(\.rawValue) ?? [])")
say("Q9 readObjects(NSURL)=\((pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []).map(\.lastPathComponent))")
say("Q9 foreign file-url -> \(shell(["pbpaste", "-Prefer", "public.file-url"]).trimmingCharacters(in: .whitespacesAndNewlines))")

// The mixed clip: two files AND a text rendition, built as items by
// hand — item 0 carries everything single-valued, later items carry
// the remaining files.
pb.clearContents()
let i0 = NSPasteboardItem()
i0.setString(fileURL.absoluteString, forType: .fileURL)
i0.setString("\(fileURL.path)\n\(f2.path)", forType: .string)
let i1 = NSPasteboardItem()
i1.setString(f2.absoluteString, forType: .fileURL)
let okMixed = pb.writeObjects([i0, i1])
say("Q9 mixed ok=\(okMixed) items=\(pb.pasteboardItems?.count ?? -1)")
say("Q9 mixed readObjects(NSURL)=\((pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []).map(\.lastPathComponent))")
say("Q9 mixed foreign text -> \(shell(["pbpaste"]).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | "))")
say("Q9 mixed clipboard info -> \(shell(["osascript", "-e", "clipboard info"]).trimmingCharacters(in: .whitespacesAndNewlines))")

say("==== end")
