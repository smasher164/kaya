package dev.kaya

import android.net.Uri

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

    /** Milliseconds the app thread has been ignoring pending
     * occurrences, 0 when it is keeping up — the stall watchdog's
     * reading, which `expect_stall` asserts. */
    @JvmStatic external fun stalledMs(): Long

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
     * The picker's one answer: parallel arrays of `content://` URIs and
     * the display names beside them. EMPTY IS CANCEL — no platform can
     * confirm an empty selection, so there is no sentinel to invent.
     *
     * The core mints the handles from these, wrapping each URI in the
     * source that knows how to open it. kaya_emit_file_dialog_result's
     * JNI spelling.
     */
    @JvmStatic external fun emitFileDialogResult(
        dialog: Long,
        uris: Array<String>,
        names: Array<String>,
    )

    /**
     * The privileged read's one answer, FLATTENED — the representation
     * crosses as scalars rather than as a struct, the way
     * [emitFileDialogResult] flattens the picker's answer, because a
     * struct would have to be built on both sides of the JNI boundary
     * and agreed on twice.
     *
     * [clip] is ONE of the wire's CLIP_* values, never a mask — and 0
     * is the universal no (denied, unfocused, empty, or nothing the
     * request accepted), which every platform reports the same way
     * because none of them says which. [clip] alone decides which
     * argument carries the payload: text and html ride [text], an
     * image rides [bytes], a custom format rides its id in [text] and
     * its bytes in [bytes], and files ride parallel [locators]
     * (`content://` URI strings) and [names] (their display names).
     * The arguments the kind does not name pass "" and empty arrays.
     *
     * The request retires here: answer exactly once, and answering
     * empty is always correct. kaya_emit_clipboard_result's JNI
     * spelling.
     */
    @JvmStatic external fun emitClipboardResult(
        request: Long,
        clip: Int,
        text: String,
        bytes: ByteArray,
        locators: Array<String>,
        names: Array<String>,
    )

    /**
     * Content arriving at a widget because the USER pasted. [tag] is
     * the widget's own click-tag bytes, handed back verbatim — the
     * same identity [emitClicked] and [emitTextChanged] ride, so a
     * stamped copy's paste needs no second entry.
     *
     * The payload flattens exactly as [emitClipboardResult]'s does,
     * with one difference: A PASTE THAT DELIVERED NOTHING IS NOT AN
     * OCCURRENCE, so [clip] is never 0 here. The empty answer belongs
     * to the read, which asked and may be refused; a paste that
     * reached a widget already carries content by definition. The core
     * refuses a 0 rather than inventing an empty occurrence.
     *
     * kaya_emit_pasted's JNI spelling.
     */
    @JvmStatic external fun emitPasted(
        tag: ByteArray,
        clip: Int,
        text: String,
        bytes: ByteArray,
        locators: Array<String>,
        names: Array<String>,
    )

    /**
     * Redeem a picked URI: `openFileDescriptor(uri, mode)` then
     * `detachFd`, returning the descriptor the guest now owns.
     *
     * A PASTED FILE COMES THROUGH HERE TOO, and that is the point of
     * the shared shape: [emitPasted]'s and [emitClipboardResult]'s
     * `locators` register the same source the picker's do, so the
     * guest redeems a file it pasted exactly as one it picked.
     *
     * CALLED FROM THE CORE, not from Kotlin — the one native method that
     * runs the other way. It exists because a handle is redeemable more
     * than once by design, so every `open` has to be a real open through
     * the resolver; handing over a descriptor at pick time would be
     * simpler and would give that property up.
     *
     * The mode is the ContentResolver's spelling and the core decides
     * it (see `android_open_mode`) — in particular Write arrives as
     * `wt`, because a bare `w` does not truncate.
     *
     * Runs on whatever thread the guest called `open` from, which is
     * the point: `openFileDescriptor` blocks, and a provider may
     * download the file before it returns. Throws rather than returning
     * a bare -1 where the platform gives a reason — the core turns the
     * exception's message into the guest's io error.
     */
    @JvmStatic
    fun openPickedUri(uri: String, mode: String): Int {
        val resolver = KayaCompose.pickerContext()?.contentResolver
            ?: throw IllegalStateException("kaya: no mounted activity to open $uri through")
        val pfd = resolver.openFileDescriptor(Uri.parse(uri), mode)
            ?: throw java.io.IOException("kaya: the provider returned no descriptor for $uri")
        // detachFd, NOT getFd: ownership crosses to the guest, which
        // closes it with its own file API. Closing the
        // ParcelFileDescriptor here would hand back a descriptor that is
        // already gone.
        return pfd.detachFd()
    }

    /** The user's back gesture popped an entry natively (the core's
     * stack reconciles inside this call, post-fact). */
    @JvmStatic external fun emitEntryPopped(entry: Long)

    /** Back on an intercept_back-armed entry: nothing popped; the app
     * answers with pop_entry if it agrees. */
    @JvmStatic external fun emitBackRequested(entry: Long)

    /** The user switched sections through the platform switcher
     * (post-fact; the core's selection mirror reconciles inside).
     * Programmatic select_section never comes here — the echo
     * doctrine. */
    @JvmStatic external fun emitSectionSelected(window: Long, section: Long)

    /** A menu action fired — a bar/overflow row, a context-menu row,
     * OR its shortcut: ONE occurrence, one dispatch path. [noun] is
     * the raw wire key path CONTEXT_ATTACH_NODE delivered with the
     * anchor (handed back verbatim), empty for a bar or live-widget
     * activation. kaya_emit_menu_activated's JNI spelling. */
    @JvmStatic external fun emitMenuActivated(item: Long, noun: ByteArray)

    /** A toggle item flipped by the USER ([checked] is the new state);
     * programmatic checked writes stay quiet — the echo doctrine.
     * Same item/noun identity as [emitMenuActivated];
     * kaya_emit_menu_toggled's JNI spelling. */
    @JvmStatic external fun emitMenuToggled(item: Long, noun: ByteArray, checked: Boolean)

    /** A radio group's selection changed by the USER; [item] is the
     * GROUP's id and [index] the 0-based option index (integral).
     * Programmatic value writes stay quiet — the echo doctrine.
     * kaya_emit_menu_value_changed's JNI spelling. */
    @JvmStatic external fun emitMenuValueChanged(item: Long, noun: ByteArray, index: Double)

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
