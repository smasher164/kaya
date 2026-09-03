// NoteSource — the FOREIGN drag source that registers kaya's own
// vocabulary. The stock Files app can only offer what Files offers
// (`public.plain-text` and a private FINode type), so it cannot answer
// two of probe 5's questions: does a MIME-shaped custom id survive a
// CROSS-PROCESS drag, and does a foreign drop of TEXT reach a receiver
// that accepts exactly kaya's types.
//
// A separate bundle, therefore a separate principal — which is the whole
// point: `session.localDragSession` is nil on the receiving side.
//
// THROWAWAY; nothing builds it but build.sh beside it.
import UIKit

let kNote = "dev.kaya/note"
let kText = "public.utf8-plain-text"

func say(_ s: String) {
    NSLog("NOTESOURCE %@", s)
    print("NOTESOURCE \(s)")
    fflush(stdout)
}

final class Chip: UILabel, UIDragInteractionDelegate {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        addInteraction(UIDragInteraction(delegate: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    func dragInteraction(_ i: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        let p = NSItemProvider()
        p.suggestedName = "foreign.txt"
        p.registerDataRepresentation(forTypeIdentifier: kText, visibility: .all) { done in
            done(Data("kaya-foreign-text-payload".utf8), nil); return nil
        }
        p.registerDataRepresentation(forTypeIdentifier: kNote, visibility: .all) { done in
            done(Data("{\"note\":\"kaya-foreign-note\",\"from\":\"notesource\"}".utf8), nil); return nil
        }
        say("itemsForBeginning: types=[\(kText), \(kNote)]")
        return [UIDragItem(itemProvider: p)]
    }

    func dragInteraction(_ i: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
        say("session ended operation=\(operation.rawValue)")
    }
}

final class VC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemIndigo.withAlphaComponent(0.2)
        let chip = Chip()
        chip.text = " FOREIGN NOTE "
        chip.accessibilityIdentifier = "foreignchip"
        chip.accessibilityLabel = "FOREIGN NOTE"
        chip.isAccessibilityElement = true
        chip.backgroundColor = .systemIndigo
        chip.textColor = .white
        chip.font = .systemFont(ofSize: 22, weight: .bold)
        chip.textAlignment = .center
        chip.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chip)
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            chip.centerXAnchor.constraint(equalTo: g.centerXAnchor),
            chip.topAnchor.constraint(equalTo: g.topAnchor, constant: 40),
            chip.widthAnchor.constraint(equalToConstant: 220),
            chip.heightAnchor.constraint(equalToConstant: 64)])
        say("READY bundle=\(Bundle.main.bundleIdentifier ?? "-")")
        // A background app is suspended and answers no drag; a repeating
        // timer is the cheapest way to keep this one live for the probe.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            say("alive state=\(UIApplication.shared.applicationState.rawValue)")
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
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self))
