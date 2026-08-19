package dev.kaya

import android.content.Context

/**
 * The APK's own `assets/`, for the core's asset resolver
 * (crates/kaya/src/assets.rs, `Place::Apk`). The reasoning for the
 * whole arrangement is docs/assets-plan.md.
 *
 * `InputStream.readBytes()` and not `readAllBytes`: the latter is API
 * 33 and this module compiles at minSdk 26
 * (android/kaya/build.gradle.kts).
 *
 * These are called FROM native code, not into it, so nothing here is
 * `external fun` and tools/check-jni.sh holds no list for this file.
 */
object KayaAssets {
    /**
     * The subdirectory of the APK's `assets/` that IS kaya's asset root.
     * The same string is in android/build.gradle.kts and in
     * tools/check-assets.sh's APK clause; that gate holds the three
     * equal.
     */
    const val ROOT = "kaya"

    /**
     * One asset's bytes, or `null` if the platform would not open it.
     * ABSENT AND UNREADABLE ARE ONE ANSWER here — an APK entry has no
     * `ENOENT` — so the core's miss sentence prints the census too.
     */
    @JvmStatic
    fun read(context: Context, name: String): ByteArray? =
        try {
            context.assets.open("$ROOT/$name").use { it.readBytes() }
        } catch (e: java.io.IOException) {
            null
        }

    /**
     * Every asset this APK carries, as asset names (relative to [ROOT],
     * `/`-separated). `AssetManager.list` answers one directory at a
     * time and never says which entries are files, so A DIRECTORY IS AN
     * ENTRY WHOSE OWN LISTING IS NON-EMPTY — the only test the platform
     * offers, which reports an empty directory as a leaf.
     */
    @JvmStatic
    fun list(context: Context): Array<String> {
        val out = ArrayList<String>()
        walk(context, "", out)
        return out.toTypedArray()
    }

    private fun walk(context: Context, dir: String, out: MutableList<String>) {
        val here = if (dir.isEmpty()) ROOT else "$ROOT/$dir"
        val entries = try {
            context.assets.list(here)
        } catch (e: java.io.IOException) {
            null
        } ?: return
        for (entry in entries) {
            val rel = if (dir.isEmpty()) entry else "$dir/$entry"
            val children = try {
                context.assets.list("$ROOT/$rel")
            } catch (e: java.io.IOException) {
                null
            }
            if (children != null && children.isNotEmpty()) walk(context, rel, out) else out.add(rel)
        }
    }

    /** The installed package this process runs out of, for the miss
     * sentence's PLACE line. Answered by the platform, never computed. */
    @JvmStatic
    fun sourceDir(context: Context): String = context.applicationInfo.sourceDir
}
