// ClipProbe II — the cells the iOS ARM turns on, each measured before
// a line of arm code, the way every platform's second campaign was.
// The first campaign (main.swift) measured the PROMPT; this one
// measures the WRITE PATH, the sync bridge, and the prompt's mechanics
// under the reads the arm will actually issue.
//
// Three modes, and the cells each measures are docs/clipboard-plan.md §8:
//   W (mode=write) the union write on the arm's own path, then the host
//     terminates the app and pbsyncs device->host, so persistence past
//     process exit is measured in the same stroke.
//   R (mode=recv)  the prompt-free queries against host-seeded content,
//     NO data touch.
//   P (mode=read)  the prompted read, on the arm's thread plan — the
//     read on a BACKGROUND queue while the main thread heartbeats.
//
// Answers land on stdout under "PROBE". Not a lane; nothing builds it
// but run2.sh beside it.
import UIKit

func say(_ s: String) {
    NSLog("PROBE %@", s)
    print("PROBE \(s)")
    fflush(stdout)
}

func timed<T>(_ label: String, _ body: () -> T) -> T {
    let t0 = Date()
    let out = body()
    say("\(label) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    return out
}

// The guests' shared 4x4 RGB PNG, byte for byte (guests/rust/clipboard.rs).
let pixelPNG = Data([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x26, 0x93, 0x09,
    0x29, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41,
    0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x47, 0x48, 0x4C, 0x74, 0xDE, 0x7F, 0x24, 0x00,
    0x00, 0xD2, 0x6F, 0x17, 0xE9, 0x51, 0xBB, 0x23,
    0x2D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82,
])

let noteID = "dev.kaya/note"
let noteBytes = Data("note=1".utf8)

func runWrite(_ pb: UIPasteboard) {
    // A real file in Documents for the file-url item — the same
    // container path the host can reach through get_app_container.
    let docs = NSHomeDirectory() + "/Documents"
    let filePath = docs + "/copied.txt"
    try? "copied bytes".write(toFile: filePath, atomically: true, encoding: .utf8)
    let fileURL = URL(fileURLWithPath: filePath)

    // W1: the union write through `items` — the arm's candidate path.
    let item: [String: Any] = [
        noteID: noteBytes,
        "public.png": pixelPNG,
        "public.html": "<b>kaya</b> clip",
        "public.utf8-plain-text": "kaya clip",
    ]
    let fileItem: [String: Any] = ["public.file-url": fileURL]
    pb.items = [item, fileItem]
    say("W1 after items=: numberOfItems=\(pb.numberOfItems) types=\(pb.types)")
    say("W1 item1 types=\(pb.types(forItemSet: IndexSet(integer: 1)) ?? [])")
    say("W1 custom-id-verbatim=\(pb.types.contains(noteID))")

    // W2: every representation back, as our own content.
    let gotNote = pb.data(forPasteboardType: noteID)
    say("W2 custom -> \(gotNote == noteBytes ? "byte-exact" : String(describing: gotNote))")
    let gotPNG = pb.data(forPasteboardType: "public.png")
    say("W2 png -> \(gotPNG == pixelPNG ? "byte-exact" : "differs: \(gotPNG?.count ?? -1) bytes")")
    let gotHTML = pb.data(forPasteboardType: "public.html")
        .flatMap { String(data: $0, encoding: .utf8) }
    say("W2 html -> \(gotHTML == "<b>kaya</b> clip" ? "exact" : String(describing: gotHTML))")
    say("W2 string -> \(pb.string.map { "\"\($0)\"" } ?? "nil")")
    let urls = pb.urls ?? []
    say("W2 urls -> \(urls.map(\.absoluteString))")
    let itemSetURL = pb.data(forPasteboardType: "public.file-url", inItemSet: IndexSet(integer: 1))
    say("W2 file-url raw -> \(itemSetURL?.first.flatMap { String(data: $0, encoding: .utf8) } ?? "nil")")

    // W3: the other write path, alone, in case W1 dropped the id.
    if !pb.types.contains(noteID) {
        pb.setData(noteBytes, forPasteboardType: noteID)
        say("W3 after setData: types=\(pb.types) verbatim=\(pb.types.contains(noteID))")
        // Rebuild the union for the host's read-back either way.
        pb.items = [item, fileItem]
    } else {
        say("W3 not needed: the items= path preserved the id")
    }
    say("W done: changeCount=\(pb.changeCount)")
}

func runRecv(_ pb: UIPasteboard) {
    // NOTHING here touches item data. This is the whole cell.
    say("R numberOfItems=\(pb.numberOfItems)")
    say("R types=\(pb.types)")
    for i in 0..<pb.numberOfItems {
        say("R item\(i) types=\(pb.types(forItemSet: IndexSet(integer: i)) ?? [])")
    }
    say("R hasStrings=\(pb.hasStrings) hasURLs=\(pb.hasURLs) hasImages=\(pb.hasImages)")
    say("R changeCount=\(pb.changeCount)")
    say("R done, no data was touched")
}

func runRead(_ pb: UIPasteboard) {
    // The arm's thread plan: reads off the main thread, main heartbeats.
    var beats = 0
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
        beats += 1
        say("heartbeat \(beats)")
        if beats >= 80 { timer.invalidate() }
    }
    DispatchQueue.global().async {
        say("P0 types (prompt-free, before any data) = \(pb.types)")
        let countBefore = pb.changeCount
        let first = timed("P1 FIRST foreign read") { pb.string }
        say("P1 -> \(first.map { "\"\($0)\"" } ?? "nil")")
        let second = timed("P2 SECOND read, same content") { pb.string }
        say("P2 -> \(second.map { "\"\($0)\"" } ?? "nil")")
        // Wait (prompt-free) for the host's re-seed, then read again.
        say("P3 waiting for a changeCount past \(countBefore)…")
        let deadline = Date().addingTimeInterval(25)
        while pb.changeCount <= countBefore, Date() < deadline { usleep(300_000) }
        say("P3 changeCount now \(pb.changeCount)")
        let third = timed("P3 read of RE-SEEDED content") { pb.string }
        say("P3 -> \(third.map { "\"\($0)\"" } ?? "nil")")
        say("==== end")
    }
}

final class VC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let mode = ProcessInfo.processInfo.environment["KAYA_CLIPPROBE_MODE"] ?? "write"
        say("==== begin mode=\(mode), ios \(UIDevice.current.systemVersion)")
        let pb = UIPasteboard.general
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            switch mode {
            case "write": runWrite(pb); say("==== end")
            case "recv": runRecv(pb); say("==== end")
            case "read": runRead(pb)
            default: say("unknown mode \(mode)")
            }
        }
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(
        _ a: UIApplication,
        didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = VC()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}

UIApplicationMain(
    CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
