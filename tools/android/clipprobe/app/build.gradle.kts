plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.kaya.clipprobe"
    compileSdk = 35
    buildToolsVersion = "37.0.0"

    defaultConfig {
        applicationId = "dev.kaya.clipprobe"
        // The validation apps' own floor and ceiling: scoped storage
        // and the picker's behaviour both key on targetSdk, so a probe
        // that targeted less would measure a platform the lane never
        // runs on.
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
    implementation("androidx.activity:activity:1.9.3")
}
