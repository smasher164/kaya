package dev.kaya

/**
 * The way into a PYTHON guest on Android. Implemented not in this
 * repo's Rust but in the shim `.so` (tools/android/pyhost-jni.c,
 * `Java_dev_kaya_KayaPy_run`), resolved BY NAME — KayaGo.kt's contract
 * one guest tier over, and the same two invisible rules: `object` +
 * `@JvmStatic` makes this the static (JNIEnv*, jclass, ...) shape the
 * C side accepts, and the short symbol name means exactly ONE native
 * `run` may be declared here.
 *
 * Runs CPython to COMPLETION on the calling thread — the shell calls
 * it from a background Thread, never the UI thread. The guest's
 * app.run() parks inside as the occurrence consumer (the python
 * binding's HOSTED_ENTRY arm, docs/python-mobile-plan.md §D2).
 */
object KayaPy {
    @JvmStatic
    external fun run(home: String, app: String): Int
}
