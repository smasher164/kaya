// C entry point for the SwiftUI backend, for guest-hosted compositions:
// a process owned by any language calls kaya_swiftui_run(api) on its main
// thread, exactly like kaya_run. @main is compiler sugar over App.main();
// nothing about SwiftUI requires Swift to own the process entry point.
// The host passes its presentation-side functions explicitly (see
// KayaHost) instead of relying on dynamic-linker symbol resolution.

import SwiftUI

struct KayaApp: App {
    var body: some Scene {
        WindowGroup {
            KayaRoot()
        }
    }
}

@_cdecl("kaya_swiftui_run")
public func kayaSwiftUIRun(_ api: UnsafePointer<KayaHostApi>) -> Int32 {
    KayaHost.api = api.pointee
    KayaApp.main() // takes over the calling (main) thread; does not return
    return 0
}
