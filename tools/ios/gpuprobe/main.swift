// The device host for tools/ios/gpuprobe: runs the Rust probe off the main
// thread, writes its report into Documents, and shows the report as it grows.
// NOT A LANE — it needs hardware (docs/canvas-gpu-plan.md §11: the phone-class
// core is the measurement the record is owed).
import UIKit

@_silgen_name("kaya_gpuprobe_run")
func kayaGpuprobeRun(_ path: UnsafePointer<CChar>) -> Int32

final class ProbeViewController: UIViewController {
    let text = UITextView()
    var report = ""
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        text.frame = view.bounds
        text.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        text.isEditable = false
        text.font = UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        text.text = "kaya gpuprobe: running…"
        view.addSubview(text)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = docs.appendingPathComponent("gpuprobe.txt").path
        report = path
        Thread.detachNewThread {
            let rc = kayaGpuprobeRun(path)
            DispatchQueue.main.async { self.refresh(done: rc) }
            // The launcher's console attaches until the process ends, so a
            // finished probe leaves on its own a moment after its last line.
            Thread.sleep(forTimeInterval: 3)
            exit(rc)
        }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in self.refresh(done: nil) }
    }
    func refresh(done: Int32?) {
        let body = (try? String(contentsOfFile: report, encoding: .utf8)) ?? "(no report yet)"
        text.text = body + (done.map { "\n[exit \($0)]" } ?? "")
        let end = NSRange(location: max(text.text.count - 1, 0), length: 1)
        text.scrollRangeToVisible(end)
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ProbeViewController()
        window.makeKeyAndVisible()
        self.window = window
        UIApplication.shared.isIdleTimerDisabled = true
        return true
    }
}
