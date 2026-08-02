// ClipProbe — what does iOS charge for a clipboard read, and does the
// harness's seeding count as "another app"?
//
// THE QUESTION THAT DECIDES THE iOS ARM. Since iOS 16 a programmatic
// read of the pasteboard prompts the user when the content came FROM
// ANOTHER APP; reading what your own app put there does not. The
// exemptions are the system paste affordances (the Paste menu command,
// the hardware shortcut, UIPasteControl).
//
// The lane's only way to seed the clipboard from outside is
// `xcrun simctl pbcopy`. If that counts as another app — and there is
// every reason to think it does, since the whole point is that the
// content did not come from us — then the iOS paste leg has to DRIVE A
// PERMISSION PROMPT, which means tools/ios/simdrive again, exactly as
// the document picker did.
//
//  Q1 What do the PROMPT-FREE queries report for simctl-seeded content?
//     hasStrings / numberOfItems / types are documented as not
//     requiring permission, and the clipboard-offers signal in
//     docs/clipboard-plan.md depends on that being true.
//  Q2 Does reading `.string` return the content, return nil, or block?
//     A prompt would show as nil-or-slow plus an alert on screen.
//  Q3 Does reading our OWN content prompt? The plan assumes not, and
//     it decides whether a copy-then-read scene can be written without
//     any prompt driving at all.
//  Q4 What does detectPatterns report? It is the documented
//     prompt-free way to learn what is there.
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
