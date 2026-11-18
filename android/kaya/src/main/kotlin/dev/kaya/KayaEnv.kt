package dev.kaya

import android.content.Intent
import android.os.Bundle
import android.system.Os

/**
 * `KAYA_*` intent extras into libc's live `environ`, so the library's env
 * switches keep one spelling everywhere: `am start … --es KAYA_SELFTEST x`
 * is this platform's `KAYA_SELFTEST=x ./app`.
 *
 * THIS IS THE C ENVIRONMENT. `Os.setenv` writes libc's own `environ`,
 * which is what a Go library loaded into a running process reads through
 * `kaya.Env` (Go's `os.Getenv` is empty here forever —
 * tools/check-go-env.py) and what CPython snapshots at init.
 *
 * CALLED FROM BOTH DOORS (docs/app-links-plan.md §4). The activity is
 * `launchMode="singleTask"` for app links, and a warm explicit start then
 * arrives at `onNewIntent` rather than at a second `onCreate` — measured
 * 2026-09-09 on the probe. In `onCreate` alone this mapping would simply
 * stop running on a warm start, and a warm-started scene would read no
 * `KAYA_SELFTEST`. What a warm re-map can and cannot do: `Os.setenv`
 * after the app thread exists moves nothing already read, so it is honest
 * only for switches read per-scene. tools/check-jni.py's manifest census
 * holds every MainActivity to calling this from both.
 *
 * NOT FOR A RESTORED ACTIVITY ([restored] non-null): the platform re-creates
 * it with its LAUNCH's intent, whose extras belong to the process that read
 * them, so a resumed act two would otherwise start as act one again
 * (docs/restoration-plan.md SR15; check-jni's census).
 */
object KayaEnv {
    @JvmStatic
    @JvmOverloads
    fun fromIntent(intent: Intent?, restored: Bundle? = null) {
        if (restored != null) return
        val extras = intent?.extras ?: return
        for (key in extras.keySet()) {
            if (key.startsWith("KAYA_")) {
                @Suppress("DEPRECATION")
                Os.setenv(key, extras.get(key).toString(), true)
            }
        }
    }
}
