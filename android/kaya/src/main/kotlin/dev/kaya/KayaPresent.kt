package dev.kaya

import android.net.Uri

/**
 * The presentation-side C API over JNI, for guest-side backends — the
 * same contract the SwiftUI backend consumes through KayaHostApi.
 * Natives are registered when [Kaya.attach] selects a guest-side
 * backend.
 */
object KayaPresent {
    /** Emit a click: [tag] is the click-tag bytes delivered with the
     * widget's CREATE record, handed back verbatim. */
    @JvmStatic external fun emitClicked(tag: ByteArray)

    /** Milliseconds the app thread has been ignoring pending
     * occurrences, 0 when it is keeping up — the stall watchdog's
     * reading, which `expect_stall` asserts. */
    @JvmStatic external fun stalledMs(): Long

    /**
     * Emit an entry edit: [tag] is the tag bytes delivered with the
     * entry's CREATE record, [text] the field's current content.
     *
     * [focused] and [quiet] are the undo ledger's (docs/undo-plan.md
     * §3). [focused] says whether the field this event names holds
     * focus — an event on an unfocused field closes the typing episode
     * as it stands. [quiet] is LEDGER-QUIET: it marks the ordinary
     * report a routed native undo also provokes, so the change is not
     * banked twice. The app hears the edit either way.
     */
    @JvmStatic external fun emitTextChanged(
        tag: ByteArray,
        text: String,
        focused: Boolean,
        quiet: Boolean,
    )

    @JvmStatic external fun emitToggled(tag: ByteArray, checked: Boolean)
    @JvmStatic external fun emitValueChanged(tag: ByteArray, value: Double)

    /** The alert's one answer: an action index, or the cancel
     * sentinel (Int -1 — the wire u32's java-int spelling) for every
     * native dismissal. kaya_emit_alert_result's JNI spelling. */
    @JvmStatic external fun emitAlertResult(alert: Long, choice: Int)

    /**
     * The picker's one answer: parallel arrays of `content://` URIs and
     * the display names beside them. EMPTY IS CANCEL — there is no
     * sentinel. kaya_emit_file_dialog_result's JNI spelling.
     */
    @JvmStatic external fun emitFileDialogResult(
        dialog: Long,
        uris: Array<String>,
        names: Array<String>,
    )

    /**
     * The SAVE dialog's one answer: the `content://` URI of the document
     * `ACTION_CREATE_DOCUMENT` made, and its display name. NULL IS
     * CANCEL — the picker spells the same thing as an empty array,
     * because it may answer with many and this may not.
     *
     * ITS OWN ENTRY RATHER THAN [emitFileDialogResult] WITH A LIST OF
     * ONE: the core decides what a handle IS from which entry it
     * arrives on, and a save destination opens with create where a
     * picked file must not (docs/save-plan.md D1). Android's two
     * sources coincide today, so answering on the picker's entry would
     * be a mistake that works. kaya_emit_save_dialog_result's JNI
     * spelling.
     */
    @JvmStatic external fun emitSaveDialogResult(
        dialog: Long,
        uri: String?,
        name: String?,
    )

    /**
     * The privileged read's one answer, FLATTENED into scalars.
     *
     * [clip] is ONE of the wire's CLIP_* values, never a mask; 0 is the
     * universal no (denied, unfocused, empty, or nothing the request
     * accepted). [clip] alone decides which argument carries the
     * payload: text and html ride [text], an image rides [bytes], a
     * custom format rides its id in [text] and its bytes in [bytes],
     * and files ride parallel [locators] (`content://` URI strings) and
     * [names]. The arguments the kind does not name pass "" and empty
     * arrays.
     *
     * ANSWER EXACTLY ONCE — the request retires here — and answering
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
     * the widget's own click-tag bytes, handed back verbatim.
     *
     * The payload flattens as [emitClipboardResult]'s does, with one
     * difference: A PASTE THAT DELIVERED NOTHING IS NOT AN OCCURRENCE,
     * so [clip] is never 0 here and the core refuses a 0.
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
     * CALLED FROM THE CORE, not from Kotlin. A handle is redeemable
     * more than once by design, so every `open` is a real open through
     * the resolver. A pasted file comes through here too.
     *
     * The mode is the ContentResolver's spelling and the core decides
     * it (see `android_open_mode`) — in particular Write arrives as
     * `wt`, because a bare `w` does not truncate.
     *
     * RUNS ON WHATEVER THREAD THE GUEST CALLED `open` FROM:
     * `openFileDescriptor` blocks, and a provider may download the file
     * before it returns. Throws rather than returning -1 where the
     * platform gives a reason.
     */
    @JvmStatic
    fun openPickedUri(uri: String, mode: String): Int {
        val resolver = KayaCompose.pickerContext()?.contentResolver
            ?: throw IllegalStateException("kaya: no mounted activity to open $uri through")
        val pfd = resolver.openFileDescriptor(Uri.parse(uri), mode)
            ?: throw java.io.IOException("kaya: the provider returned no descriptor for $uri")
        // detachFd, NOT getFd: ownership crosses to the guest. Closing
        // the ParcelFileDescriptor here would hand back a dead fd.
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
     * Fetch a blob's bytes by the [handle] an apply record carried.
     * HANDLES ARE BATCH-LOCAL: the next [nextCommands] call replaces
     * the table, so fetch within the batch. Null for a dead handle.
     */
    @JvmStatic external fun blobData(handle: Long): ByteArray?

    // ---- The undo tier (docs/undo-plan.md D6/§3) -------------------
    //
    // THE WINDOW IS ALWAYS 0 HERE: Android is one Activity and one
    // surface. It stays in the signature so the JNI thunks forward
    // straight to the C entries.

    /**
     * Where an undo would go RIGHT NOW: 0 nowhere (the command is inert
     * and reads disabled), 1 the focused field's own stack, 2 the core's
     * ledger.
     *
     * [focused] is the widget the backend has focus on, 0 for none;
     * [canUndo] is A4's one named query in this platform's vocabulary
     * (`TextUndoManager.canUndo`). ENABLEMENT AND ACTIVATION ARE THE
     * SAME CALL, so the two cannot drift. kaya_undo_route's JNI
     * spelling.
     */
    @JvmStatic external fun undoRoute(window: Long, focused: Long, canUndo: Boolean): Int

    /** Redo's twin, with the field's `canRedo` in place of `canUndo`.
     *  kaya_redo_route's JNI spelling. */
    @JvmStatic external fun redoRoute(window: Long, focused: Long, canRedo: Boolean): Int

    /** The core tier answers. The ops reach this backend through
     *  [nextCommands] like any other apply, so nothing comes back
     *  here. kaya_undo's JNI spelling. */
    @JvmStatic external fun undo(window: Long)

    /** kaya_redo's JNI spelling. */
    @JvmStatic external fun redo(window: Long)

    /**
     * THE ONE REPORT OF A ROUTED NATIVE UNDO (docs/undo-plan.md §3):
     * the [field] the backend sent the platform's own undo to, the
     * [text] the walk landed on, and whether that field can still undo.
     * The core walks its frontier episode from those three facts.
     *
     * [canUndo] IN BOTH DIRECTIONS, deliberately — a redo reports it
     * too. It is not "did this walk have more to give"; it is the
     * core's test for the one case A1's clear is meant to make
     * unreachable, a platform that coalesced across the episode's start.
     *
     * The ordinary [emitTextChanged] the same undo provokes carries
     * `quiet = true`, so the change is banked once no matter which of
     * the two the platform delivers first — and on this backend BOTH
     * arrive (measured: a routed `undoState.undo()` moves the snapshot
     * the field's collector observes, docs/probes/undo-fan-compose.md
     * §1 Q-a and §3 point 6). kaya_note_native_undo's JNI spelling.
     */
    @JvmStatic external fun noteNativeUndo(
        window: Long,
        field: Long,
        text: String,
        canUndo: Boolean,
    )
}
