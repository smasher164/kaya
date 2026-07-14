package dev.kaya

/**
 * The direct-access tier of the occurrence ring, for JVM consumers with
 * real atomics. dataAddress/headAddress/tailAddress expose the ring's
 * memory layout, io_uring-offsets style; the data path is Unsafe
 * volatile/ordered loads and stores on those addresses, and
 * [waitOccurrences] is the blocking call for the empty case only. Single
 * consumer; do not mix with the function floor. Natives are registered
 * by [Kaya.nativeRun].
 *
 * Raw addresses rather than direct ByteBuffers because ART's interpreter
 * truncates a direct buffer's native address to 32 bits in its
 * byte-buffer-view VarHandle path; Unsafe address-based access (Netty's
 * Android idiom) is unaffected.
 */
object KayaRing {
    @JvmStatic external fun dataAddress(): Long
    @JvmStatic external fun capacity(): Int
    @JvmStatic external fun headAddress(): Long
    @JvmStatic external fun tailAddress(): Long
    @JvmStatic external fun waitOccurrences(): Boolean
    @JvmStatic external fun setText(widgetId: Long, text: String)
}
