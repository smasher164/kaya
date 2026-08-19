package dev.kaya

import android.app.Activity

/**
 * The direct-access tier of the occurrence ring, for JVM consumers with
 * real atomics. [attach] is kaya_attach with the JVM app as the guest:
 * call it from onCreate on the UI thread; the native side builds the
 * scene and returns, and occurrences land in the ring for a thread of
 * this process to consume. Exclusive with [Kaya.attach] — one core per
 * process.
 *
 * dataAddress/headAddress/tailAddress expose the ring's memory layout,
 * io_uring-offsets style; the data path is Unsafe fenced loads and
 * stores on those addresses, and [waitOccurrences] is the blocking call
 * for the empty case only. Single consumer; do not mix with the function
 * floor. Raw addresses rather than direct ByteBuffers because ART's
 * interpreter truncates a direct buffer's native address to 32 bits in
 * its byte-buffer-view VarHandle path; Unsafe address-based access is
 * unaffected.
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

    /** kaya_blob_register's JNI spelling: one copy of the bytes into
     * core-owned memory; the returned handle is consumed by the next
     * submit from this guest, referenced or not, and the caller's
     * array is free the moment this returns. */
    @JvmStatic external fun blobRegister(data: ByteArray): Long

    /**
     * Redeem an occurrence blob for its bytes, and release it — called
     * by the generated decoder, never by a guest.
     *
     * A blob arriving in an OCCURRENCE is a handle into a table with no
     * boundary that retires one, unlike the apply channel's batch-local
     * index, so the decoder lets go of it while decoding and no handle
     * ever reaches an app.
     */
    @JvmStatic external fun occurrenceBlob(handle: Long): ByteArray

    /**
     * Open an asset by name — a relative path under the asset root,
     * spelled with `/`, as UTF-8 bytes. 0 is the MISS, and the caller
     * raises with the sentence [assetMissSentence] hands it.
     *
     * BYTES AND NOT A STRING, because JNI's string calls speak MODIFIED
     * UTF-8: a name outside ASCII would reach the resolver as something
     * other than what the guest typed.
     *
     * The same entry the desktop JVM carries, because the JVM guest tier
     * is one tier; on Android the root is the APK's own `assets/`, read
     * through the platform's AssetManager, and this class cannot tell.
     */
    @JvmStatic external fun assetOpen(name: ByteArray): Long

    /** An open asset's bytes: one copy out of core memory. */
    @JvmStatic external fun assetBytes(handle: Long): ByteArray

    /**
     * Register an open asset's bytes into the pending blob table and
     * return the handle a record carries. The bytes never enter the
     * JVM's heap — this is the redemption a font or an icon takes.
     */
    @JvmStatic external fun assetBlob(handle: Long): Long

    /** Drop an open asset; idempotent, so a double release is a no-op. */
    @JvmStatic external fun assetRelease(handle: Long)

    /**
     * The core's sentence for why [assetOpen] answered 0, carried
     * across as bytes; empty means the name resolves. The sentence has
     * ONE author, so every language raises the same words.
     *
     * NAMED FOR THE CARRYING, not for the answering, and deliberately
     * not `assetWhyNot`: tools/check-diagnostics.sh reads any *WhyNot
     * by that name alone and holds every branch to printing what it
     * measured. The function that EARNED the name is `asset_why_not`
     * in crates/kaya/src/assets.rs, which stats the root, lists what
     * is there and reads the io error; the gate audits it at
     * answers=8, measured=8. This is the memcpy that carries its
     * sentence, so it takes the carrier's name — OCaml's
     * `asset_miss_sentence` one binding over.
     */
    @JvmStatic external fun assetMissSentence(name: ByteArray): ByteArray

    /**
     * Redeem a picked file: a [java.io.FileDescriptor] the caller owns,
     * with `seekable[0]` set to 1 when it supports random access.
     *
     * NATIVE BECAUSE JAVA HAS NO OTHER WAY — there is no public API for
     * wrapping a descriptor, and reflecting into FileDescriptor's
     * private field throws on a modern JDK. The same entry the desktop
     * JVM carries, because the JVM guest tier is one tier; on Android
     * it lands on the source that opens through the ContentResolver.
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
