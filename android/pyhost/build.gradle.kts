import java.security.MessageDigest

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.kaya.pyhost"
    compileSdk = 35
    buildToolsVersion = "37.0.0"

    defaultConfig {
        applicationId = "dev.kaya.pyhost"
        // THE NDK API LEVEL FOLLOWS THIS NUMBER (gohost's rule):
        // tools/android/run-emulator.py reads minSdk out of this file
        // and picks aarch64-linux-android<minSdk>-clang for the shim.
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.0"
    }

    // AAPT decompresses assets named *.gz; the runner's staging renames
    // them *.gz- and MainActivity undoes it on extraction (CPython's
    // own testbed trick, docs/probes/mobilepkg-cpython-2026.md §4).
    androidResources {
        noCompress += listOf("so", "pyc")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

// THE GUEST SOURCES ARE STAGED BY THE BUILD, not by whoever last ran the
// lane. `src/main/assets/python/app/` used to be filled only by
// tools/android/run-emulator.py, so a hand-built APK packaged the file
// that runner last copied — and `--rerun-tasks` did not help, because the
// staged copy IS the packaging task's input and it was unchanged. A
// three-state bisect over one guest then returned identical results for
// all three states (docs/traps.md). Everything in this task is in-tree
// and cheap; the CPython stdlib beside it stays with the runner, since it
// comes from a nix store path and its absence fails loudly at first
// launch rather than silently.
//
// THE SCENE LIST IS THE RUNNER'S — keep it equal to the tuple in
// run-emulator.py's python staging block, or the APK carries a scene the
// lane does not expect and apk_assets_verify says so.
val kayaRepoRoot = rootProject.projectDir.parentFile
val kayaPythonScenes = listOf("portfolio", "varied")

val stageGuestPython by tasks.registering {
    val app = layout.projectDirectory.dir("src/main/assets/python/app")
    inputs.file(File(kayaRepoRoot, "tools/pyhost-main.py"))
    inputs.files(kayaPythonScenes.map { File(kayaRepoRoot, "guests/python/$it.py") })
    inputs.dir(File(kayaRepoRoot, "bindings/python/kaya"))
    outputs.dir(app)
    doLast {
        copy {
            from(File(kayaRepoRoot, "tools/pyhost-main.py"))
            into(app)
            rename { "main.py" }
        }
        copy {
            from(kayaPythonScenes.map { File(kayaRepoRoot, "guests/python/$it.py") })
            into(app)
        }
        sync {
            from(File(kayaRepoRoot, "bindings/python/kaya"))
            into(app.dir("kaya"))
            exclude("__pycache__/**")
        }
        // AND THE STAMP, or the staging is invisible to the DEVICE.
        // MainActivity extracts assets/python once and skips the whole
        // walk when `kaya-stamp` matches what it already unpacked — so a
        // rebuilt APK carrying a new guest runs the OLD one, silently and
        // for as long as the stamp is unchanged. That cost four wrong
        // conclusions in one session (docs/traps.md); the copy above is
        // worthless without this.
        val pythonDir = layout.projectDirectory.dir("src/main/assets/python").asFile
        val digest = MessageDigest.getInstance("SHA-256")
        pythonDir.walkTopDown()
            .filter { it.isFile && it.name != "kaya-stamp" }
            .sortedBy { it.relativeTo(pythonDir).invariantSeparatorsPath }
            .forEach {
                digest.update(it.relativeTo(pythonDir).invariantSeparatorsPath.toByteArray())
                digest.update(it.readBytes())
            }
        val stamp = digest.digest().joinToString("") { b -> "%02x".format(b) }
        File(pythonDir, "kaya-stamp").writeText(stamp)
        logger.lifecycle(
            "pyhost: staged main.py, ${kayaPythonScenes.joinToString(", ")} " +
                "and the python binding from the tree; stamp ${stamp.take(12)}")
    }
}

tasks.named("preBuild") { dependsOn(stageGuestPython) }

dependencies {
    implementation(project(":kaya"))
}
