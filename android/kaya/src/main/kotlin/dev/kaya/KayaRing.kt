package dev.kaya

import android.app.Activity

/**
 * The direct-access tier of the occurrence ring. [attach] from onCreate
 * ON THE UI THREAD; exclusive with [Kaya.attach], SINGLE CONSUMER.
 * Raw addresses rather than direct ByteBuffers: ART truncates a direct
 * buffer's address to 32 bits in the byte-buffer-view VarHandle path
 * (docs/traps.md).
 */
object KayaRing {
    @JvmStatic external fun attach(activity: Activity)

    /**
     * START THE JVM GUEST, once per process (docs/deferred.md's mount
     * entry) — a later onCreate is a NO-OP, which makes recreation
     * invisible to a guest. THE SHELL'S FOUR LINES, IN ORDER:
     * `System.loadLibrary("kaya")`, `KayaRing.attach(this)`,
     * `KayaCompose.mount(this)`, `KayaRing.startGuest(scene)`.
     */
    @JvmStatic
    fun startGuest(scene: Runnable) {
        if (guestStarted) return
        guestStarted = true
        Thread(scene, "kaya-app").start()
    }

    /** onCreate runs on the one UI thread, so no lock. */
    private var guestStarted = false

    /** One transaction as packed records (KAYA_TX_*), applied atomically. */
    @JvmStatic external fun submit(records: ByteArray)
    @JvmStatic external fun dataAddress(): Long
    @JvmStatic external fun capacity(): Int
    @JvmStatic external fun headAddress(): Long
    @JvmStatic external fun tailAddress(): Long
    @JvmStatic external fun waitOccurrences(): Boolean

    /** Return the app thread from [waitOccurrences]. Safe from any thread. */
    @JvmStatic external fun wake()
    @JvmStatic external fun specHash(): Long

    /**
     * The host capability word — kaya_capabilities's JNI spelling; a
     * `Long` because JNI has no unsigned types. BOTH JVMs carry it
     * because the ANSWER differs: this one says no to auxiliary windows
     * and the desktops say yes.
     */
    @JvmStatic external fun capabilities(): Long

    /** kaya_blob_register's JNI spelling: the returned handle is
     * consumed by the next submit from this guest, referenced or not,
     * and the caller's array is free the moment this returns. */
    @JvmStatic external fun blobRegister(data: ByteArray): Long

    /**
     * Redeem an occurrence blob for its bytes, and release it — called
     * by the generated decoder, never by a guest. Nothing else retires
     * this handle.
     */
    @JvmStatic external fun occurrenceBlob(handle: Long): ByteArray

    /**
     * Open an asset by name — a `/`-spelled relative path under the
     * asset root; 0 is the MISS, and the caller raises with
     * [assetMissSentence]'s sentence. BYTES AND NOT A STRING: JNI's
     * string calls speak MODIFIED UTF-8.
     */
    @JvmStatic external fun assetOpen(name: ByteArray): Long

    /** An open asset's bytes: one copy out of core memory. */
    @JvmStatic external fun assetBytes(handle: Long): ByteArray

    /**
     * Register an open asset's bytes into the pending blob table and
     * return the handle a record carries. The bytes never enter the
     * JVM's heap.
     */
    @JvmStatic external fun assetBlob(handle: Long): Long

    /** Drop an open asset; idempotent, so a double release is a no-op. */
    @JvmStatic external fun assetRelease(handle: Long)

    /**
     * The core's sentence for why [assetOpen] answered 0; empty means
     * the name resolves. Deliberately NOT `assetWhyNot`:
     * tools/check-diagnostics.py reads any *WhyNot by that name alone,
     * and the diagnostic is `asset_why_not` in crates/kaya/src/assets.rs.
     */
    @JvmStatic external fun assetMissSentence(name: ByteArray): ByteArray

    /**
     * Redeem a picked file: a [java.io.FileDescriptor] the caller owns,
     * with `seekable[0]` set to 1 for random access. Native because no
     * public API wraps a descriptor. BLOCKS, possibly for a long time —
     * a provider may download the file — so call it from a thread you
     * chose.
     */
    @JvmStatic external fun openPicked(
        handle: Long,
        mode: Int,
        seekable: IntArray,
    ): java.io.FileDescriptor
}
