// PickerProbe — what the harness can SEE and DO to the iOS document
// picker, measured in the SIMULATOR, which is where the lane runs. NOT
// tools/ios/scopeprobe's question: that one needs HARDWARE, because the
// simulator enforces no sandbox (docs/traps.md).
//
// The deciding question, since iOS has no accessibility-service escape
// hatch: is UIDocumentPickerViewController's content REACHABLE
// IN-PROCESS? Cells and answers: docs/file-dialogs-plan.md §6e and
// docs/traps.md; the Q-labels are in the log lines below.
// THROWAWAY; nothing builds it but build.sh beside it.
import UIKit
import UniformTypeIdentifiers

/// Which shape of the question this run asks: single and multi selection
/// are different interactions (docs/traps.md).
///
/// From the ENVIRONMENT, because `simctl launch --args` reaches the app
/// as argv while SIMCTL_CHILD_* reaches it as the environment, and the
/// lane already speaks the latter.
let variant = ProcessInfo.processInfo.environment["KAYA_PROBE_VARIANT"] ?? "single"

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

        say("==== begin, ios \(UIDevice.current.systemVersion), variant \(variant)")

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
        // A VARIANT rather than an assumption: with many, a tap SELECTS
        // rather than answering and a confirm button appears.
        p.allowsMultipleSelection = (variant == "multi")
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
        // remote bar button's tracking view, labelled "Cancel". If it
        // can be driven, an iOS leg can at least prove the
        // request/result grammar without choosing a file.
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
