package dev.kaya

import android.app.Activity

/**
 * The way into kaya on Android ([KayaRing.attach] for a JVM guest).
 * Called from onCreate ON THE UI THREAD; the native side spawns the app
 * thread and returns this one to the Looper. The guest library's only
 * name-based export — every other native in this package is registered
 * by the native side (tools/check-jni.py).
 */
object Kaya {
    const val PRESENT_GUEST = 1

    @JvmStatic
    external fun attach(activity: Activity): Int
}
