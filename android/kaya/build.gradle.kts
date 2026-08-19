plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "dev.kaya"
    compileSdk = 35
    // Pinned to the version the nix SDK provides; AGP cannot download
    // into the read-only store path.
    buildToolsVersion = "37.0.0"

    defaultConfig {
        // ART supports MethodHandles.invokeExact on Unsafe from API 26,
        // which is what the JVM surface's ring recipe binds.
        minSdk = 26
    }

    buildFeatures {
        compose = true
    }

    sourceSets {
        getByName("main") {
            // "generated" holds dev.kaya.KayaBuildId, written by
            // tools/android/run-emulator.sh. Absent outside that lane,
            // which gradle treats as an empty source dir.
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
    // api, not implementation: the app shell touches the types
    // (ComponentActivity in MainActivity).
    api("androidx.activity:activity-compose:1.9.3")
    implementation(platform("androidx.compose:compose-bom:2024.10.01"))
    implementation("androidx.compose.material3:material3")
    // Material 3 adaptive is NOT covered by the compose BOM above (it
    // versions separately), so the versions are written out, which is
    // also what check-pins wants. The NAVIGATION artifact is
    // deliberately absent: its navigator owns a destination history,
    // and kaya's core already owns the stack.
    implementation("androidx.compose.material3.adaptive:adaptive:1.0.0")
    implementation("androidx.compose.material3.adaptive:adaptive-layout:1.0.0")
    // THE SEMANTIC ICON VOCABULARY's glyphs (docs/styling-plan.md D6).
    // Version WRITTEN OUT rather than left to the BOM above, and the
    // number is not arbitrary: 1.7.8 is the LAST version these two
    // modules will ever have (Google Maven's maven-metadata ends there,
    // lastUpdated 20250212180149, and the release notes date 1.7.8 to
    // 2025-02-12 — the two agree to the day). The BOM would supply
    // 1.7.5, which is merely the version compose-bom:2024.10.01 was cut
    // with. Pinning the frozen one means this column can never move
    // under the lane.
    //
    // NEITHER MODULE DRAGS THE COMPOSE UI STACK FORWARD, which is the
    // thing to check before overriding a BOM: measured from the 1.7.8
    // poms, material-icons-core depends on `compose.ui:ui-android:1.6.0`
    // — BELOW the BOM's 1.7.5, so ui/foundation stay exactly where they
    // are and only the icon classes move.
    //
    // EXTENDED IS HERE FOR THREE NAMES: remove, copy and paste
    // (`Icons.Default.Remove`, `ContentCopy`, `ContentPaste`). The other
    // 17 of the vocabulary's 20 are in core, which material3 already put
    // on the classpath transitively — core is declared anyway so the
    // version this file pins is the version that resolves rather than
    // whatever extended happens to depend on.
    //
    // It is a 35.7 MB build input whose own pom says "should not be
    // included directly", for three vectors. The Apache-2.0 alternative
    // — copying those three ImageVectors into kaya's own Kotlin, which
    // the license permits and the frozen library makes safe forever — is
    // the smaller dependency and is Akhil's call, not this arm's
    // (docs/styling/symbols-material-symbols.md §4.2).
    implementation("androidx.compose.material:material-icons-core:1.7.8")
    implementation("androidx.compose.material:material-icons-extended:1.7.8")
}
