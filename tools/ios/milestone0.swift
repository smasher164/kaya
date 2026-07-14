// Milestone 0 from Swift over the C ABI (function floor). The kaya
// declarations come straight from kaya.h via -import-objc-header; nothing
// is re-declared here.
//
// Swift's main thread enters kaya_run() and becomes the core's UI thread;
// a Thread is the app thread, draining occurrences and sending commands.

import Foundation

let appThread = Thread {
    var occurrence = KayaOccurrence()
    var count = 0
    while kaya_next_occurrence(&occurrence) {
        if occurrence.kind == UInt16(KAYA_OCCURRENCE_BUTTON_CLICKED) {
            count += 1
            let noun = count == 1 ? "time" : "times"
            let text = Array("Clicked \(count) \(noun)".utf8)
            text.withUnsafeBufferPointer { buffer in
                kaya_set_text(UInt64(KAYA_WIDGET_LABEL), buffer.baseAddress, UInt(buffer.count))
            }
        }
    }
}
appThread.start()

// Takes over the main thread; on iOS this never returns (the self-test
// exits the process).
exit(kaya_run())
