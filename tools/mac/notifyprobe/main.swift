// A bundle-wrapped probe: can an ad-hoc, LSUIElement, accessory-policy
// bundle outside /Applications post a local notification, read it back from
// the centre's delivered list, and receive its activation? Run by hand
// (tools/mac/notifyprobe/build.sh). Prints one line per measured fact.
//
// S9's question (docs/tasks-s9-plan.md §2.1) needs one more mode: does the
// OS RELAUNCH a terminated bundle for a tap, and does `didReceive` carry
// the identifier in the process it started? NOTIFYPROBE_EXIT_AFTER_POST
// posts and leaves at once, and NOTIFYPROBE_LOG names a file every launch
// appends to — a relaunched instance has no terminal to print to.
import AppKit
import UserNotifications

// DEFAULTED, not env-only: the process the OS relaunches for a tap
// inherits NOTHING, so a log named only in the environment would be
// written by the first launch and by no other.
let probeLog = ProcessInfo.processInfo.environment["NOTIFYPROBE_LOG"]
    ?? "/tmp/notifyprobe.log"

func note(_ text: String) {
    let line = "[pid \(getpid())] \(text)"
    print("notifyprobe: " + line)
    let stamped = "\(Date().timeIntervalSince1970) \(line)\n"
    if let handle = FileHandle(forWritingAtPath: probeLog) {
        handle.seekToEndOfFile()
        handle.write(Data(stamped.utf8))
        try? handle.close()
    } else {
        try? stamped.write(toFile: probeLog, atomically: true, encoding: .utf8)
    }
}

final class Delegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        print("notifyprobe: willPresent \(n.request.identifier) — presenting as a banner")
        done([.banner, .list])
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        note("ACTIVATED \(r.notification.request.identifier) action=\(r.actionIdentifier)")
        done()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
note("launched, bundle id \(Bundle.main.bundleIdentifier ?? "<nil>") path \(Bundle.main.bundlePath)")
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
        note("add error=\(err.map { "\($0)" } ?? "none")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            centre.getDeliveredNotifications { delivered in
                note("delivered = \(delivered.map { "\($0.request.identifier):\($0.request.content.title)" })")
                // S9 §2.1: leave with the notification STILL DELIVERED, so
                // the tap has a terminated app to relaunch.
                if ProcessInfo.processInfo.environment["NOTIFYPROBE_EXIT_AFTER_POST"] != nil {
                    note("posted and exiting; the notification stays in the centre")
                    NSApp.terminate(nil)
                }
            }
            centre.getPendingNotificationRequests { pending in
                note("pending = \(pending.map { $0.identifier })")
            }
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
    note("no activation within \(Int(wait))s — removing and exiting")
    centre.removeDeliveredNotifications(withIdentifiers: ["kaya-task-12"])
    NSApp.terminate(nil)
}
app.run()
