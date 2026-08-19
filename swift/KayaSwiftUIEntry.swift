// C entry point for the SwiftUI backend: a process owned by any language calls
// kaya_swiftui_run(api) on its main thread, exactly like kaya_run. The host
// passes its presentation-side functions explicitly (see KayaHost) instead of
// relying on dynamic-linker symbol resolution.

import SwiftUI

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
            KayaRoot()
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
        // KAYA_ACTIVATE=1 makes the app REGULAR — EXPLICITLY, because an
        // unbundled binary with no policy set defaults to PROHIBITED (measured:
        // policy=2, no activation, and a partially unpublished AX tree — merely
        // skipping the accessory call left the app LOWER, not higher). A
        // pixel-proof capture needs active-window chrome. The lanes never set
        // it, so suite runs stay accessory and steal nobody's keyboard.
        if ProcessInfo.processInfo.environment["KAYA_ACTIVATE"] != nil {
            NSApplication.shared.setActivationPolicy(.regular)
        } else if ProcessInfo.processInfo.environment["KAYA_SELFTEST"] != nil {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
