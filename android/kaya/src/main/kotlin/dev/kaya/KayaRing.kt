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
    @JvmStatic external fun specHash(): Long
}
