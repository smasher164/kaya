// ClipProbe — what does iOS charge for a clipboard read, and does the
// harness's seeding count as "another app"?
//
// THE QUESTION THAT DECIDES THE iOS ARM: since iOS 16 a programmatic
// read of the pasteboard prompts when the content came FROM ANOTHER APP,
// and the lane's only way to seed from outside is `xcrun simctl pbcopy`.
// If that counts as another app, the paste leg has to DRIVE A PERMISSION
// PROMPT — tools/ios/simdrive again, as with the document picker. The
// questions and their answers are docs/clipboard-plan.md; the Q-labels
// below mark which reading is which.
//
// Answers land on stdout under "PROBE". Not a lane; nothing builds it
// but build.sh beside it.
import UIKit
import UniformTypeIdentifiers

func say(_ s: String) {
    NSLog("PROBE %@", s)
    print("PROBE \(s)")
    fflush(stdout)
}

/// Wall time around a call, because "prompted" shows up as a read that
/// takes human time or never answers, not as an error.
func timed<T>(_ label: String, _ body: () -> T) -> T {
    let t0 = Date()
    let out = body()
    say("\(label) took \(Int(Date().timeIntervalSince(t0) * 1000))ms")
    return out
}

final class VC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        say("==== begin, ios \(UIDevice.current.systemVersion)")

        let pb = UIPasteboard.general

        // Q1: the queries that should cost nothing.
        say("Q1 numberOfItems=\(pb.numberOfItems)")
        say("Q1 hasStrings=\(pb.hasStrings) hasURLs=\(pb.hasURLs) hasImages=\(pb.hasImages)")
        say("Q1 types=\(pb.types)")

        // Q4: the documented prompt-free detection.
        pb.detectPatterns(for: [.probableWebURL, .number]) { result in
            switch result {
            case .success(let found): say("Q4 detectPatterns -> \(found)")
            case .failure(let err): say("Q4 detectPatterns FAILED: \(err)")
            }
        }

        // TWO RUNS, because they are mutually exclusive: writing our
        // own content DESTROYS the foreign seed, and reading the
        // foreign one blocks on a prompt that never lets the second
        // half run. KAYA_CLIPPROBE_MODE picks which question is asked.
        let mode = ProcessInfo.processInfo.environment["KAYA_CLIPPROBE_MODE"] ?? "foreign"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if mode == "own" {
                // Q3: our own content, which the plan assumes is free.
                // If it is, a copy-then-read scene needs no prompt
                // driving at all.
                pb.string = "kaya-own-content"
                let mine = timed("Q3 read of OUR OWN content") { pb.string }
                say("Q3 own .string -> \(mine.map { "\"\($0)\"" } ?? "nil")")
                say("Q3 numberOfItems now \(pb.numberOfItems), types \(pb.types)")
            } else {
                // Q2: content seeded by simctl before launch, so NOT
                // ours. A prompt shows up here as a read that never
                // returns.
                let got = timed("Q2 read of FOREIGN content") { pb.string }
                say("Q2 foreign .string -> \(got.map { "\"\($0)\"" } ?? "nil")")
            }
            say("==== end")
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
