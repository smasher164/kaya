package dev.kaya

import android.app.Activity

/**
 * The way into kaya on Android. [attach] is called from onCreate ON THE
 * UI THREAD; the native side spawns the app thread and returns this one
 * to the Looper. It is the guest library's only name-based export —
 * every other native in this package is registered by the native side.
 *
 * For a JVM guest the entry is [KayaRing.attach] instead.
 */
object Kaya {
    const val PRESENT_GUEST = 1

    @JvmStatic
    external fun attach(activity: Activity): Int
}
