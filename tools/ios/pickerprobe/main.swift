// PickerProbe — what the harness can SEE and DO to the iOS document
// picker, measured in the SIMULATOR, which is where the lane runs.
//
// Not the same question tools/ios/scopeprobe answers. That one needs
// HARDWARE, because it asks what the sandbox DENIES and the simulator
// enforces nothing (docs/traps.md). This one asks what the picker's UI
// looks like from inside the app, which the simulator answers honestly
// because it is the same UIKit.
//
// THE QUESTION THAT DECIDES THE WHOLE ARM, because iOS has no
// accessibility-service escape hatch the way Android does:
//
//  Q1 Is UIDocumentPickerViewController's content REACHABLE IN-PROCESS?
//     Every other backend reads the real picker — AX on mac, AT-SPI on
//     GTK, UI Automation on Windows, an accessibility service on
//     Android. On iOS the picker is widely believed to be a REMOTE view
//     controller hosted by another process, in which case the app sees
//     a placeholder with no rows and `expect_file_dialog` has nothing
//     to read. If that is so, the iOS arm needs a different answer to
//     "drive the real picker" and it is better to know now.
//  Q2 Where can the guest write that the picker can BROWSE? The app's
//     own container is only visible to the Files browser when the
//     bundle says so (UIFileSharingEnabled +
//     LSSupportsOpeningDocumentsInPlace), which is an Info.plist
//     question, not a code one.
//  Q3 Does `directoryURL` aim the picker, the way EXTRA_INITIAL_URI
//     does on Android and `directoryURL` does on NSOpenPanel?
//  Q4 Does the picker even come up in the simulator — is the
//     DocumentManager service present there at all?
//
// Answers land in the log under "PROBE". Not a lane; nothing builds it
// but build.sh beside it.
import UIKit
import UniformTypeIdentifiers

func say(_ s: String) {
    NSLog("PROBE %@", s)
    print("PROBE \(s)")
    fflush(stdout)
}

/// Every view under `v`, depth first, with what it would publish to an
/// accessibility client. This is the in-process read the harness would
/// have to make.
func dump(_ v: UIView, _ depth: Int = 0, into out: inout [String]) {
    if out.count > 400 { return }
    let pad = String(repeating: "  ", count: depth)
    let cls = String(describing: type(of: v))
    let label = v.accessibilityLabel ?? ""
    let ident = v.accessibilityIdentifier ?? ""
    let text = (v as? UILabel)?.text ?? ""
    if !label.isEmpty || !ident.isEmpty || !text.isEmpty || depth < 4 {
        out.append("\(pad)\(cls) label=\(label) id=\(ident) text=\(text)")
    }
    for sub in v.subviews { dump(sub, depth + 1, into: &out) }
}

/// The accessibility ELEMENT tree, which is not the view tree: a remote
/// view controller can publish elements it has no views for, so both
/// have to be asked before concluding the picker is unreadable.
func dumpElements(_ container: NSObject, _ depth: Int = 0, into out: inout [String]) {
    if out.count > 400 || depth > 6 { return }
    let pad = String(repeating: "  ", count: depth)
    let n = container.accessibilityElementCount()
    if n == NSNotFound || n == 0 {
        return
    }
    for i in 0..<n {
        guard let child = container.accessibilityElement(at: i) as? NSObject else { continue }
        let label = (child.value(forKey: "accessibilityLabel") as? String) ?? ""
        out.append("\(pad)[\(i)] \(type(of: child)) label=\(label)")
        dumpElements(child, depth + 1, into: &out)
    }
}

final class VC: UIViewController, UIDocumentPickerDelegate {
    var picker: UIDocumentPickerViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        say("==== begin, ios \(UIDevice.current.systemVersion)")

        // Q2: the candidate directories, and whether this process can
        // fill them. The app's Documents dir is the interesting one —
        // it is the only place a guest can write without a picker
        // already having granted something.
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let tmp = fm.temporaryDirectory
        say("Q2 documentDirectory=\(docs.path)")
        say("Q2 temporaryDirectory=\(tmp.path)")
        say("Q2 NSTemporaryDirectory=\(NSTemporaryDirectory())")
        say("Q2 bundle UIFileSharingEnabled=" +
            "\(Bundle.main.object(forInfoDictionaryKey: "UIFileSharingEnabled") ?? "absent")")
        say("Q2 bundle LSSupportsOpeningDocumentsInPlace=" +
            "\(Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") ?? "absent")")

        let dir = docs.appendingPathComponent("kaya-probe-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try "picked bytes".write(to: dir.appendingPathComponent("picked.txt"),
                                     atomically: true, encoding: .utf8)
            try "decoy".write(to: dir.appendingPathComponent("decoy.txt"),
                              atomically: true, encoding: .utf8)
            say("Q2 wrote the scene's two files into \(dir.lastPathComponent) OK")
        } catch {
            say("Q2 WRITE FAILED: \(error)")
        }

        // Q3/Q4: present it, aimed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.present(at: dir) }
    }

    func present(at dir: URL) {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item])
        p.delegate = self
        // Q3. NSOpenPanel honours its directoryURL only AT presentation;
        // this is the iOS spelling of the same idea, and whether it is
        // honoured at all is the question.
        p.directoryURL = dir
        p.allowsMultipleSelection = false
        picker = p
        say("Q3 presenting, aimed at \(dir.path)")
        present(p, animated: true) {
            say("Q4 presented; the picker is up")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { self.read() }
        }
    }

    /// Q1, the one that decides the arm.
    func read() {
        guard let p = picker else {
            say("Q1 no picker held")
            return
        }
        say("Q1 picker class=\(type(of: p)) child VCs=\(p.children.map { String(describing: type(of: $0)) })")
        if let v = p.viewIfLoaded {
            var out: [String] = []
            dump(v, 0, into: &out)
            say("Q1 VIEW TREE (\(out.count) rows):")
            for row in out { say("Q1   \(row)") }
        } else {
            say("Q1 the picker's view is not even loaded in this process")
        }

        var elems: [String] = []
        if let v = p.viewIfLoaded {
            dumpElements(v, 0, into: &elems)
        }
        say("Q1 ACCESSIBILITY ELEMENTS (\(elems.count) rows):")
        for row in elems { say("Q1   \(row)") }

        // The definitive framing: does ANY view in this process's window
        // carry the text of a file the picker must be showing?
        var all: [String] = []
        for w in (view.window?.windowScene?.windows ?? []) {
            dump(w, 0, into: &all)
        }
        let names = all.filter { $0.contains("picked.txt") || $0.contains("decoy.txt") }
        say("Q1 VERDICT: this process's windows carry \(all.count) views; " +
            "\(names.count) of them mention the scene's files")
        for n in names { say("Q1   \(n)") }

        // Q5: the ONE part of the picker that IS in this process — the
        // remote bar button's tracking view, which carries the label
        // "Cancel". If it can be driven, an iOS leg can at least prove
        // the request/result grammar (present, dismiss, empty list)
        // even where it cannot choose a file. If it cannot, nothing
        // about this picker is reachable from the lane.
        var cancels: [UIView] = []
        func findCancel(_ v: UIView) {
            if v.accessibilityLabel == "Cancel" { cancels.append(v) }
            for s in v.subviews { findCancel(s) }
        }
        for w in (view.window?.windowScene?.windows ?? []) { findCancel(w) }
        say("Q5 in-process views labelled Cancel: \(cancels.count) " +
            "\(cancels.map { String(describing: type(of: $0)) })")
        if let c = cancels.first {
            let ok = c.accessibilityActivate()
            say("Q5 accessibilityActivate() on it -> \(ok)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                say("Q5 picker still presented after activate: " +
                    "\(self.presentedViewController != nil)")
                say("==== end")
            }
            return
        }
        say("==== end")
    }

    func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        say("Q4 picked \(urls.map { $0.lastPathComponent })")
    }

    func documentPickerWasCancelled(_ c: UIDocumentPickerViewController) {
        say("Q4 cancelled")
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
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self))
