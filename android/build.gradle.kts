plugins {
    id("com.android.application") version "8.7.3" apply false
    id("com.android.library") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
}

// Read AT CONFIGURATION TIME, not in a task: a task would have to be
// ordered ahead of AGP's resource merge by hand
// (docs/app-identity-plan.md, rulings 3 and 4).

/** The declaration: `name` and `icon` out of kaya's packaging manifest. */
data class KayaIdentity(val name: String, val icon: File)

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
    fun value(key: String): String {
        val re = Regex("""^\s*$key\s*=\s*"([^"]*)"\s*$""", RegexOption.MULTILINE)
        val m = re.find(manifest.readText())
            ?: throw GradleException(
                "kaya: ${manifest.path} declares no `$key` — the APK reads both `name` " +
                    "and `icon` from it, and half a declaration is not one."
            )
        return m.groupValues[1]
    }
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
    return KayaIdentity(name, icon)
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
                // would re-encode the mark.
                isCrunchPngs = false
            }
        }
    }
}
