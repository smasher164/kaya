package dev.kaya

/**
 * The presentation-side C API over JNI, for guest-side backends: emit
 * occurrences exactly as a core backend's action handler would, and pump
 * commands with a blocking call — the same contract the SwiftUI backend
 * consumes through KayaHostApi. Natives are registered when
 * [Kaya.nativeStart] selects a guest-side backend.
 */
object KayaPresent {
    @JvmStatic external fun emitButtonClicked(widgetId: Long)

    /** Block until the next command; false when the core has shut down. */
    @JvmStatic external fun nextCommand(command: KayaCommand): Boolean
}

/** One decoded command out of [KayaPresent.nextCommand]. */
class KayaCommand {
    @JvmField var kind: Int = 0
    @JvmField var widgetId: Long = 0
    @JvmField var text: String = ""
}
