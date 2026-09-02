// The UI target app xcodebuild insists a UI-test bundle name: an empty
// window, never driven. The driver attaches to the lane's real guests
// by bundle id (KayaDrive.swift); this exists so the xctestrun has a
// UITargetAppPath at all, before any guest bundle is built.
import UIKit

@main
final class KayaDriveTarget: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = UIViewController()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}
