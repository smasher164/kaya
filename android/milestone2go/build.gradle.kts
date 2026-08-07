plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.kaya.milestone2go"
    compileSdk = 35
    buildToolsVersion = "37.0.0"

    defaultConfig {
        applicationId = "dev.kaya.milestone2go"
        // THE NDK API LEVEL FOLLOWS THIS NUMBER, not the other way
        // round: tools/android/run-emulator.sh reads minSdk out of this
        // file and picks aarch64-linux-android<minSdk>-clang to
        // cross-build the Go guest, so the guest cannot be built against
        // a platform the manifest does not claim.
        //
        // 26 for the same reason milestone2kt is 26 — the pump natives
        // this app registers through KayaRing come from the same tier —
        // and the Go side needs nothing newer (its .so NEEDs only
        // libkaya.so, liblog, libdl, libc).
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.0"
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
