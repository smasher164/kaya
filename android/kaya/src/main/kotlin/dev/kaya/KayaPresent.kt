package dev.kaya

/**
 * The presentation-side C API over JNI, for guest-side backends: emit
 * occurrences exactly as a core backend's action handler would, and pump
 * resolved apply-op records with a blocking call — the same contract the
 * SwiftUI backend consumes through KayaHostApi. Natives are registered
 * when [Kaya.attach] selects a guest-side backend.
 */
object KayaPresent {
    /**
     * Emit a click: [tag] is the click-tag bytes delivered with the
     * widget's CREATE record, handed back verbatim.
     */
    @JvmStatic external fun emitClicked(tag: ByteArray)

    /**
     * Emit an entry edit: [tag] is the tag bytes delivered with the
     * entry's CREATE record, [text] the field's current content.
     */
    @JvmStatic external fun emitTextChanged(tag: ByteArray, text: String)

    /**
     * Emit a checkbox flip: [tag] is the tag bytes delivered with the
     * box's CREATE record, [checked] its new state.
     */
    @JvmStatic external fun emitToggled(tag: ByteArray, checked: Boolean)
    @JvmStatic external fun emitValueChanged(tag: ByteArray, value: Double)

    /** The alert's one answer: an action index, or the cancel
     * sentinel (Int -1 — the wire u32's java-int spelling) for every
     * native dismissal. kaya_emit_alert_result's JNI spelling. */
    @JvmStatic external fun emitAlertResult(alert: Long, choice: Int)

    /**
     * Block until the next transaction resolves, fill [buffer] with
     * apply-op records (KAYA_APPLY_*), and return the byte length —
     * 0 when the core has shut down. Use a 64 KiB buffer.
     */
    /** The core's protocol fingerprint, for the stale-APK assert. */
    @JvmStatic external fun specHash(): Long

    @JvmStatic external fun nextCommands(buffer: ByteArray): Int

    /**
     * Fetch a blob's bytes by the [handle] an apply record carried,
     * copied into a fresh array. Handles are batch-local: the current
     * batch's table is replaced by the next [nextCommands] call, so
     * fetch within the batch. Null for a dead handle.
     */
    @JvmStatic external fun blobData(handle: Long): ByteArray?
}
