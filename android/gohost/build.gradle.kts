plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.kaya.gohost"
    compileSdk = 36
    buildToolsVersion = "37.0.0"

    defaultConfig {
        applicationId = "dev.kaya.gohost"
        // THE NDK API LEVEL FOLLOWS THIS NUMBER, not the other way
        // round: tools/android/run-emulator.py reads minSdk out of this
        // file and picks aarch64-linux-android<minSdk>-clang.
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    kotlinOptions {
        jvmTarget = "21"
    }
}

dependencies {
    implementation(project(":kaya"))
}
