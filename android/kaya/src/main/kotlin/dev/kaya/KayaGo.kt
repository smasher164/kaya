package dev.kaya

import android.app.Activity

/**
 * The way into a GO guest on Android, implemented in the guest's own
 * `.so` (`//export Java_dev_kaya_KayaGo_attach` in
 * bindings/go/android.go) and resolved BY NAME. Two rules no compiler
 * here can see: `object` + `@JvmStatic` is what makes JNI pass
 * (JNIEnv*, jclass, jobject), and the unmangled symbol name means
 * exactly ONE native `attach` may be declared.
 *
 * THE SHELL'S FIVE LINES, IN ORDER, none of them optional:
 *
 * ```
 * System.loadLibrary("kaya"); System.loadLibrary("<guest>")
 * KayaRing.attach(this)     // Kaya.attach here would be WRONG: it
 *                           // swaps the ring sink for a Rust AppCtx
 * KayaCompose.mount(this); KayaGo.attach(this)
 * ```
 */
object KayaGo {
    @JvmStatic
    external fun attach(activity: Activity): Int
}
