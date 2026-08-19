package dev.kaya

import android.app.Activity

/**
 * The direct-access tier of the occurrence ring, for JVM consumers with
 * real atomics. Call [attach] from onCreate ON THE UI THREAD. Exclusive
 * with [Kaya.attach] — one core per process. SINGLE CONSUMER; do not
 * mix with the function floor.
 *
 * Raw addresses rather than direct ByteBuffers: ART truncates a direct
 * buffer's address to 32 bits in the byte-buffer-view VarHandle path
 * (docs/traps.md).
 */
object KayaRing {
    @JvmStatic external fun attach(activity: Activity)
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
     * The host capability word — kaya_capabilities's JNI spelling. A
     * `Long` because JNI has no unsigned types. BOTH JVMs carry it,
     * because the ANSWER differs between them: this one says no to
     * auxiliary windows and the desktops say yes.
     */
    @JvmStatic external fun capabilities(): Long

    /** kaya_blob_register's JNI spelling: the returned handle is
     * consumed by the next submit from this guest, referenced or not,
     * and the caller's array is free the moment this returns. */
    @JvmStatic external fun blobRegister(data: ByteArray): Long

    /**
     * Redeem an occurrence blob for its bytes, and release it — called
     * by the generated decoder, never by a guest. Unlike the apply
     * channel's batch-local index, nothing else retires this handle, so
     * the decoder releases it and no handle reaches an app.
     */
    @JvmStatic external fun occurrenceBlob(handle: Long): ByteArray

    /**
     * Open an asset by name — a relative path under the asset root,
     * spelled with `/`, as UTF-8 bytes. 0 is the MISS, and the caller
     * raises with the sentence [assetMissSentence] hands it.
     *
     * BYTES AND NOT A STRING: JNI's string calls speak MODIFIED UTF-8,
     * so a name outside ASCII would reach the resolver altered.
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
     * The core's sentence for why [assetOpen] answered 0, carried
     * across as bytes; empty means the name resolves.
     *
     * NAMED FOR THE CARRYING, and deliberately NOT `assetWhyNot`:
     * tools/check-diagnostics.sh reads any *WhyNot by that name alone.
     * The function that earned the name is `asset_why_not` in
     * crates/kaya/src/assets.rs (docs/deferred.md).
     */
    @JvmStatic external fun assetMissSentence(name: ByteArray): ByteArray

    /**
     * Redeem a picked file: a [java.io.FileDescriptor] the caller owns,
     * with `seekable[0]` set to 1 when it supports random access.
     *
     * NATIVE BECAUSE JAVA HAS NO OTHER WAY — no public API wraps a
     * descriptor, and reflecting into FileDescriptor's private field
     * throws on a modern JDK.
     *
     * BLOCKS, possibly for a long time — a provider may download the
     * file before it answers — so call it from a thread you chose.
     */
    @JvmStatic external fun openPicked(
        handle: Long,
        mode: Int,
        seekable: IntArray,
    ): java.io.FileDescriptor
}
