package dev.kaya

/**
 * The way into a PYTHON guest on Android, in the shim `.so`
 * (tools/android/pyhost-jni.c) and resolved BY NAME under KayaGo.kt's
 * two invisible rules. Runs CPython to COMPLETION on the calling
 * thread — the shell calls it from a background Thread, never the UI
 * thread (docs/python-mobile-plan.md §D2).
 */
object KayaPy {
    @JvmStatic
    external fun run(home: String, app: String): Int
}
