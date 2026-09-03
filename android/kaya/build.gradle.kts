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
            // tools/android/run-emulator.py. Absent outside that lane,
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
    // Material 3 adaptive versions separately from the BOM above, so
    // these are written out (which is also what check-pins wants). The
    // NAVIGATION artifact is deliberately absent: its navigator owns a
    // destination history and kaya's core already owns the stack.
    // 1.2.0, DELIBERATELY: at 1.0.0 three panes were structurally
    // unreachable at every width (docs/multicolumn-plan.md Q4).
    implementation("androidx.compose.material3.adaptive:adaptive:1.2.0")
    implementation("androidx.compose.material3.adaptive:adaptive-layout:1.2.0")
    // THE SEMANTIC ICON VOCABULARY's glyphs, versions WRITTEN OUT: 1.7.8
    // is the last release these modules will ever have, the BOM supplies
    // 1.7.5, and neither drags the compose ui stack forward (docs/traps.md:
    // "material-icons-core 1.7.8 asks for a compose.ui BELOW the BOM's
    // own"). EXTENDED IS HERE FOR THREE NAMES — remove, copy, paste;
    // docs/styling/symbols-material-symbols.md §4.2 prices the alternative.
    implementation("androidx.compose.material:material-icons-core:1.7.8")
    implementation("androidx.compose.material:material-icons-extended:1.7.8")
    // HCT for the brand scheme's four non-primary palettes
    // (docs/deferred.md "THE FULL M3 SCHEME", route (b)). 2.1.1 IS THE
    // CEILING FOR THIS MODULE, not the latest: Kotlin 2.0.21 reads
    // class metadata only one minor ahead (<= 2.1), 3.0.0+ ships 2.2+
    // metadata, and 5.0.x additionally demands minCompileSdk 37 against
    // this module's 35. Moving it means moving the Kotlin plugin first.
    implementation("com.materialkolor:material-color-utilities:2.1.1")
    // KayaColorSchemesTest, the wall check-compose runs so the emulator
    // never proves the brand scheme first.
    testImplementation("junit:junit:4.13.2")
}
