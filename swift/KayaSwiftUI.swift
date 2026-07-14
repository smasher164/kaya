// KayaSwiftUI: the Swift half of the SwiftUI backend. Plays the
// presentation role of kaya's protocol over the C ABI:
//
//   kaya signal      -> @Observable property (SwiftUI invalidation renders)
//   occurrence       <- SwiftUI action closure -> kaya_emit_button_clicked
//   command SetText  -> kaya_next_command (blocking pump) -> observable write
//
// The command pump blocks in kaya_next_command on its own thread and hops
// to the main actor to write observable state — the doorbell equivalent,
// no polling, no callbacks across the ABI.
//
// Milestone-0 grade: the scene is hardcoded here, exactly as it is in
// every Rust backend. The scene-as-data interpreter arrives with the
// reactive surface. Compiled together with the app's Swift sources as one
// module; SPM packaging comes when this grows.

import SwiftUI

@Observable
final class KayaModel {
    var labelText = "Clicked 0 times"
}

let kayaModel = KayaModel()

/// The presentation-side functions, handed over by the host kaya rather
/// than resolved through the dynamic linker: hosts may carry kaya
/// statically or load it RTLD_LOCAL, so the vtable pins the one live
/// instance. Populated by kaya_swiftui_run.
enum KayaHost {
    nonisolated(unsafe) static var api: KayaHostApi!

    static func emit(_ widgetId: UInt64) {
        api.emit_button_clicked(widgetId)
    }

    static func nextCommand(_ command: inout KayaCommand) -> Bool {
        api.next_command(&command)
    }
}

func kayaStartCommandPump() {
    let thread = Thread {
        var command = KayaCommand()
        while KayaHost.nextCommand(&command) {
            if command.kind == UInt16(KAYA_COMMAND_SET_TEXT),
                command.widget_id == UInt64(KAYA_WIDGET_LABEL)
            {
                let text = withUnsafeBytes(of: command.text) { raw in
                    String(decoding: raw.prefix(Int(command.text_len)), as: UTF8.self)
                }
                DispatchQueue.main.async {
                    kayaModel.labelText = text
                }
            }
        }
    }
    thread.start()
}

/// Drives the round trip without a human, matching the Rust backends'
/// spawn_selftest: emits the same occurrence the Button action emits and
/// verifies the rendered model state.
func kayaStartSelftest() {
    guard ProcessInfo.processInfo.environment["KAYA_SELFTEST"] != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        KayaHost.emit(UInt64(KAYA_WIDGET_BUTTON))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
        KayaHost.emit(UInt64(KAYA_WIDGET_BUTTON))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
        if kayaModel.labelText == "Clicked 2 times" {
            print("KAYA_SELFTEST: OK (\(kayaModel.labelText))")
            exit(0)
        } else {
            FileHandle.standardError.write(
                "KAYA_SELFTEST: FAILED (label reads \(kayaModel.labelText))\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

/// The milestone-0 scene.
struct KayaRoot: View {
    @State private var state = kayaModel

    var body: some View {
        VStack(spacing: 8) {
            Button("Click me") {
                KayaHost.emit(UInt64(KAYA_WIDGET_BUTTON))
            }
            Text(state.labelText)
        }
        .padding()
        .onAppear {
            kayaStartCommandPump()
            kayaStartSelftest()
        }
    }
}
