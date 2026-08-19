plugins {
    id("com.android.application") version "8.7.3" apply false
    id("com.android.library") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
}

// THE APK IS ANDROID'S READER OF THE DECLARED IDENTITY
// (docs/app-identity-plan.md, rulings 3 and 4). The launcher icon is not
// something a running app sets here — it is compiled into the installed
// package — so this build is where the declaration lands: the icon
// becomes a mipmap resource and `android:icon` names it, and the name
// becomes `android:label` through a manifest placeholder.
//
// HERE AND NOT IN THE THREE APP MODULES, because three copies of a
// declaration is the failure the declaration exists to prevent: the
// labels below were three hand-written literals, and a fourth was about
// to be written. One reader, three manifests naming what it produced.
//
// AT CONFIGURATION TIME, deliberately. A task would have to be ordered
// ahead of AGP's resource merge by hand, and an ordering nobody can see
// is how a stale icon ships; doing it here means `gradle assembleDebug`
// itself refuses when the declaration is missing or unreadable, which is
// the wall invariant 3 asks for — on the path nobody can avoid.

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
    // A two-key file with no sections, so a two-line parser reads it
    // exactly rather than pulling a TOML library into the build. A key
    // this cannot find is a failure, never a default: a default is how
    // one reader ends up showing a different name from the others.
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
 * carries it in.
 *
 * ANDROID IS THE ONE PLATFORM WHOSE PACKAGED ASSETS ARE NOT FILES, so
 * this is the only build in the tree that has to put them somewhere:
 * everywhere else the running app either sees the repo or is handed a
 * staged directory by name. Here the bytes go INTO the artifact and
 * `AssetManager` reads them back (dev.kaya.KayaAssets).
 *
 * `kaya/` RATHER THAN THE TOP OF `assets/`: an app's AssetManager root
 * listing is not exclusively the app's (the framework's own asset
 * directories are visible there on several API levels) and every AAR on
 * the classpath merges its `assets/` into the same namespace — so a
 * census taken at the root would name entries kaya never shipped, and
 * tools/scenes/assets.steps freezes that census. The same string is in
 * KayaAssets.kt's `ROOT` and in tools/check-assets.sh's APK clause,
 * which holds the three equal.
 *
 * AT CONFIGURATION TIME for the icon's reason one block up: an ordering
 * nobody can see is how a stale asset ships.
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
        // The generated assets root: the whole tree, under one
        // subdirectory, copied VERBATIM so the lane's byte-equality
        // check after assembleDebug is a real comparison.
        val generatedAssets = layout.buildDirectory.dir("generated/kaya-assets").get().asFile
        val packagedAssets = File(generatedAssets, kayaAssetPrefix)
        // Deleted first: a copy over a stale tree leaves an asset the
        // repo no longer has inside the APK, and the census would then
        // report it forever.
        packagedAssets.deleteRecursively()
        kayaAssetRoot.copyRecursively(packagedAssets, overwrite = true)

        // The generated res root: one `mipmap/` holding the declared
        // picture under the name `android:icon` will spell.
        val generatedRes = layout.buildDirectory.dir("generated/kaya-identity/res").get().asFile
        val mipmap = File(generatedRes, "mipmap")
        mipmap.mkdirs()
        val packaged = File(mipmap, "kaya_mark.png")
        // Copied VERBATIM, which is what makes the byte-equality check
        // downstream (tools/android/run-emulator.sh, after assembleDebug)
        // a real comparison rather than a comparison of two renderings.
        kayaIdentity.icon.copyTo(packaged, overwrite = true)

        extensions.configure<com.android.build.api.dsl.ApplicationExtension>("android") {
            defaultConfig {
                manifestPlaceholders["kayaAppLabel"] = kayaIdentity.name
            }
            sourceSets.getByName("main").res.srcDir(generatedRes)
            sourceSets.getByName("main").assets.srcDir(generatedAssets)
            buildTypes.getByName("debug") {
                // AAPT2's PNG crunch would re-encode the picture, and the
                // lane's check would then be comparing kaya's file against
                // aapt's idea of it — a comparison that fails for a reason
                // that is not a drift. Off is already the debug default;
                // it is written down because the check depends on it.
                isCrunchPngs = false
            }
        }
    }
}
