package dev.kaya

import android.app.Activity

/**
 * The way into a GO guest on Android — the one entry whose native side
 * lives outside this repo's Rust, in the guest's own `.so`.
 *
 * [Kaya.attach] and [KayaRing.attach] are both implemented in
 * `crates/kaya/src/android.rs` and both take the core's ends. This one
 * is different in exactly one way and the difference is forced: the JVM
 * can start a JVM guest's thread itself (`Thread(scene).start()` in the
 * milestone2kt shell), and it has no way at all to call a Go function.
 * So Go starts the thread on its own side, and this entry exists only to
 * ask for it — `//export Java_dev_kaya_KayaGo_attach` in
 * `bindings/go/android.go`, resolved BY NAME out of the guest library.
 *
 * The shell's five lines, in order, and none of them optional:
 *
 * ```
 * System.loadLibrary("kaya")      // libkaya.so, from jniLibs
 * System.loadLibrary("<guest>")   // the Go c-shared .so; Go's runtime
 *                                 // boots under the app's linker here
 * KayaRing.attach(this)           // registers the pump natives and takes
 *                                 // NO core ends, so the occurrence sink
 *                                 // stays the ring — which is what a
 *                                 // direct-ring consumer like Go wants.
 *                                 // Kaya.attach would be WRONG here: it
 *                                 // replaces the sink with a channel
 *                                 // into a Rust AppCtx
 * KayaCompose.mount(this)         // the interpreter and its pump
 * KayaGo.attach(this)             // into Go: starts the app thread and
 *                                 // returns this thread to the Looper
 * ```
 *
 * Two things decide whether the two sides meet at all, and both are
 * invisible to every compiler involved:
 *
 *  - `object` + `@JvmStatic` makes this a STATIC method, so JNI passes
 *    (JNIEnv*, jclass, jobject activity) — the three pointers the Go
 *    side accepts. This is KayaRing's own shape.
 *  - The short symbol name carries no argument mangling, so this class
 *    must declare exactly ONE native `attach`. An overload makes both
 *    unresolvable until the names carry their signatures.
 *
 * [attach] answers who presents ([Kaya.PRESENT_GUEST]), the same jint
 * [Kaya.attach] answers. The shell has already mounted by then and does
 * not branch on it: the value is a fingerprint, not a decision.
 */
object KayaGo {
    @JvmStatic
    external fun attach(activity: Activity): Int
}
