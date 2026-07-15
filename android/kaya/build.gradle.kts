plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "dev.kaya"
    compileSdk = 35
    // Pinned to the version the nix SDK provides; AGP's default may differ
    // and it cannot download into the read-only store path.
    buildToolsVersion = "37.0.0"

    defaultConfig {
        // The JVM surface's ring recipe binds Unsafe through
        // MethodHandles.invokeExact, which ART supports from API 26.
        // (It would be 33 if ART's VarHandle worked on foreign memory;
        // see KayaApp's ring loop.)
        minSdk = 26
    }

    buildFeatures {
        compose = true
    }

    sourceSets {
        getByName("main") {
            // The generated wire vocabulary (dev.kaya.KayaWire), shared
            // with the desktop bindings tree; kaya-bindgen writes it.
            java.srcDirs("../../bindings/java")
        }
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
    // The Compose backend. api rather than implementation where the app
    // shell touches the types (ComponentActivity in MainActivity).
    api("androidx.activity:activity-compose:1.9.3")
    implementation(platform("androidx.compose:compose-bom:2024.10.01"))
    implementation("androidx.compose.material3:material3")
}
