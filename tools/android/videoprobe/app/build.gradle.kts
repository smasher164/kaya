plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "dev.kaya.videoprobe"
    compileSdk = 35
    buildToolsVersion = "37.0.0"

    defaultConfig {
        applicationId = "dev.kaya.videoprobe"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.0"
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
        // media3's whole ExoPlayer surface is @UnstableApi.
        freeCompilerArgs += "-opt-in=androidx.media3.common.util.UnstableApi"
    }
}

dependencies {
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation(platform("androidx.compose:compose-bom:2024.10.01"))
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    // PINNED EXACT, as every network-resolved dependency in this tree is
    // (tools/check-pins.py's rule). 1.6.1 is the last media3 line built
    // against compileSdk 35, which is android/kaya's own.
    implementation("androidx.media3:media3-exoplayer:1.6.1")
}
