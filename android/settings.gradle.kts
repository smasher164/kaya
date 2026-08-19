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

// :kaya is the library's Kotlin half; the three milestone2* modules are
// the Rust-, JVM- and Go-guest validation apps.
include(":kaya", ":milestone2", ":milestone2kt", ":milestone2go")
