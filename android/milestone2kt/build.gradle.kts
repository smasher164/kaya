plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "dev.kaya.milestone2kt"
    compileSdk = 35
    buildToolsVersion = "37.0.0"

    defaultConfig {
        applicationId = "dev.kaya.milestone2kt"
        // The ring consumer binds Unsafe through MethodHandles, which ART
        // has from API 26. (It would be 33 if ART's VarHandle worked on
        // foreign memory; see Milestone2.java.) Validated on 35.
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
            // The scene guests live in guests/java, beside the other
            // languages' guests (the same out-of-tree srcDirs the :kaya
            // module uses for bindings/java); MainActivity stays here —
            // it is the app shell, not a scene.
            java.srcDirs("src/main/java", "../../guests/java")
        }
    }
}

// KayaRecords reflects the canonical constructor when record metadata
// is unavailable (D8 desugars records on Android, so ART never sees
// record components); -parameters keeps the component names it needs.
tasks.withType<JavaCompile> {
    options.compilerArgs.add("-parameters")
}

dependencies {
    implementation(project(":kaya"))
}
