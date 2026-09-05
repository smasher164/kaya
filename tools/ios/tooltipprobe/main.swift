// TooltipProbe — does the iPad's pointer tooltip appear for SwiftUI's
// `.help`, for UIKit's `UIControl.toolTip`, for a `UIToolTipInteraction`,
// in the SIMULATOR with the pointer sent to the device? Three controls on
// one screen; the maintainer hovers each (docs/tooltip-plan.md §6).
// THROWAWAY; nothing builds it but build.sh beside it.
import SwiftUI
import UIKit

func say(_ s: String) {
    NSLog("PROBE %@", s)
    print("PROBE \(s)")
    fflush(stdout)
}

struct Helped: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Button("3. SwiftUI Button with .help") {}
                .buttonStyle(.bordered)
                .help("SwiftUI .help — the bubble the plan expected")
            Text("4. SwiftUI Text with .help")
                .help("SwiftUI .help on a Text")
        }
    }
}

final class Root: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 32
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 40),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
        ])
        let title = UILabel()
        title.text = "TooltipProbe — hover each with the pointer sent to the device"
        title.font = .preferredFont(forTextStyle: .title2)
        stack.addArrangedSubview(title)

        // 1. UIKit's own property (UIControl.toolTip, iPadOS 15+).
        let b = UIButton(type: .system)
        b.setTitle("1. UIButton with UIControl.toolTip", for: .normal)
        b.toolTip = "UIControl.toolTip — UIKit's own bubble"
        stack.addArrangedSubview(b)

        // 2. The interaction on a plain view.
        let l = UILabel()
        l.text = "2. UILabel with UIToolTipInteraction"
        l.isUserInteractionEnabled = true
        l.addInteraction(UIToolTipInteraction(defaultToolTip: "UIToolTipInteraction — UIKit's interaction on a label"))
        stack.addArrangedSubview(l)

        // 3 + 4. SwiftUI hosted.
        let host = UIHostingController(rootView: Helped())
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(host.view)
        host.didMove(toParent: self)

        say("ready: hover 1, 2, 3, 4 — pointer support: \(UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "not a pad")")
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = Root()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
