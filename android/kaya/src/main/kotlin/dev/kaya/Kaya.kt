package dev.kaya

import android.app.Activity

/**
 * The way into kaya on Android. The host Activity loads the guest library
 * (which carries kaya) and calls [nativeStart] from onCreate on the UI
 * thread; the native side spawns the app-logic thread and returns the
 * thread to the Looper. The return value says who presents:
 * [PRESENT_CORE] means the native side built the scene (the Views
 * backend); [PRESENT_GUEST] means runtime backend selection picked a
 * guest-side backend, and the Activity should mount it (Compose, via
 * [KayaCompose.mount]). Every other native method in this package is
 * registered by the native side, not resolved by name, so the guest
 * library's only name-based export is this entry.
 */
object Kaya {
    const val PRESENT_CORE = 0
    const val PRESENT_GUEST = 1

    @JvmStatic
    external fun nativeStart(activity: Activity): Int

    /**
     * The kaya_run analog when the JVM app itself is the guest: the
     * native side builds the scene and returns; occurrences land in the
     * ring for a thread of this process to consume through [KayaRing].
     * Resolved from libkaya.so directly; exclusive with [nativeStart].
     */
    @JvmStatic
    external fun nativeRun(activity: Activity)
}
