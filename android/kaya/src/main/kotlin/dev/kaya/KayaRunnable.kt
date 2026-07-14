package dev.kaya

/**
 * A main-thread hop posted from native threads: the command doorbell and
 * the selftest steps. Carries only an op code, never data; the data stays
 * in the channels on the native side.
 */
class KayaRunnable(private val op: Long) : Runnable {
    override fun run() = nativeRun(op)

    private external fun nativeRun(op: Long)
}
