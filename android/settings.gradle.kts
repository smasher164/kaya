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
// classes whose natives the Rust side registers). :milestone2 is the
// Rust-guest validation app; :milestone2kt is the JVM-guest one (direct
// ring via VarHandle); :milestone2go is the Go-guest one (the same
// direct ring, from a c-shared .so the shell loads and attaches).
include(":kaya", ":milestone2", ":milestone2kt", ":milestone2go")
