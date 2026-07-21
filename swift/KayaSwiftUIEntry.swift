// C entry point for the SwiftUI backend, for guest-hosted compositions:
// a process owned by any language calls kaya_swiftui_run(api) on its main
// thread, exactly like kaya_run. @main is compiler sugar over App.main();
// nothing about SwiftUI requires Swift to own the process entry point.
// The host passes its presentation-side functions explicitly (see
// KayaHost) instead of relying on dynamic-linker symbol resolution.

import SwiftUI

struct KayaApp: App {
    #if os(macOS)
    // Selftest runs drive widgets by direct calls, never real input:
    // staying an accessory (no Dock icon, no activation) keeps a
    // suite's windows from stealing the human's keyboard.
    @NSApplicationDelegateAdaptor(KayaAppDelegate.self) var delegate
    #endif
    var body: some Scene {
        WindowGroup {
            KayaRoot()
        }
    }
}

#if os(macOS)
final class KayaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["KAYA_SELFTEST"] != nil {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
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
