// A bundle-wrapped probe: can an ad-hoc, LSUIElement, accessory-policy
// bundle outside /Applications post a local notification, read it back from
// the centre's delivered list, and receive its activation? Run by hand
// (tools/mac/notifyprobe/build.sh). Prints one line per measured fact.
import AppKit
import UserNotifications

final class Delegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        print("notifyprobe: willPresent \(n.request.identifier) — presenting as a banner")
        done([.banner, .list])
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        print("notifyprobe: ACTIVATED \(r.notification.request.identifier) action=\(r.actionIdentifier)")
        done()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
print("notifyprobe: bundle id \(Bundle.main.bundleIdentifier ?? "<nil>") path \(Bundle.main.bundlePath)")
let delegate = Delegate()
let centre = UNUserNotificationCenter.current()
centre.delegate = delegate
let wait = Double(ProcessInfo.processInfo.environment["NOTIFYPROBE_WAIT"] ?? "20") ?? 20
centre.getNotificationSettings { s in
    print("notifyprobe: authorization before ask = \(s.authorizationStatus.rawValue) (0 notDetermined 1 denied 2 authorized 3 provisional)")
}
let opts: UNAuthorizationOptions = ProcessInfo.processInfo.environment["NOTIFYPROBE_PROVISIONAL"] != nil ? [.alert, .sound, .provisional] : [.alert, .sound]
    centre.requestAuthorization(options: opts) { granted, error in
    print("notifyprobe: requestAuthorization granted=\(granted) error=\(error.map { "\($0)" } ?? "none")")
    let content = UNMutableNotificationContent()
    content.title = "Call the plumber"
    content.body = "Reminder from the notify probe"
    let request = UNNotificationRequest(identifier: "kaya-task-12", content: content, trigger: nil)
    centre.add(request) { err in
        print("notifyprobe: add error=\(err.map { "\($0)" } ?? "none")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            centre.getDeliveredNotifications { delivered in
                print("notifyprobe: delivered = \(delivered.map { "\($0.request.identifier):\($0.request.content.title)" })")
            }
            centre.getPendingNotificationRequests { pending in
                print("notifyprobe: pending = \(pending.map { $0.identifier })")
            }
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
    print("notifyprobe: no activation within \(Int(wait))s — removing and exiting")
    centre.removeDeliveredNotifications(withIdentifiers: ["kaya-task-12"])
    NSApp.terminate(nil)
}
app.run()
