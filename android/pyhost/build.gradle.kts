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
        // THE NDK API LEVEL FOLLOWS THIS NUMBER (milestone2go's rule):
        // tools/android/run-emulator.sh reads minSdk out of this file
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

dependencies {
    implementation(project(":kaya"))
}
