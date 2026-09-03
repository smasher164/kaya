plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.kaya.javahost"
    compileSdk = 35
    buildToolsVersion = "37.0.0"

    defaultConfig {
        applicationId = "dev.kaya.javahost"
        // The ring consumer binds Unsafe through MethodHandles, which
        // ART has from API 26.
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

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/java", "../../guests/java")
        }
    }
}

// KayaRecords reflects the canonical constructor when record metadata
// is unavailable (D8 desugars records on Android, so ART never sees
// record components); -parameters keeps the component names it needs.
tasks.withType<JavaCompile> {
    options.compilerArgs.add("-parameters")
    // Main.java is the desktop entrypoint: KayaRing.run has no Android
    // twin (crates/kaya/src/jvm.rs), and check-compose compiles this task.
    exclude("dev/kaya/guests/Main.java")
}

dependencies {
    implementation(project(":kaya"))
}
