// DragProbe — docs/dnd-plan.md §2 probe 5, measured in the SIMULATOR.
//
// THE QUESTION: does a drop FROM ANOTHER APP into a kaya-shaped receiver
// raise the iOS 16 paste prompt ("<app> would like to paste from
// <other>")? The plan reasons no (the user's own drag gesture is the
// consent) and had not measured it.
//
// The measurement needs a POSITIVE CONTROL on the same device, in the
// same process, in the same minute — otherwise "no prompt appeared"
// cannot be told from "nothing happened". So this probe carries a
// `paste` button that reads UIPasteboard.general, which is the read that
// DOES prompt when the board's last writer was another principal.
//
// Q1 canHandle       what the session offers before any verdict
// Q2 sessionDidUpdate the proposal, the location, allowsMoveOperation
// Q3 performDrop     the item providers and their registered types
// Q4 load-in-callback   loadDataRepresentation started INSIDE performDrop
// Q5 load-after-return  the SAME provider, started 3s AFTER it returned
//                        (D6's premise: is the coordinated read confined
//                         to the callback?)
// Q6 file lifetime   does loadFileRepresentation's URL survive its own
//                    completion handler?
// Q7 paste control   the prompt, on the route that is known to raise it
//
// THROWAWAY; nothing builds it but build.sh beside it.
import UIKit
import UniformTypeIdentifiers

let kNote = "dev.kaya/note"
let kText = "public.utf8-plain-text"

let logURL: URL = {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    return dir.appendingPathComponent("dragprobe.log")
}()

let logQueue = DispatchQueue(label: "dev.kaya.dragprobe.log")

func say(_ s: String) {
    let line = "DRAGPROBE \(String(format: "%.3f", Date().timeIntervalSince1970)) \(s)"
    NSLog("%@", line)
    print(line)
    fflush(stdout)
    logQueue.sync {
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(Data((line + "\n").utf8))
            try? h.close()
        } else {
            try? Data((line + "\n").utf8).write(to: logURL)
        }
    }
}

/// Everything a session will say about itself before the app has taken
/// any position on it. `canLoadObjects` is asked for the two classes a
/// kaya receiver would ever ask for.
func describe(_ tag: String, _ session: UIDropSession) -> String {
    var parts: [String] = []
    parts.append("items=\(session.items.count)")
    parts.append("local=\(session.localDragSession != nil)")
    parts.append("canLoadNSString=\(session.canLoadObjects(ofClass: NSString.self))")
    parts.append("canLoadNSURL=\(session.canLoadObjects(ofClass: NSURL.self))")
    parts.append("canLoadUIImage=\(session.canLoadObjects(ofClass: UIImage.self))")
    parts.append("hasText=\(session.hasItemsConforming(toTypeIdentifiers: [kText]))")
    parts.append("hasNote=\(session.hasItemsConforming(toTypeIdentifiers: [kNote]))")
    parts.append("hasFileURL=\(session.hasItemsConforming(toTypeIdentifiers: ["public.file-url"]))")
    parts.append("allowsMove=\(session.allowsMoveOperation)")
    parts.append("restrictedToDraggingApplication=\(session.isRestrictedToDraggingApplication)")
    for (i, item) in session.items.enumerated() {
        let p = item.itemProvider
        parts.append("item[\(i)].types=\(p.registeredTypeIdentifiers)")
        parts.append("item[\(i)].suggestedName=\(p.suggestedName ?? "-")")
        parts.append("item[\(i)].localObject=\(item.localObject.map { "\($0)" } ?? "-")")
    }
    return "\(tag) \(parts.joined(separator: " "))"
}

/// A drop destination. `wide` accepts anything the platform offers,
/// which is what a FILE drop needs; the strict one accepts exactly the
/// kaya-shaped vocabulary the plan names.
final class DropView: UIView, UIDropInteractionDelegate {
    let tag_: String
    let wide: Bool
    var status: ((String) -> Void)?
    /// Kept ALIVE past performDrop on purpose (Q5).
    var stashed: [NSItemProvider] = []

    init(tag: String, wide: Bool) {
        self.tag_ = tag
        self.wide = wide
        super.init(frame: .zero)
        addInteraction(UIDropInteraction(delegate: self))
        isUserInteractionEnabled = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private var accepted: [String] { wide ? ["public.item"] : [kText, kNote] }

    func dropInteraction(_ i: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        say(describe("Q1 \(tag_) canHandle", session))
        return true
    }

    func dropInteraction(_ i: UIDropInteraction, sessionDidEnter session: UIDropSession) {
        say("Q2a \(tag_) sessionDidEnter")
        backgroundColor = UIColor.systemYellow
    }

    func dropInteraction(_ i: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        let ok = session.hasItemsConforming(toTypeIdentifiers: accepted)
        let op: UIDropOperation = ok ? .copy : .forbidden
        let p = session.location(in: self)
        say("Q2 \(tag_) sessionDidUpdate at=(\(Int(p.x)),\(Int(p.y))) accepted=\(accepted) match=\(ok) proposal=\(op.rawValue) local=\(session.localDragSession != nil)")
        return UIDropProposal(operation: op)
    }

    func dropInteraction(_ i: UIDropInteraction, sessionDidExit session: UIDropSession) {
        say("Q2b \(tag_) sessionDidExit")
        backgroundColor = wide ? UIColor.systemBlue.withAlphaComponent(0.25)
                               : UIColor.systemGreen.withAlphaComponent(0.25)
    }

    func dropInteraction(_ i: UIDropInteraction, performDrop session: UIDropSession) {
        say(describe("Q3 \(tag_) performDrop", session))
        status?("\(tag_): DROP items=\(session.items.count)")
        backgroundColor = UIColor.systemPurple.withAlphaComponent(0.5)
        for (idx, item) in session.items.enumerated() {
            let p = item.itemProvider
            stashed.append(p)
            for t in p.registeredTypeIdentifiers {
                // Q4: the read STARTED INSIDE the callback.
                p.loadDataRepresentation(forTypeIdentifier: t) { data, err in
                    say("Q4 \(self.tag_) in-callback loadData item=\(idx) type=\(t) bytes=\(data?.count ?? -1) err=\(err.map { "\($0)" } ?? "-") head=\(DropView.head(data))")
                }
            }
            // Q6: a file representation, and whether its URL outlives the
            // completion handler it was handed in.
            if p.hasItemConformingToTypeIdentifier("public.item") {
                p.loadFileRepresentation(forTypeIdentifier: "public.item") { url, err in
                    guard let url else {
                        say("Q6 \(self.tag_) loadFileRepresentation item=\(idx) url=nil err=\(err.map { "\($0)" } ?? "-")")
                        return
                    }
                    let inside = FileManager.default.fileExists(atPath: url.path)
                    let bytes = (try? Data(contentsOf: url))?.count ?? -1
                    say("Q6 \(self.tag_) loadFileRepresentation item=\(idx) url=\(url.path) existsInCallback=\(inside) bytesInCallback=\(bytes)")
                    let path = url.path
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        let after = FileManager.default.fileExists(atPath: path)
                        let b2 = (try? Data(contentsOf: URL(fileURLWithPath: path)))?.count ?? -1
                        say("Q6b \(self.tag_) 3s after the completion returned: exists=\(after) bytes=\(b2) path=\(path)")
                    }
                }
            }
        }
        // Q5: the SAME providers, read 3 seconds after performDrop returned.
        let providers = session.items.map { $0.itemProvider }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for (idx, p) in providers.enumerated() {
                for t in p.registeredTypeIdentifiers {
                    p.loadDataRepresentation(forTypeIdentifier: t) { data, err in
                        say("Q5 \(self.tag_) deferred loadData item=\(idx) type=\(t) bytes=\(data?.count ?? -1) err=\(err.map { "\($0)" } ?? "-") head=\(DropView.head(data))")
                    }
                }
                if p.hasItemConformingToTypeIdentifier("public.item") {
                    p.loadFileRepresentation(forTypeIdentifier: "public.item") { url, err in
                        say("Q5b \(self.tag_) deferred loadFileRepresentation item=\(idx) url=\(url?.path ?? "nil") err=\(err.map { "\($0)" } ?? "-") bytes=\((url.flatMap { try? Data(contentsOf: $0) })?.count ?? -1)")
                    }
                }
            }
        }
    }

    func dropInteraction(_ i: UIDropInteraction, concludeDrop session: UIDropSession) {
        say("Q3b \(tag_) concludeDrop")
    }

    func dropInteraction(_ i: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        say("Q3c \(tag_) sessionDidEnd local=\(session.localDragSession != nil)")
    }

    static func head(_ d: Data?) -> String {
        guard let d else { return "-" }
        let s = String(decoding: d.prefix(48), as: UTF8.self)
        return "\"" + s.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

/// The same-app source: one item carrying both representations, so a
/// local drag exercises the same receiver the foreign one does.
final class DragChip: UILabel, UIDragInteractionDelegate {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        addInteraction(UIDragInteraction(delegate: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    func dragInteraction(_ i: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        let payload = "kaya-local-note"
        let p = NSItemProvider()
        p.suggestedName = "local.txt"
        p.registerDataRepresentation(forTypeIdentifier: kText, visibility: .all) { done in
            done(Data(payload.utf8), nil); return nil
        }
        p.registerDataRepresentation(forTypeIdentifier: kNote, visibility: .all) { done in
            done(Data("{\"note\":\"\(payload)\"}".utf8), nil); return nil
        }
        say("Q0 itemsForBeginning: one item, types=[\(kText), \(kNote)]")
        let item = UIDragItem(itemProvider: p)
        item.localObject = "chip"
        return [item]
    }

    func dragInteraction(_ i: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
        say("Q0b drag session ended operation=\(operation.rawValue)")
    }
}

final class VC: UIViewController {
    let statusLabel = UILabel()
    let strict = DropView(tag: "strict", wide: false)
    let wide = DropView(tag: "wide", wide: true)
    let chip = DragChip()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white

        statusLabel.numberOfLines = 3
        statusLabel.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)
        statusLabel.text = "dragprobe ready"
        statusLabel.textAlignment = .center
        statusLabel.backgroundColor = UIColor.systemGray6
        statusLabel.accessibilityIdentifier = "status"

        strict.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.25)
        wide.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.25)
        strict.accessibilityIdentifier = "strictdrop"
        wide.accessibilityIdentifier = "widedrop"
        strict.isAccessibilityElement = true
        wide.isAccessibilityElement = true
        strict.accessibilityLabel = "STRICT DROP"
        wide.accessibilityLabel = "WIDE DROP"
        strict.status = { [weak self] s in self?.statusLabel.text = s }
        wide.status = { [weak self] s in self?.statusLabel.text = s }

        for (v, text) in [(strict, "STRICT DROP\nutf8-plain-text + dev.kaya/note"),
                          (wide, "WIDE DROP\npublic.item")] {
            let l = UILabel()
            l.text = text
            l.numberOfLines = 2
            l.textAlignment = .center
            l.font = .systemFont(ofSize: 20, weight: .bold)
            l.translatesAutoresizingMaskIntoConstraints = false
            l.isUserInteractionEnabled = false
            v.addSubview(l)
            NSLayoutConstraint.activate([
                l.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                l.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        }

        chip.text = " DRAG ME "
        chip.accessibilityIdentifier = "chip"
        chip.accessibilityLabel = "DRAG ME"
        chip.isAccessibilityElement = true
        chip.backgroundColor = UIColor.systemOrange
        chip.font = .systemFont(ofSize: 20, weight: .bold)
        chip.textAlignment = .center

        let paste = UIButton(type: .system)
        paste.setTitle("PASTE", for: .normal)
        paste.accessibilityIdentifier = "paste"
        paste.titleLabel?.font = .systemFont(ofSize: 20, weight: .bold)
        paste.backgroundColor = UIColor.systemRed.withAlphaComponent(0.25)
        paste.addTarget(self, action: #selector(doPaste), for: .touchUpInside)

        let types = UIButton(type: .system)
        types.setTitle("TYPES", for: .normal)
        types.accessibilityIdentifier = "types"
        types.titleLabel?.font = .systemFont(ofSize: 20, weight: .bold)
        types.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.25)
        types.addTarget(self, action: #selector(doTypes), for: .touchUpInside)

        for v in [statusLabel, strict, wide, chip, paste, types] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: g.topAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor),
            statusLabel.heightAnchor.constraint(equalToConstant: 70),

            strict.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            strict.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 8),
            strict.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -8),
            strict.heightAnchor.constraint(equalTo: g.heightAnchor, multiplier: 0.30),

            wide.topAnchor.constraint(equalTo: strict.bottomAnchor, constant: 8),
            wide.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 8),
            wide.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -8),
            wide.heightAnchor.constraint(equalTo: g.heightAnchor, multiplier: 0.30),

            chip.topAnchor.constraint(equalTo: wide.bottomAnchor, constant: 12),
            chip.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 8),
            chip.heightAnchor.constraint(equalToConstant: 56),
            chip.widthAnchor.constraint(equalToConstant: 160),

            paste.topAnchor.constraint(equalTo: chip.topAnchor),
            paste.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 12),
            paste.heightAnchor.constraint(equalToConstant: 56),
            paste.widthAnchor.constraint(equalToConstant: 140),

            types.topAnchor.constraint(equalTo: chip.topAnchor),
            types.leadingAnchor.constraint(equalTo: paste.trailingAnchor, constant: 12),
            types.heightAnchor.constraint(equalToConstant: 56),
            types.widthAnchor.constraint(equalToConstant: 140)])

        say("READY bundle=\(Bundle.main.bundleIdentifier ?? "-") log=\(logURL.path)")
        seedDocuments()
        watchSceneState()
    }

    /// Is this app even ELIGIBLE for a drop? A drag hovering over a
    /// window whose scene is in the background is never offered to that
    /// app's drop interactions, and the app logs NOTHING — which is
    /// indistinguishable from a broken delegate. So the state is on the
    /// record beside every drag.
    func watchSceneState() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let scenes = UIApplication.shared.connectedScenes.map {
                "\(type(of: $0)):\($0.activationState.rawValue)"
            }
            say("STATE app=\(UIApplication.shared.applicationState.rawValue) scenes=\(scenes)")
        }
        for (name, n) in [("didActivate", UIScene.didActivateNotification),
                          ("willDeactivate", UIScene.willDeactivateNotification),
                          ("didEnterBackground", UIScene.didEnterBackgroundNotification),
                          ("willEnterForeground", UIScene.willEnterForegroundNotification)] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in
                say("SCENE \(name)")
            }
        }
    }

    /// A file in this app's Documents, which UIFileSharingEnabled makes
    /// browsable from the stock Files app — the foreign FILE drag source.
    func seedDocuments() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let f = dir.appendingPathComponent("dragsource.txt")
        try? Data("kaya-foreign-file-payload\n".utf8).write(to: f)
        say("SEED \(f.path) bytes=\((try? Data(contentsOf: f))?.count ?? -1)")
    }

    /// Q7, the positive control: the read that is KNOWN to raise the
    /// iOS 16 prompt when the board's last writer was another principal.
    @objc func doPaste() {
        let before = UIPasteboard.general.changeCount
        say("Q7 paste: asking UIPasteboard.general.string (changeCount=\(before))")
        statusLabel.text = "PASTE asked"
        DispatchQueue.global().async {
            let s = UIPasteboard.general.string
            DispatchQueue.main.async {
                say("Q7 paste returned: \(s.map { "\"\($0)\"" } ?? "nil")")
                self.statusLabel.text = "PASTE -> \(s ?? "nil")"
            }
        }
    }

    @objc func doTypes() {
        say("TYPES \(UIPasteboard.general.types) changeCount=\(UIPasteboard.general.changeCount)")
        statusLabel.text = "TYPES \(UIPasteboard.general.types.count)"
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
