package dev.kaya

import android.app.Activity

/**
 * The way into a GO guest on Android. Implemented not in this repo's
 * Rust but in the guest's own `.so`
 * (`//export Java_dev_kaya_KayaGo_attach` in bindings/go/android.go),
 * resolved BY NAME.
 *
 * THE SHELL'S FIVE LINES, IN ORDER, none of them optional:
 *
 * ```
 * System.loadLibrary("kaya")      // libkaya.so, from jniLibs
 * System.loadLibrary("<guest>")   // the Go c-shared .so
 * KayaRing.attach(this)           // takes NO core ends, so the
 *                                 // occurrence sink stays the ring.
 *                                 // Kaya.attach here would be WRONG:
 *                                 // it swaps the sink for a channel
 *                                 // into a Rust AppCtx
 * KayaCompose.mount(this)         // the interpreter and its pump
 * KayaGo.attach(this)             // into Go: starts the app thread
 * ```
 *
 * Two things no compiler here can see:
 *
 *  - `object` + `@JvmStatic` makes this a STATIC method, so JNI passes
 *    (JNIEnv*, jclass, jobject activity) — what the Go side accepts.
 *  - The short symbol name carries no argument mangling, so this class
 *    must declare exactly ONE native `attach`. An overload makes both
 *    unresolvable until the names carry their signatures.
 */
object KayaGo {
    @JvmStatic
    external fun attach(activity: Activity): Int
}
