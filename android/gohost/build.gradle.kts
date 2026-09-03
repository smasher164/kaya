plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.kaya.gohost"
    compileSdk = 35
    buildToolsVersion = "37.0.0"

    defaultConfig {
        applicationId = "dev.kaya.gohost"
        // THE NDK API LEVEL FOLLOWS THIS NUMBER, not the other way
        // round: tools/android/run-emulator.py reads minSdk out of this
        // file and picks aarch64-linux-android<minSdk>-clang to
        // cross-build the Go guest.
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
