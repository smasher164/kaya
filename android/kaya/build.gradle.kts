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
            // "generated" holds dev.kaya.KayaBuildId, written by
            // tools/android/run-emulator.sh so the apk can be asked
            // which interpreter sources it was built from
            // (tools/build-id.sh). Absent outside that lane, which
            // gradle treats as an empty source dir.
            java.srcDirs("../../bindings/java", "generated")
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
    // Material 3 adaptive: ListDetailPaneScaffold is Android's own
    // list-detail container, and adopting it hands Android the decision
    // of where one pane becomes two instead of kaya drawing that line.
    // NOT covered by the compose BOM above (it versions separately), so
    // the versions are written out, which is also what check-pins wants.
    //
    // adaptive-layout carries the scaffold; adaptive carries the
    // directive and the window-size reading it is computed from. The
    // NAVIGATION artifact is deliberately absent: its navigator owns a
    // destination history, and kaya's core already owns the stack.
    implementation("androidx.compose.material3.adaptive:adaptive:1.0.0")
    implementation("androidx.compose.material3.adaptive:adaptive-layout:1.0.0")
}
