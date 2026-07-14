package dev.kaya

/**
 * The presentation-side C API over JNI, for guest-side backends: emit
 * occurrences exactly as a core backend's action handler would, and pump
 * resolved apply-op records with a blocking call — the same contract the
 * SwiftUI backend consumes through KayaHostApi. Natives are registered
 * when [Kaya.attach] selects a guest-side backend.
 */
object KayaPresent {
    @JvmStatic external fun emitButtonClicked(widgetId: Long)

    /**
     * Block until the next transaction resolves, fill [buffer] with
     * apply-op records (KAYA_APPLY_*), and return the byte length —
     * 0 when the core has shut down. Use a 64 KiB buffer.
     */
    @JvmStatic external fun nextCommands(buffer: ByteArray): Int
}
