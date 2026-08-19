package dev.kaya

import android.content.Context

/**
 * The APK's own `assets/`, for the core's asset resolver
 * (crates/kaya/src/assets.rs, `Place::Apk`).
 *
 * ANDROID IS THE ONE PLATFORM WHOSE PACKAGED ASSETS ARE NOT FILES. On
 * every other platform kaya ships, an asset root is a directory and the
 * core reads it with `std::fs`; an entry inside an APK has no path at
 * all — it is a range inside a zip the framework maps — so the resolver
 * has to ask the platform, and this object is what it asks.
 *
 * WHY KOTLIN AND NOT `AAssetManager` FROM RUST. The NDK's asset API
 * needs an `AAssetManager*`, which is obtained from a `Context` through
 * JNI anyway, and the stream reading is one line here against a
 * hand-rolled loop there. `InputStream.readBytes()` is Kotlin's own
 * extension and works at every API level; `InputStream.readAllBytes` is
 * API 33 and this module compiles at minSdk 26
 * (android/kaya/build.gradle.kts), which is the shape of failure this
 * repo keeps closing — links on the desktop, dies on a phone.
 *
 * EVERY ENTRY SITS UNDER [ROOT], NOT AT `assets/`'s TOP LEVEL, and the
 * Rust side names assets without that prefix so a guest spells one name
 * on five platforms. Two reasons, both about the CENSUS the miss
 * sentence prints:
 *
 *  - an app's AssetManager root listing is not exclusively the app's —
 *    the framework's own asset directories are visible there on several
 *    API levels;
 *  - every AAR on the classpath merges its `assets/` into the same
 *    namespace, so one added dependency would rename what kaya says its
 *    package carries.
 *
 * Either would make tools/scenes/assets.steps's frozen census a fact
 * about the toolchain rather than about kaya. The prefix is written in
 * three places — here, in android/build.gradle.kts's copy, and in
 * tools/check-assets.sh's APK clause — and that gate holds the three
 * equal rather than trusting them to stay so.
 *
 * NO `external fun` ANYWHERE HERE, deliberately: these are called FROM
 * native code, not into it, so there is no registration list for
 * tools/check-jni.sh to hold and none is needed. What holds this class's
 * name is the emulator lane's `assets-compose` leg, which resolves an
 * asset out of its own APK on every run — a wall someone walks into by
 * running the lane, rather than a gate someone has to remember.
 */
object KayaAssets {
    /**
     * The subdirectory of the APK's `assets/` that IS kaya's asset root.
     * The same string appears in android/build.gradle.kts (which copies
     * the tree there) and in tools/check-assets.sh (which checks the
     * built APK's entries); that gate refuses if the three disagree.
     */
    const val ROOT = "kaya"

    /**
     * One asset's bytes, or `null` if the platform would not open it.
     *
     * ABSENT AND UNREADABLE ARE ONE ANSWER on this route and the caller
     * says so: an APK entry has no `ENOENT` to distinguish them, so the
     * core's sentence reports "no asset named X" plus the census of what
     * the package does carry, and lets the reader see which it is.
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
     * `/`-separated). The recursion lives here because
     * `AssetManager.list` answers one directory at a time and says
     * nothing about which of its entries are files.
     *
     * A DIRECTORY IS AN ENTRY WHOSE OWN LISTING IS NON-EMPTY, which is
     * the only test the platform offers. An empty directory is therefore
     * indistinguishable from a file and is reported as a leaf — harmless
     * here, because the packaging step copies a tree of files and an
     * empty directory would not survive the zip anyway.
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

    /**
     * The installed package this process runs out of, for the miss
     * sentence's second line — the one that names the resolved PLACE.
     * A path the platform answered with, never one computed here.
     */
    @JvmStatic
    fun sourceDir(context: Context): String = context.applicationInfo.sourceDir
}
