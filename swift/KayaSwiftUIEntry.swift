// C entry point for the SwiftUI backend: a process owned by any language calls
// kaya_swiftui_run(api) on its main thread, exactly like kaya_run. The host
// passes its presentation-side functions explicitly (see KayaHost) instead of
// relying on dynamic-linker symbol resolution.

import SwiftUI
import UserNotifications

struct KayaApp: App {
    #if os(macOS)
    // Selftest runs drive widgets by direct calls, never real input: staying an
    // accessory keeps a suite's windows from stealing the human's keyboard.
    @NSApplicationDelegateAdaptor(KayaAppDelegate.self) var delegate
    #else
    // The catalog's regular-width home: the system menu bar, which only a
    // UIResponder in the chain can populate.
    @UIApplicationDelegateAdaptor(KayaUIAppDelegate.self) var delegate
    #endif
    var body: some Scene {
        WindowGroup {
            #if os(macOS)
                KayaRoot()
            #else
                // iOS IS THE OPPOSITE OF macOS (docs/traps.md, 2026-09-09):
                // `.onOpenURL` is the ONLY door that fires here —
                // `launchOptions[.url]` is always empty and
                // `application(_:open:options:)` never runs — and a link
                // reuses the one scene rather than building a second.
                KayaRoot().onOpenURL { KayaHost.linkOpened($0.absoluteString) }
            #endif
        }
        // Auxiliary surfaces: data-driven windows keyed by the kaya window id.
        // Never opened by the system — only the mount arm presents one; phones
        // never get here (the core rejects create_window without the capability).
        WindowGroup(for: UInt64.self) { $windowId in
            if let windowId {
                KayaAuxRoot(windowId: windowId)
            }
        }
    }
}

#if os(macOS)
final class KayaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // KAYA_ACTIVATE=1 makes the app REGULAR — EXPLICITLY, since an unbundled
        // binary with no policy set defaults to PROHIBITED (measured: policy=2,
        // no activation, a partly unpublished AX tree). The lanes never set it,
        // so suite runs stay accessory and steal nobody's keyboard.
        if ProcessInfo.processInfo.environment["KAYA_ACTIVATE"] != nil {
            NSApplication.shared.setActivationPolicy(.regular)
        } else if ProcessInfo.processInfo.environment["KAYA_SELFTEST"] != nil {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        // BEFORE ANY WINDOW EXISTS, so every one of them inherits it and no
        // first frame is drawn in the host's mode (tools/check-appearance.py).
        kayaApplyAppearance()
        // The notification centre's delegate, before launching finishes, so
        // a launch caused by a tap is delivered (docs/tasks-s3-plan.md §3).
        if kayaCanPostNotifications() {
            UNUserNotificationCenter.current().delegate = kayaNotificationDelegate
        }
        // THE CARVE-OUT DOOR (docs/tasks-s9-plan.md R6a): no programmatic
        // tap exists here, so the runner starts the bundle again naming
        // the notification and this enters the delegate's own funnel.
        kayaDeliverLaunchNotification()
    }

    /// THE COLD LINK DOOR (docs/app-links-plan.md §4). A process
    /// LaunchServices starts to OPEN A URL takes this path, and it must:
    /// the raw kAEGetURL handler below is installed only once launching
    /// has FINISHED, because a handler installed in
    /// `applicationWillFinishLaunching` swallows the launch event and
    /// SwiftUI's WindowGroup then opens NO WINDOW AT ALL — no root, no
    /// interpreter pump, no harness, the app thread building its scene
    /// into a window nobody ever draws (measured 2026-09-09, both halves
    /// watched). `.onOpenURL` is not the answer either: it opens a second
    /// window per link (docs/traps.md).
    func application(_ application: NSApplication, open urls: [URL]) {
        kayaDiag("link deleg urls=\(urls.map { $0.absoluteString })")
        for url in urls { KayaHost.linkOpened(url.absoluteString) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // THE WARM LINK DOOR, INSTALLED HERE AND NOT EARLIER (see the
        // arm above): from now on a link reaching this running process is
        // taken before AppKit converts it, so no window is added for it.
        kayaInstallLinkDoor()
        // PIXEL-PROOF RUNS ONLY (KAYA_ACTIVATE=1): AppKit renders an inactive
        // app's chrome grey, and macOS 14's cooperative activation ignores
        // another process's activate call, so the app must ask for itself.
        // Never set by the lanes — that is the accessory rule above.
        if ProcessInfo.processInfo.environment["KAYA_ACTIVATE"] != nil {
            NSApplication.shared.activate()
        }
    }
}
#else
/// Subclasses UIResponder, NOT NSObject: `buildMenu(with:)` is a UIResponder
/// method, and a delegate that only conforms to UIApplicationDelegate is never
/// asked to build menus.
final class KayaUIAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = kayaNotificationDelegate
        // The macOS arm's door, one platform over (docs/tasks-s9-plan.md
        // R6a): the simulator's shade activates nothing, so the runner
        // starts the app again naming the notification.
        kayaDeliverLaunchNotification()
        return true
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        // Only the main system carries a bar; context menu systems reach this
        // same responder and must be left alone.
        guard builder.system == .main else { return }
        kayaBuildCatalogMenus(builder)
    }
}
#endif

@_cdecl("kaya_swiftui_run")
public func kayaSwiftUIRun(_ api: UnsafePointer<KayaHostApi>) -> Int32 {
    KayaHost.api = api.pointee
    // The runtime capability this host measured (docs/tasks-s3-plan.md N6),
    // granted before the guest's first read.
    let host = KayaHost.api.spec_hash()
    if host != kayaSpecHash {
        fatalError(
            "kaya: stale SwiftUI interpreter dylib — its spec hash "
                + String(format: "%016llx", kayaSpecHash)
                + " does not match the host core's "
                + String(format: "%016llx", host)
                + "; rebuild it (tools/swiftui/build-dylib.sh)")
    }
    KayaApp.main() // takes over the calling (main) thread; does not return
    return 0
}

