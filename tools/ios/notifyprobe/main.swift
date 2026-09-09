// The iOS half of tools/mac/notifyprobe, and the same three questions with no
// cargo in the way (docs/tasks-s3-plan.md §7's iOS row): does PROVISIONAL
// authorization grant on the simulator with no prompt, does the centre's
// delivered list read a foreground post back, and does a REAL tap on
// SpringBoard's shade reach the delegate's didReceive? Built and driven by
// hand — tools/ios/notifyprobe/build.sh, then the xcui driver's notify_tap.
// One line per measured fact, on stdout, which `simctl launch --console-pty`
// carries.
//
// S9's question (docs/tasks-s9-plan.md §2.1) adds one more mode: does a
// notification that FIRES while the app is terminated show a banner, and
// does a tap on that banner relaunch the app and deliver the identifier?
// NOTIFYPROBE_AT_SECONDS schedules instead of posting now, and
// NOTIFYPROBE_EXIT_AFTER_POST leaves at once so the fire finds no process.
// The log's path is DEFAULTED, never env-only: the process the system
// relaunches inherits nothing, so a log named in the environment would be
// written by the first launch and by no other.
import Darwin
import UIKit
import UserNotifications

let probeLog = NSHomeDirectory() + "/Documents/notifyprobe.log"

final class ProbeDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?
    let label = UILabel()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        let w = UIWindow(frame: UIScreen.main.bounds)
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground
        label.frame = vc.view.bounds
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = "notifyprobe"
        label.accessibilityIdentifier = "notifyprobe-status"
        vc.view.addSubview(label)
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
        measure()
        return true
    }

    func say(_ what: String) {
        let line = "[pid \(getpid())] \(what)"
        print("notifyprobe: " + line)
        fflush(stdout)
        let stamped = "\(Date().timeIntervalSince1970) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: probeLog) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? stamped.write(toFile: probeLog, atomically: true, encoding: .utf8)
        }
    }

    func measure() {
        let centre = UNUserNotificationCenter.current()
        say("bundle id \(Bundle.main.bundleIdentifier ?? "<nil>")")
        centre.getNotificationSettings { s in
            self.say("authorization before ask = \(s.authorizationStatus.rawValue) "
                + "(0 notDetermined 1 denied 2 authorized 3 provisional)")
            let provisional = ProcessInfo.processInfo.environment["NOTIFYPROBE_PROVISIONAL"] != nil
            let opts: UNAuthorizationOptions =
                provisional ? [.alert, .sound, .provisional] : [.alert, .sound]
            let asked = Date()
            centre.requestAuthorization(options: opts) { granted, error in
                self.say(String(format: "requestAuthorization(provisional=%@) granted=%@ "
                    + "error=%@ answered in %.2fs",
                    "\(provisional)", "\(granted)",
                    error.map { "\($0)" } ?? "none", Date().timeIntervalSince(asked)))
                centre.getNotificationSettings { after in
                    self.say("authorization after ask = \(after.authorizationStatus.rawValue), "
                        + "alertSetting=\(after.alertSetting.rawValue) "
                        + "notificationCenterSetting=\(after.notificationCenterSetting.rawValue)")
                    self.post()
                }
            }
        }
    }

    func post() {
        let centre = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Call the plumber"
        content.body = "Reminder from the notify probe"
        // S9 §2.1: a FUTURE instant, so the fire finds no process at all.
        var trigger: UNNotificationTrigger? = nil
        if let at = ProcessInfo.processInfo.environment["NOTIFYPROBE_AT_SECONDS"],
            let seconds = Double(at), seconds > 0
        {
            trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: seconds, repeats: false)
            say("scheduled \(seconds)s out, not posted now")
        }
        let request = UNNotificationRequest(
            identifier: "kaya-12", content: content, trigger: trigger)
        let posted = Date()
        centre.add(request) { err in
            self.say(String(format: "add error=%@ in %.2fs",
                            err.map { "\($0)" } ?? "none", Date().timeIntervalSince(posted)))
            if ProcessInfo.processInfo.environment["NOTIFYPROBE_EXIT_AFTER_POST"] != nil {
                self.say("posted and exiting; the fire must find no process")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.readBack(0) }
        }
    }

    /// The delivered list, read up to five times a second apart: a foreground
    /// post reaches the list only through the delegate's willPresent, and how
    /// long that takes is the number the harness's expect_notification lives on.
    func readBack(_ round: Int) {
        let centre = UNUserNotificationCenter.current()
        centre.getDeliveredNotifications { delivered in
            let titles = delivered.map { "\($0.request.identifier):\($0.request.content.title)" }
            self.say("round \(round): delivered = \(titles)")
            DispatchQueue.main.async {
                self.label.text = "delivered \(titles.count)"
                if round < 4 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.readBack(round + 1)
                    }
                }
            }
        }
    }

    func userNotificationCenter(
        _ centre: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        say("willPresent \(notification.request.identifier) — asking for a banner and the list")
        done([.banner, .list])
    }

    func userNotificationCenter(
        _ centre: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler done: @escaping () -> Void
    ) {
        say("ACTIVATED \(response.notification.request.identifier) "
            + "action=\(response.actionIdentifier)")
        DispatchQueue.main.async { self.label.text = "activated" }
        done()
    }
}

UIApplicationMain(
    CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ProbeDelegate.self))
