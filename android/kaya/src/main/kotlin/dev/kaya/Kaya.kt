package dev.kaya

import android.app.Activity

/**
 * The way into kaya on Android — the attach shape, which every Android
 * app has by construction: the OS owns the Looper, kaya joins it. The
 * shell Activity loads the guest library (which carries kaya and its app
 * logic) and calls [attach] from onCreate on the UI thread; the native
 * side spawns the app thread, adds its scene, and returns the thread to
 * the Looper. Desktop hosts call the anchorless kaya_attach; here the
 * anchor (the Activity) is explicit, as Android context always is.
 *
 * One backend per platform: the native side wires the pump and always
 * answers [PRESENT_GUEST]; the Activity mounts the Compose interpreter
 * via [KayaCompose.mount]. Every other native method in this package is
 * registered by the native side, not resolved by name, so the guest
 * library's only name-based export is this entry.
 *
 * For a JVM guest — app logic in this process consuming the ring — the
 * entry is [KayaRing.attach] instead.
 */
object Kaya {
    const val PRESENT_GUEST = 1

    @JvmStatic
    external fun attach(activity: Activity): Int
}
