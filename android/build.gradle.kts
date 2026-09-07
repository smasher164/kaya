plugins {
    id("com.android.application") version "8.7.3" apply false
    id("com.android.library") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
}

// Read AT CONFIGURATION TIME, not in a task: a task would have to be
// ordered ahead of AGP's resource merge by hand
// (docs/app-identity-plan.md, rulings 3 and 4).

/**
 * The declaration: `name` and `icon`, plus the `[launch]` slot's colour
 * and picture (docs/tasks-s2-plan.md T4), out of kaya's packaging manifest.
 */
data class KayaIdentity(
    val name: String,
    val icon: File,
    val launchBackground: String,
    val launchIcon: File,
)

fun kayaReadIdentity(repoRoot: File): KayaIdentity {
    val manifest = File(repoRoot, "guests/assets/identity.toml")
    if (!manifest.isFile) {
        throw GradleException(
            "kaya: the app identity is declared in ${manifest.path} and that file is " +
                "not there. The APK's launcher icon and label are read from it " +
                "(docs/app-identity-plan.md ruling 4); nothing here can guess a name " +
                "or a picture."
        )
    }
    val text = manifest.readText()
    // SECTION-AWARE, because `[launch]` put a second table in this file
    // and a MULTILINE key pattern would read `background` whatever table
    // it sits in — which is how the next key added to the root table
    // would silently answer for the launch slot.
    fun table(section: String): Map<String, String> {
        val header = Regex("""^\[([A-Za-z0-9_.-]+)]$""")
        val pair = Regex("""^([A-Za-z0-9_]+)\s*=\s*"([^"]*)"$""")
        // A `#` INSIDE QUOTES IS NOT A COMMENT, which is not a nicety
        // here: the launch background is spelled #RRGGBB and is the one
        // value in this manifest that carries one, so a plain
        // substringBefore('#') reads its line as empty and reports the
        // key missing. Measured 2026-09-07, one build.
        fun uncommented(raw: String): String {
            var quoted = false
            for ((i, c) in raw.withIndex()) {
                if (c == '"') quoted = !quoted
                else if (c == '#' && !quoted) return raw.substring(0, i)
            }
            return raw
        }
        val out = LinkedHashMap<String, String>()
        var current = ""
        for (raw in text.lineSequence()) {
            val line = uncommented(raw).trim()
            if (line.isEmpty()) continue
            val head = header.find(line)
            if (head != null) {
                current = head.groupValues[1]
                continue
            }
            val kv = pair.find(line) ?: continue
            if (current == section) out[kv.groupValues[1]] = kv.groupValues[2]
        }
        return out
    }

    val root = table("")
    val launch = table("launch")
    fun value(key: String): String =
        root[key] ?: throw GradleException(
            "kaya: ${manifest.path} declares no `$key` — the APK reads both `name` " +
                "and `icon` from it, and half a declaration is not one."
        )
    val name = value("name")
    if (name.isBlank()) {
        throw GradleException(
            "kaya: ${manifest.path} declares an empty `name`. An app that wants the " +
                "platform's own identity declares none at all — an empty string would " +
                "sail through every lowering (docs/app-identity-plan.md I5, wall 3)."
        )
    }
    val icon = File(repoRoot, value("icon"))
    if (!icon.isFile) {
        throw GradleException(
            "kaya: ${manifest.path} names the icon ${icon.path}, which is not there. " +
                "That file's BYTES are what the APK packages and what the running app " +
                "sends over the wire — the same file, on purpose."
        )
    }

    val background = launch["background"] ?: throw GradleException(
        "kaya: ${manifest.path} declares no `[launch] background`. Android's own " +
            "slot takes a colour and a picture, and an app that supplies neither " +
            "gets the platform's window background between the tap and the first " +
            "frame (docs/tasks-s2-plan.md T4)."
    )
    if (!Regex("^#[0-9A-Fa-f]{6}$").matches(background)) {
        throw GradleException(
            "kaya: ${manifest.path} declares `[launch] background = \"$background\"`, " +
                "which is not #RRGGBB. The slot's colour is written into an Android " +
                "colour resource and into the iOS bundle's colour asset, and neither " +
                "reader can guess what a half-spelled one meant."
        )
    }
    // `image` DEFAULTS TO `icon` (T4): one picture stands for the app in
    // the launcher and on the way in.
    val launchIcon = File(repoRoot, launch["image"] ?: value("icon"))
    if (!launchIcon.isFile) {
        throw GradleException(
            "kaya: ${manifest.path} names the launch image ${launchIcon.path}, which " +
                "is not there."
        )
    }
    return KayaIdentity(name, icon, background, launchIcon)
}

val kayaIdentity = kayaReadIdentity(rootDir.parentFile)

/**
 * The asset root the APK carries, and the subdirectory of `assets/` it
 * carries it in (docs/assets-plan.md; docs/deferred.md on the `kaya/`
 * prefix). The prefix string is also in KayaAssets.kt's `ROOT` and in
 * tools/check-assets.py's APK clause; that gate holds the three equal.
 */
val kayaAssetRoot = File(rootDir.parentFile, "guests/assets")
val kayaAssetPrefix = "kaya"
if (!kayaAssetRoot.isDirectory) {
    throw GradleException(
        "kaya: the asset root ${kayaAssetRoot.path} is not there. Every asset an " +
            "app names with `asset(\"...\")` is packaged out of it, and on Android " +
            "there is no second route — a phone cannot see the repo " +
            "(docs/assets-plan.md A4)."
    )
}

subprojects {
    // THE LAUNCH SLOT'S TWO RESOURCES GO IN THE LIBRARY, not in each app:
    // `Theme.Kaya.Launch` is declared once in android/kaya's themes.xml and
    // a library style may only name resources its own module can resolve,
    // so a per-app copy of the colour and the drawable would mean a
    // per-app copy of the theme (docs/tasks-s2-plan.md T4).
    plugins.withId("com.android.library") {
        val generatedLaunch =
            layout.buildDirectory.dir("generated/kaya-launch/res").get().asFile
        val values = File(generatedLaunch, "values")
        val drawable = File(generatedLaunch, "drawable")
        values.mkdirs()
        drawable.mkdirs()
        File(values, "kaya_launch.xml").writeText(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                "<resources>\n" +
                "    <color name=\"kaya_launch_background\">" +
                "#FF${kayaIdentity.launchBackground.substring(1).uppercase()}" +
                "</color>\n" +
                "</resources>\n"
        )
        // Copied VERBATIM, like the mark: the lane hashes what the APK
        // carries against this file (run-emulator's apk_launch_verify).
        kayaIdentity.launchIcon.copyTo(File(drawable, "kaya_launch_mark.png"),
            overwrite = true)

        extensions.configure<com.android.build.api.dsl.LibraryExtension>("android") {
            sourceSets.getByName("main").res.srcDir(generatedLaunch)
        }
    }

    plugins.withId("com.android.application") {
        // Copied VERBATIM: the lane's byte-equality check after
        // assembleDebug (tools/android/run-emulator.py) compares hashes.
        val generatedAssets = layout.buildDirectory.dir("generated/kaya-assets").get().asFile
        val packagedAssets = File(generatedAssets, kayaAssetPrefix)
        // Deleted first, or a stale asset stays in the APK and the
        // census reports it forever.
        packagedAssets.deleteRecursively()
        kayaAssetRoot.copyRecursively(packagedAssets, overwrite = true)

        val generatedRes = layout.buildDirectory.dir("generated/kaya-identity/res").get().asFile
        val mipmap = File(generatedRes, "mipmap")
        mipmap.mkdirs()
        val packaged = File(mipmap, "kaya_mark.png")
        kayaIdentity.icon.copyTo(packaged, overwrite = true)

        extensions.configure<com.android.build.api.dsl.ApplicationExtension>("android") {
            defaultConfig {
                manifestPlaceholders["kayaAppLabel"] = kayaIdentity.name
            }
            sourceSets.getByName("main").res.srcDir(generatedRes)
            sourceSets.getByName("main").assets.srcDir(generatedAssets)
            buildTypes.getByName("debug") {
                // Already the debug default, written down because the
                // byte-equality check depends on it: AAPT2's PNG crunch
                // would re-encode the mark AND the launch picture.
                isCrunchPngs = false
            }
        }
    }
}
