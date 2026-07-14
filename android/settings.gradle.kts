pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "kaya-android"

// :kaya is the library's own Kotlin half (entry declaration + the shim
// classes whose natives the Rust side registers). :milestone0 is the
// Rust-guest validation app; :milestone0kt is the JVM-guest one (direct
// ring via VarHandle).
include(":kaya", ":milestone0", ":milestone0kt")
